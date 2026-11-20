/* =============================================================================
   04_usp_dq_controles_post_carga.sql — Totales de control DESPUÉS de cargar el DW.

   Analogía: es la cuadratura del cierre. Lo que vino en los archivos (sin lo que quedó
   en cuarentena) tiene que estar en el libro, en cantidad y en plata; y el saldo que
   informa el banco tiene que explicarse con los movimientos registrados.

     CTL_FILAS_*          filas válidas de staging (clave de negocio única, sin cuarentena) = filas en el DW
     CTL_MONTO_*          suma por moneda de staging válido = suma en el DW
     CTL_SALDO_EXTRACTO   saldo inicial + movimientos cargados = saldo final del banco (cuenta x mes)
     CTL_SALDO_CONTINUIDAD  el saldo final de un mes = el inicial del siguiente

   Son controles AGREGADOS: no apuntan a una fila de staging sino a una tabla, una
   moneda o una cuenta-mes (van a dq_errores con stg_row_id NULL y la clave en texto).
   Tienen sentido después de una carga completa o incremental "hasta hoy"; con una
   ventana cerrada (@fecha_hasta) el orquestador no los corre.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE audit.usp_dq_controles_post_carga
    @ejecucion_id UNIQUEIDENTIFIER = NULL
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

        /* ---- registrar */
        BEGIN TRANSACTION;
        INSERT INTO audit.dq_resultados (ejecucion_id, regla_id, tabla, categoria, severidad, filas_evaluadas, filas_con_error)
        SELECT @ejecucion_id, r.regla_id, r.tabla, r.categoria, r.severidad, c.evaluadas, c.errores
        FROM #ctl c JOIN audit.dq_reglas r ON r.regla_id = c.regla_id AND r.activa = 1;
        INSERT INTO audit.dq_errores (ejecucion_id, regla_id, tabla, clave, valor)
        SELECT @ejecucion_id, d.regla_id, r.tabla, d.clave, d.valor
        FROM #det d JOIN audit.dq_reglas r ON r.regla_id = d.regla_id AND r.activa = 1;
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
