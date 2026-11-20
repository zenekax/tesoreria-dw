/* =============================================================================
   04_usp_dq_controles_post_carga.sql — Totales de control DESPUÉS de cargar el DW.

   Analogía: es la cuadratura del cierre. Lo que vino en los archivos (sin lo que quedó
   en cuarentena) tiene que estar en el libro, en cantidad y en plata; y el saldo que
   informa el banco tiene que explicarse con los movimientos registrados.

     CTL_FILAS_*          filas válidas de staging (clave de negocio única, sin cuarentena) = filas en el DW
     CTL_MONTO_*          suma por moneda de staging válido = suma en el DW
     CTL_SALDO_EXTRACTO   saldo inicial + movimientos cargados = saldo final del banco (cuenta x mes)
     CTL_SALDO_CONTINUIDAD  el saldo final de un mes = el inicial del siguiente

   Además, las 3 reglas de CONSISTENCIA ERP vs. banco (PAG_SIN_EXTRACTO, COB_SIN_EXTRACTO,
   EXT_SIN_MATCH), que se evalúan sobre el resultado de la conciliación 1 a 1 (dw.usp_conciliar):
   una partida que quedó pendiente fuera del período de tránsito, salvo que la explique una
   fila en cuarentena del otro lado (no se culpa a un comprobante por el error de otro).
   Estas sí apuntan a la fila de staging (archivo y línea).

   Los totales de control son AGREGADOS: no apuntan a una fila de staging sino a una tabla, una
   moneda o una cuenta-mes (van a dq_errores con stg_row_id NULL y la clave en texto).
   Tienen sentido después de una carga completa o incremental "hasta hoy"; con una
   ventana cerrada (@fecha_hasta) el orquestador no los corre.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE audit.usp_dq_controles_post_carga
    @ejecucion_id  UNIQUEIDENTIFIER = NULL,
    @dias_transito INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @proc SYSNAME = N'audit.usp_dq_controles_post_carga';
    DECLARE @log_id INT, @msg_ok NVARCHAR(4000), @stg INT, @dw INT;
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #ctl (regla_id VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
                           evaluadas INT NOT NULL, errores INT NOT NULL);
        CREATE TABLE #det (regla_id VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL,
                           clave NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
                           valor NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL);

        /* ---- staging válido: primera aparición de cada clave, fuera de cuarentena */
        SELECT s.invoice_id AS clave, s.currency AS moneda, TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto
        INTO #inv
        FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY _row_id) AS nro FROM stg.invoices) s
        WHERE s.nro = 1 AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_invoices q
                                        WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA');
        SELECT s.payment_id AS clave, s.currency AS moneda, TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto
        INTO #pag
        FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY _row_id) AS nro FROM stg.payments) s
        WHERE s.nro = 1 AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_payments q
                                        WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA');
        SELECT s.collection_id AS clave, s.currency AS moneda, TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto
        INTO #cob
        FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY collection_id ORDER BY _row_id) AS nro FROM stg.collections) s
        WHERE s.nro = 1 AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_collections q
                                        WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA');
        SELECT s.statement_line_id AS clave, s.currency AS moneda, TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto
        INTO #ext
        FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY statement_line_id ORDER BY _row_id) AS nro FROM stg.bank_statements) s
        WHERE s.nro = 1 AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q
                                        WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA');

        /* ---- CTL_FILAS_*: cantidad */
        SELECT @stg = COUNT(*) FROM #inv;  SELECT @dw = COUNT(*) FROM dw.fact_facturas;
        INSERT INTO #ctl VALUES ('CTL_FILAS_FACTURAS', @stg, ABS(@stg - @dw));
        IF @stg <> @dw INSERT INTO #det VALUES ('CTL_FILAS_FACTURAS', N'total', CONCAT(N'staging=', @stg, N'; dw=', @dw));

        SELECT @stg = COUNT(*) FROM #pag;  SELECT @dw = COUNT(*) FROM dw.fact_pagos;
        INSERT INTO #ctl VALUES ('CTL_FILAS_PAGOS', @stg, ABS(@stg - @dw));
        IF @stg <> @dw INSERT INTO #det VALUES ('CTL_FILAS_PAGOS', N'total', CONCAT(N'staging=', @stg, N'; dw=', @dw));

        SELECT @stg = COUNT(*) FROM #cob;  SELECT @dw = COUNT(*) FROM dw.fact_cobranzas;
        INSERT INTO #ctl VALUES ('CTL_FILAS_COBRANZAS', @stg, ABS(@stg - @dw));
        IF @stg <> @dw INSERT INTO #det VALUES ('CTL_FILAS_COBRANZAS', N'total', CONCAT(N'staging=', @stg, N'; dw=', @dw));

        SELECT @stg = COUNT(*) FROM #ext;  SELECT @dw = COUNT(*) FROM dw.fact_movimientos_bancarios;
        INSERT INTO #ctl VALUES ('CTL_FILAS_MOVIMIENTOS', @stg, ABS(@stg - @dw));
        IF @stg <> @dw INSERT INTO #det VALUES ('CTL_FILAS_MOVIMIENTOS', N'total', CONCAT(N'staging=', @stg, N'; dw=', @dw));

        /* ---- CTL_MONTO_*: plata, por moneda (FULL OUTER JOIN: una moneda que está de un solo lado también es diferencia) */
        WITH s AS (SELECT moneda, SUM(monto) AS monto FROM #pag GROUP BY moneda),
             d AS (SELECT m.codigo_iso AS moneda, SUM(f.monto) AS monto FROM dw.fact_pagos f
                   JOIN dw.dim_moneda m ON m.moneda_key = f.moneda_key GROUP BY m.codigo_iso)
        INSERT INTO #det SELECT 'CTL_MONTO_PAGOS', COALESCE(s.moneda, d.moneda),
               CONCAT(N'staging=', ISNULL(s.monto, 0), N'; dw=', ISNULL(d.monto, 0))
        FROM s FULL OUTER JOIN d ON d.moneda = s.moneda WHERE ISNULL(s.monto, 0) <> ISNULL(d.monto, 0);
        INSERT INTO #ctl SELECT 'CTL_MONTO_PAGOS', (SELECT COUNT(DISTINCT moneda) FROM #pag),
               (SELECT COUNT(*) FROM #det WHERE regla_id = 'CTL_MONTO_PAGOS');

        WITH s AS (SELECT moneda, SUM(monto) AS monto FROM #cob GROUP BY moneda),
             d AS (SELECT m.codigo_iso AS moneda, SUM(f.monto) AS monto FROM dw.fact_cobranzas f
                   JOIN dw.dim_moneda m ON m.moneda_key = f.moneda_key GROUP BY m.codigo_iso)
        INSERT INTO #det SELECT 'CTL_MONTO_COBRANZAS', COALESCE(s.moneda, d.moneda),
               CONCAT(N'staging=', ISNULL(s.monto, 0), N'; dw=', ISNULL(d.monto, 0))
        FROM s FULL OUTER JOIN d ON d.moneda = s.moneda WHERE ISNULL(s.monto, 0) <> ISNULL(d.monto, 0);
        INSERT INTO #ctl SELECT 'CTL_MONTO_COBRANZAS', (SELECT COUNT(DISTINCT moneda) FROM #cob),
               (SELECT COUNT(*) FROM #det WHERE regla_id = 'CTL_MONTO_COBRANZAS');

        WITH s AS (SELECT moneda, SUM(monto) AS monto FROM #ext GROUP BY moneda),
             d AS (SELECT m.codigo_iso AS moneda, SUM(f.monto) AS monto FROM dw.fact_movimientos_bancarios f
                   JOIN dw.dim_moneda m ON m.moneda_key = f.moneda_key GROUP BY m.codigo_iso)
        INSERT INTO #det SELECT 'CTL_MONTO_MOVIMIENTOS', COALESCE(s.moneda, d.moneda),
               CONCAT(N'staging=', ISNULL(s.monto, 0), N'; dw=', ISNULL(d.monto, 0))
        FROM s FULL OUTER JOIN d ON d.moneda = s.moneda WHERE ISNULL(s.monto, 0) <> ISNULL(d.monto, 0);
        INSERT INTO #ctl SELECT 'CTL_MONTO_MOVIMIENTOS', (SELECT COUNT(DISTINCT moneda) FROM #ext),
               (SELECT COUNT(*) FROM #det WHERE regla_id = 'CTL_MONTO_MOVIMIENTOS');

        /* ---- CTL_SALDO_EXTRACTO: ¿los movimientos cargados explican el saldo del banco?
           Si una línea quedó en cuarentena (importe en blanco, fecha rota), el mes de esa
           cuenta no cuadra: es exactamente lo que el tesorero tiene que ir a mirar. */
        SELECT s.banco_cuenta_key, c.numero_cuenta, f.anio_mes, s.saldo_inicial, s.saldo_final,
               ISNULL(mv.total, 0) AS movimientos,
               LEAD(s.saldo_inicial) OVER (PARTITION BY s.banco_cuenta_key ORDER BY s.fecha_cierre_key) AS inicial_siguiente
        INTO #saldos
        FROM dw.fact_saldo_bancario_mensual s
        JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = s.banco_cuenta_key
        JOIN dw.dim_fecha f ON f.fecha_key = s.fecha_cierre_key
        OUTER APPLY (SELECT SUM(m.monto) AS total
                     FROM dw.fact_movimientos_bancarios m
                     WHERE m.banco_cuenta_key = s.banco_cuenta_key
                       AND m.fecha_imputacion_key BETWEEN f.anio * 10000 + f.mes * 100 + 1 AND s.fecha_cierre_key) mv;

        INSERT INTO #det SELECT 'CTL_SALDO_EXTRACTO', CONCAT(numero_cuenta, N'|', anio_mes),
               CONCAT(N'saldo_banco=', saldo_final, N'; inicial+movimientos=', saldo_inicial + movimientos,
                      N'; diferencia=', saldo_final - saldo_inicial - movimientos)
        FROM #saldos WHERE saldo_inicial + movimientos <> saldo_final;
        INSERT INTO #ctl SELECT 'CTL_SALDO_EXTRACTO', (SELECT COUNT(*) FROM #saldos),
               (SELECT COUNT(*) FROM #det WHERE regla_id = 'CTL_SALDO_EXTRACTO');

        INSERT INTO #det SELECT 'CTL_SALDO_CONTINUIDAD', CONCAT(numero_cuenta, N'|', anio_mes),
               CONCAT(N'final=', saldo_final, N'; inicial_mes_siguiente=', inicial_siguiente)
        FROM #saldos WHERE inicial_siguiente IS NOT NULL AND inicial_siguiente <> saldo_final;
        INSERT INTO #ctl SELECT 'CTL_SALDO_CONTINUIDAD', (SELECT COUNT(*) FROM #saldos WHERE inicial_siguiente IS NOT NULL),
               (SELECT COUNT(*) FROM #det WHERE regla_id = 'CTL_SALDO_CONTINUIDAD');

        /* ---- Consistencia ERP vs. banco, sobre la conciliación 1 a 1 ----------------------------- */
        DECLARE @fecha_corte DATE = (SELECT EOMONTH(MAX(TRY_CONVERT(DATE, period + '-01', 23))) FROM stg.bank_balances);
        SET @fecha_corte = ISNULL(@fecha_corte, CAST(SYSUTCDATETIME() AS DATE));
        DECLARE @limite_transito DATE = DATEADD(DAY, -@dias_transito, @fecha_corte);
        CREATE TABLE #det_fila (regla_id VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, stg_row_id BIGINT NULL,
                                source_file NVARCHAR(260) COLLATE DATABASE_DEFAULT NULL, source_line INT NULL,
                                clave NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
                                valor NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL);

        -- Lo que está en cuarentena del lado banco (líneas rotas) y del lado ERP (pagos/cobranzas rotos).
        SELECT q.stg_row_id AS linea_q, q.account_number, TRY_CONVERT(DATE, q.booking_date, 23) AS f_imp,
               TRY_CONVERT(DECIMAL(19,2), q.amount) AS monto, q.bank_tx_code, q.description
        INTO #lineas_cuarentena
        FROM audit.cuarentena_bank_statements q WHERE q.estado = 'EN_CUARENTENA' AND q.reglas NOT LIKE '%DUPLICADO%';
        SELECT 'PAGO' AS tipo, q.stg_row_id AS erp_q, q.account_id, ABS(TRY_CONVERT(DECIMAL(19,2), q.amount)) AS monto_abs,
               TRY_CONVERT(DATE, q.payment_date, 23) AS fecha
        INTO #erp_cuarentena
        FROM audit.cuarentena_payments q WHERE q.estado = 'EN_CUARENTENA' AND q.reglas NOT LIKE '%DUPLICADO%'
        UNION ALL
        SELECT 'COBRANZA', q.stg_row_id, q.account_id, ABS(TRY_CONVERT(DECIMAL(19,2), q.amount)),
               TRY_CONVERT(DATE, q.collection_date, 23)
        FROM audit.cuarentena_collections q WHERE q.estado = 'EN_CUARENTENA' AND q.reglas NOT LIKE '%DUPLICADO%';

        -- PAG/COB_SIN_EXTRACTO: partida del ERP pendiente en banco, fuera del tránsito, que no se
        -- explica por una línea ROTA del banco (en cuarentena). Cada línea rota explica como mucho
        -- UNA partida (1 a 1, como la conciliación): la que tiene su referencia en la descripción o,
        -- si no, la más cercana en fecha. Sin el 1 a 1, a escala 20 una línea rota de OTRO movimiento
        -- "tapaba" a un pago que realmente no se debitó.
        SELECT k.conciliacion_key, k.origen, COALESCE(k.pago_id, k.cobranza_id) AS clave, c.numero_cuenta, f.fecha,
               k.monto_libro, COALESCE(p.referencia_pago, cb.referencia_cobranza) AS referencia
        INTO #pend_libro
        FROM dw.fact_conciliacion k
        JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
        JOIN dw.dim_fecha f ON f.fecha_key = k.fecha_libro_key
        LEFT JOIN dw.fact_pagos p ON p.pago_id = k.pago_id
        LEFT JOIN dw.fact_cobranzas cb ON cb.cobranza_id = k.cobranza_id
        WHERE k.estado = 'PENDIENTE_EN_BANCO' AND f.fecha <= @limite_transito;

        WITH candidatos AS (
            SELECT p.conciliacion_key, l.linea_q,
                   ROW_NUMBER() OVER (PARTITION BY l.linea_q ORDER BY
                       IIF(l.description LIKE N'%' + p.referencia + N'%'
                           OR l.description LIKE N'% ' + RIGHT(p.referencia, 5) + N' %', 0, 1),
                       ABS(DATEDIFF(DAY, p.fecha, ISNULL(l.f_imp, p.fecha))), p.conciliacion_key) AS rn
            FROM #pend_libro p
            JOIN #lineas_cuarentena l
              ON l.account_number = p.numero_cuenta
             AND l.bank_tx_code = IIF(p.origen = 'PAGO', 'TRF_OUT', 'TRF_IN')
             AND (l.f_imp IS NULL OR l.f_imp BETWEEN p.fecha AND DATEADD(DAY, 7, p.fecha))
             AND (l.monto IS NULL OR ABS(ABS(l.monto) - ABS(p.monto_libro)) <= 50)
        )
        DELETE p FROM #pend_libro p
        WHERE p.conciliacion_key IN (SELECT conciliacion_key FROM candidatos WHERE rn = 1);

        INSERT INTO #det_fila
        SELECT 'PAG_SIN_EXTRACTO', s._row_id, s._source_file, s._source_line, p.clave,
               CONCAT(ABS(p.monto_libro), N' el ', CONVERT(CHAR(10), p.fecha, 23))
        FROM #pend_libro p
        OUTER APPLY (SELECT TOP (1) x._row_id, x._source_file, x._source_line FROM stg.payments x
                     WHERE x.payment_id = p.clave AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_payments q
                           WHERE q.stg_row_id = x._row_id AND q.estado = 'EN_CUARENTENA') ORDER BY x._row_id) s
        WHERE p.origen = 'PAGO';
        INSERT INTO #det_fila
        SELECT 'COB_SIN_EXTRACTO', s._row_id, s._source_file, s._source_line, p.clave,
               CONCAT(ABS(p.monto_libro), N' el ', CONVERT(CHAR(10), p.fecha, 23))
        FROM #pend_libro p
        OUTER APPLY (SELECT TOP (1) x._row_id, x._source_file, x._source_line FROM stg.collections x
                     WHERE x.collection_id = p.clave AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_collections q
                           WHERE q.stg_row_id = x._row_id AND q.estado = 'EN_CUARENTENA') ORDER BY x._row_id) s
        WHERE p.origen = 'COBRANZA';
        INSERT INTO #ctl SELECT 'PAG_SIN_EXTRACTO', (SELECT COUNT(*) FROM dw.fact_pagos WHERE fecha_pago_key <= 
               CONVERT(INT, CONVERT(CHAR(8), @limite_transito, 112))), (SELECT COUNT(*) FROM #det_fila WHERE regla_id = 'PAG_SIN_EXTRACTO');
        INSERT INTO #ctl SELECT 'COB_SIN_EXTRACTO', (SELECT COUNT(*) FROM dw.fact_cobranzas WHERE fecha_cobranza_key <=
               CONVERT(INT, CONVERT(CHAR(8), @limite_transito, 112))), (SELECT COUNT(*) FROM #det_fila WHERE regla_id = 'COB_SIN_EXTRACTO');

        -- EXT_SIN_MATCH: transferencia del banco que quedó sin pareja, salvo que la explique un
        -- pago/cobranza en cuarentena (misma cuenta, importe parecido, fecha en la ventana o no
        -- confiable). También 1 a 1: cada fila en cuarentena explica como mucho una línea.
        WITH candidatos AS (
            SELECT k.conciliacion_key,
                   -- (tipo, erp_q): stg_row_id es único DENTRO de cada tabla de staging; un pago y una cobranza
                   -- pueden tener el mismo número, así que solo no alcanza para identificar la fila.
                   ROW_NUMBER() OVER (PARTITION BY e.tipo, e.erp_q ORDER BY ABS(e.monto_abs - ABS(k.monto_banco)),
                       ABS(DATEDIFF(DAY, ISNULL(e.fecha, f.fecha), f.fecha)), k.conciliacion_key) AS rn
            FROM dw.fact_conciliacion k
            JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
            JOIN dw.dim_fecha f ON f.fecha_key = k.fecha_banco_key
            JOIN #erp_cuarentena e
              ON e.account_id = c.cuenta_id AND e.tipo = IIF(k.monto_banco < 0, 'PAGO', 'COBRANZA')
             AND ABS(e.monto_abs - ABS(k.monto_banco)) <= 50
             AND (e.fecha IS NULL OR e.fecha > @fecha_corte OR f.fecha BETWEEN e.fecha AND DATEADD(DAY, 7, e.fecha))
            WHERE k.estado = 'PENDIENTE_EN_LIBROS'
        )
        SELECT conciliacion_key INTO #lineas_explicadas FROM candidatos WHERE rn = 1;

        INSERT INTO #det_fila
        SELECT 'EXT_SIN_MATCH', s._row_id, s._source_file, s._source_line, k.linea_extracto_id,
               CONCAT(k.monto_banco, N' el ', CONVERT(CHAR(10), f.fecha, 23))
        FROM dw.fact_conciliacion k
        JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
        JOIN dw.dim_fecha f ON f.fecha_key = k.fecha_banco_key
        OUTER APPLY (SELECT TOP (1) x._row_id, x._source_file, x._source_line FROM stg.bank_statements x
                     WHERE x.statement_line_id = k.linea_extracto_id AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q
                           WHERE q.stg_row_id = x._row_id AND q.estado = 'EN_CUARENTENA') ORDER BY x._row_id) s
        WHERE k.estado = 'PENDIENTE_EN_LIBROS'
          AND k.conciliacion_key NOT IN (SELECT conciliacion_key FROM #lineas_explicadas);
        INSERT INTO #ctl SELECT 'EXT_SIN_MATCH',
               (SELECT COUNT(*) FROM dw.fact_movimientos_bancarios m JOIN dw.dim_tipo_movimiento t
                ON t.tipo_movimiento_key = m.tipo_movimiento_key WHERE t.es_conciliable = 1),
               (SELECT COUNT(*) FROM #det_fila WHERE regla_id = 'EXT_SIN_MATCH');

        /* ---- registrar */
        BEGIN TRANSACTION;
        INSERT INTO audit.dq_resultados (ejecucion_id, regla_id, tabla, categoria, severidad, filas_evaluadas, filas_con_error)
        SELECT @ejecucion_id, r.regla_id, r.tabla, r.categoria, r.severidad, c.evaluadas, c.errores
        FROM #ctl c JOIN audit.dq_reglas r ON r.regla_id = c.regla_id AND r.activa = 1;
        INSERT INTO audit.dq_errores (ejecucion_id, regla_id, tabla, clave, valor)
        SELECT @ejecucion_id, d.regla_id, r.tabla, d.clave, d.valor
        FROM #det d JOIN audit.dq_reglas r ON r.regla_id = d.regla_id AND r.activa = 1;
        INSERT INTO audit.dq_errores (ejecucion_id, regla_id, tabla, stg_row_id, source_file, source_line, clave, valor)
        SELECT @ejecucion_id, d.regla_id, r.tabla, d.stg_row_id, d.source_file, d.source_line, d.clave, d.valor
        FROM #det_fila d JOIN audit.dq_reglas r ON r.regla_id = d.regla_id AND r.activa = 1;
        COMMIT;

        SELECT @msg_ok = STRING_AGG(CONCAT(regla_id, N'=', errores), N', ') WITHIN GROUP (ORDER BY regla_id)
        FROM #ctl WHERE errores > 0;
        SET @msg_ok = ISNULL(N'controles con diferencias: ' + @msg_ok, N'todos los controles cuadran');
        DECLARE @n_ctl INT = (SELECT COUNT(*) FROM #ctl), @n_dif INT = (SELECT COUNT(*) FROM #ctl WHERE errores > 0);
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @n_ctl, 0, 0, @n_dif, 0, @msg_ok;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE(), @num INT = ERROR_NUMBER(), @lin INT = ERROR_LINE(),
                @prc NVARCHAR(128) = ERROR_PROCEDURE();
        EXEC audit.usp_etl_log_fin @log_id, 'ERROR', @mensaje = @msg, @error_numero = @num,
             @error_linea = @lin, @error_proc = @prc;
        THROW;
    END CATCH
END;
GO
