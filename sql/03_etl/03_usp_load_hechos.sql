/* =============================================================================
   03_usp_load_hechos.sql — Carga de hechos desde staging, incremental por fecha.

   Mismo patrón para todos (ver 02_usp_load_dimensiones.sql):
     candidatos tipados (#cand) -> conteos y motivos -> transacción: UPDATE de lo que
     cambió + INSERT de lo nuevo -> avanzar marca de agua -> log.

   Conceptos que aparecen acá:
   - Ventana incremental: @fecha_desde/@fecha_hasta filtran por la fecha de negocio
     (fecha de pago, de imputación...). Si la fecha viene rota (NULL tras TRY_CONVERT),
     se usa el mes del archivo de origen ('2026-03/payments.csv'): así la fila cae en
     alguna ventana y queda contada como descartada, en vez de desaparecer en silencio.
   - Duplicados: ROW_NUMBER() OVER (PARTITION BY clave ORDER BY _row_id) sobre TODO
     staging (no solo la ventana): se queda con la primera aparición; si la copia cae
     en otra ventana (el banco reenvía la línea el mes siguiente), igual se reconoce.
   - Lookup "punto en el tiempo" de la contraparte SCD2: la versión cuya vigencia
     contiene la fecha del hecho. Si no hay, miembro -1 (no se pierde la fila).
   - Tipo de cambio: el último disponible a la fecha (CROSS/OUTER APPLY + TOP 1):
     fines de semana y días sin cotización usan el día hábil anterior.
   - UPDATE ... WHERE EXISTS (SELECT origen EXCEPT SELECT destino): detecta cambios
     tratando NULL = NULL; sin cambios, no se toca la fila (re-ejecutar no escribe nada).
   - El motivo de descarte es el PRIMERO que falla (orden del CASE). En la Fase 5 estas
     filas van a cuarentena con todas las reglas que violan.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- fact_tipo_cambio
   GRANO: moneda x día hábil. Va primero: los demás hechos lo usan para convertir a USD. */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_tipo_cambio
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_tipo_cambio';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @elim INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.currency AS moneda, s.source AS fuente,
                   TRY_CONVERT(DATE, s.rate_date, 23) AS fecha,
                   TRY_CONVERT(DECIMAL(19,6), s.rate_per_usd) AS tipo_cambio,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.rate_date, s.currency ORDER BY s._row_id) AS nro
            FROM stg.fx_rates s
            -- Fase 5: lo que la calidad de datos puso en cuarentena no entra al DW.
            WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_fx_rates q
                              WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA')
        )
        SELECT t.*, f.fecha_key, m.moneda_key,
               CASE WHEN t.fecha IS NULL THEN 'FECHA_INVALIDA'
                    WHEN f.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN t.tipo_cambio IS NULL THEN 'COTIZACION_INVALIDA'
                    WHEN t.tipo_cambio <= 0 THEN 'COTIZACION_NO_POSITIVA'
                    WHEN t.fuente IS NULL THEN 'FUENTE_NULA' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_fecha f ON f.fecha = t.fecha
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        WHERE COALESCE(t.fecha, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET tipo_cambio_por_usd = c.tipo_cambio, fuente = c.fuente, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_tipo_cambio f
        JOIN #cand c ON c.fecha_key = f.fecha_key AND c.moneda_key = f.moneda_key AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.tipo_cambio, c.fuente EXCEPT SELECT f.tipo_cambio_por_usd, f.fuente);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_tipo_cambio (fecha_key, moneda_key, tipo_cambio_por_usd, fuente)
        SELECT c.fecha_key, c.moneda_key, c.tipo_cambio, c.fuente
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_tipo_cambio f WHERE f.fecha_key = c.fecha_key AND f.moneda_key = c.moneda_key)
        ORDER BY c.fecha_key, c.moneda_key;
        SET @ins = @@ROWCOUNT;

        -- Retiro (Fase 5): cotizaciones ya cargadas cuyo origen ahora está en cuarentena (ej. un TC 10x),
        -- sin otra fila válida para ese día y moneda. Los hechos que lo usaban se recalculan en la carga.
        DELETE f FROM dw.fact_tipo_cambio f
        JOIN dw.dim_fecha d ON d.fecha_key = f.fecha_key
        JOIN dw.dim_moneda m ON m.moneda_key = f.moneda_key
        WHERE EXISTS (SELECT 1 FROM audit.cuarentena_fx_rates q
                      WHERE q.estado = 'EN_CUARENTENA' AND q.currency = m.codigo_iso
                        AND TRY_CONVERT(DATE, q.rate_date, 23) = d.fecha)
          AND NOT EXISTS (SELECT 1 FROM stg.fx_rates s
                          WHERE s.currency = m.codigo_iso AND TRY_CONVERT(DATE, s.rate_date, 23) = d.fecha
                            AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_fx_rates q2
                                            WHERE q2.stg_row_id = s._row_id AND q2.estado = 'EN_CUARENTENA'));
        SET @elim = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_tipo_cambio', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos,
             @eliminadas = @elim;
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

/* ---------------------------------------------------------------- fact_facturas
   GRANO: una fila por factura. Ventana por fecha de emisión. TC y versión de la
   contraparte: los vigentes el día de emisión. */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_facturas
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_facturas';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @elim INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.invoice_id AS factura_id, s.invoice_number AS numero_factura,
                   s.counterparty_id AS contraparte_id, s.invoice_type AS tipo_factura, s.currency AS moneda,
                   s.description AS descripcion,
                   TRY_CONVERT(DATE, s.issue_date, 23) AS fecha_emision,
                   TRY_CONVERT(DATE, s.due_date, 23) AS fecha_vencimiento,
                   TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.invoice_id ORDER BY s._row_id) AS nro
            FROM stg.invoices s
            -- Fase 5: lo que la calidad de datos puso en cuarentena no entra al DW.
            WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_invoices q
                              WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA')
        )
        SELECT t.*, m.moneda_key, fe.fecha_key AS fecha_emision_key, fv.fecha_key AS fecha_vencimiento_key,
               ISNULL(cp.contraparte_key, -1) AS contraparte_key, tc.tipo_cambio_por_usd AS tipo_cambio_usd,
               CAST(ROUND(t.monto / tc.tipo_cambio_por_usd, 2) AS DECIMAL(19,2)) AS monto_usd,
               CASE WHEN t.factura_id IS NULL THEN 'CLAVE_NULA'
                    WHEN t.numero_factura IS NULL THEN 'NUMERO_NULO'
                    WHEN t.tipo_factura IS NULL OR t.tipo_factura NOT IN ('AP', 'AR') THEN 'TIPO_INVALIDO'
                    WHEN t.fecha_emision IS NULL THEN 'FECHA_EMISION_INVALIDA'
                    WHEN t.fecha_vencimiento IS NULL THEN 'FECHA_VENCIMIENTO_INVALIDA'
                    WHEN fe.fecha_key IS NULL OR fv.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN t.fecha_vencimiento < t.fecha_emision THEN 'VENCIMIENTO_ANTERIOR_A_EMISION'
                    WHEN t.monto IS NULL THEN 'MONTO_INVALIDO'
                    WHEN t.monto <= 0 THEN 'MONTO_NO_POSITIVO'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN tc.tipo_cambio_por_usd IS NULL THEN 'SIN_TIPO_DE_CAMBIO'
                    WHEN ROUND(t.monto / tc.tipo_cambio_por_usd, 2) <= 0 THEN 'MONTO_USD_CERO' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        LEFT JOIN dw.dim_fecha fe ON fe.fecha = t.fecha_emision
        LEFT JOIN dw.dim_fecha fv ON fv.fecha = t.fecha_vencimiento
        OUTER APPLY (SELECT TOP (1) x.tipo_cambio_por_usd FROM dw.fact_tipo_cambio x
                     WHERE x.moneda_key = m.moneda_key AND x.fecha_key <= fe.fecha_key
                     ORDER BY x.fecha_key DESC) tc
        OUTER APPLY (SELECT TOP (1) d.contraparte_key FROM dw.dim_contraparte d
                     WHERE d.contraparte_id = t.contraparte_id
                       AND t.fecha_emision BETWEEN d.vigente_desde AND d.vigente_hasta) cp
        WHERE COALESCE(t.fecha_emision, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha_emision) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha_emision <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET numero_factura = c.numero_factura, tipo_factura = c.tipo_factura, contraparte_key = c.contraparte_key,
            moneda_key = c.moneda_key, fecha_emision_key = c.fecha_emision_key,
            fecha_vencimiento_key = c.fecha_vencimiento_key, monto = c.monto, tipo_cambio_usd = c.tipo_cambio_usd,
            monto_usd = c.monto_usd, descripcion = c.descripcion, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_facturas f
        JOIN #cand c ON c.factura_id = f.factura_id AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.numero_factura, c.tipo_factura, c.contraparte_key, c.moneda_key, c.fecha_emision_key,
                             c.fecha_vencimiento_key, c.monto, c.tipo_cambio_usd, c.monto_usd, c.descripcion
                      EXCEPT
                      SELECT f.numero_factura, f.tipo_factura, f.contraparte_key, f.moneda_key, f.fecha_emision_key,
                             f.fecha_vencimiento_key, f.monto, f.tipo_cambio_usd, f.monto_usd, f.descripcion);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_facturas (factura_id, numero_factura, tipo_factura, contraparte_key, moneda_key,
                    fecha_emision_key, fecha_vencimiento_key, monto, tipo_cambio_usd, monto_usd, descripcion)
        SELECT c.factura_id, c.numero_factura, c.tipo_factura, c.contraparte_key, c.moneda_key, c.fecha_emision_key,
               c.fecha_vencimiento_key, c.monto, c.tipo_cambio_usd, c.monto_usd, c.descripcion
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_facturas f WHERE f.factura_id = c.factura_id)
        ORDER BY c.fecha_emision, c.factura_id;
        SET @ins = @@ROWCOUNT;

        -- Retiro (Fase 5): filas que ya estaban en el DW y cuyo origen ahora está en cuarentena,
        -- sin otra fila válida en staging con la misma clave. No se pierden: quedan en la cuarentena.
        DELETE f FROM dw.fact_facturas f
        WHERE EXISTS (SELECT 1 FROM audit.cuarentena_invoices q WHERE q.invoice_id = f.factura_id AND q.estado = 'EN_CUARENTENA')
          AND NOT EXISTS (SELECT 1 FROM stg.invoices s
                          WHERE s.invoice_id = f.factura_id
                            AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_invoices q2
                                            WHERE q2.stg_row_id = s._row_id AND q2.estado = 'EN_CUARENTENA'));
        SET @elim = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_facturas', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos,
             @eliminadas = @elim;
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

/* ---------------------------------------------------------------- fact_pagos
   GRANO: un pago ejecutado. Ventana por fecha de pago. Contraparte o cuenta que no
   existen -> miembro -1 (la fila entra; la Fase 5 decide si va a cuarentena). */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_pagos
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_pagos';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @elim INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.payment_id AS pago_id, s.payment_reference AS referencia_pago,
                   s.invoice_id AS factura_id, s.counterparty_id AS contraparte_id, s.account_id AS cuenta_id,
                   s.currency AS moneda, s.payment_method AS medio_pago,
                   TRY_CONVERT(DATE, s.payment_date, 23) AS fecha_pago,
                   TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.payment_id ORDER BY s._row_id) AS nro
            FROM stg.payments s
            -- Fase 5: lo que la calidad de datos puso en cuarentena no entra al DW.
            WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_payments q
                              WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA')
        )
        SELECT t.*, m.moneda_key, fp.fecha_key AS fecha_pago_key,
               ISNULL(cp.contraparte_key, -1) AS contraparte_key, ISNULL(bc.banco_cuenta_key, -1) AS banco_cuenta_key,
               tc.tipo_cambio_por_usd AS tipo_cambio_usd,
               CAST(ROUND(t.monto / tc.tipo_cambio_por_usd, 2) AS DECIMAL(19,2)) AS monto_usd,
               DATEDIFF(DAY, vto.fecha, t.fecha_pago) AS dias_vs_vencimiento,
               CASE WHEN t.pago_id IS NULL THEN 'CLAVE_NULA'
                    WHEN t.referencia_pago IS NULL THEN 'REFERENCIA_NULA'
                    WHEN t.factura_id IS NULL THEN 'FACTURA_NULA'
                    WHEN t.medio_pago IS NULL THEN 'MEDIO_NULO'
                    WHEN t.fecha_pago IS NULL THEN 'FECHA_INVALIDA'
                    WHEN fp.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN t.monto IS NULL THEN 'MONTO_INVALIDO'
                    WHEN t.monto <= 0 THEN 'MONTO_NO_POSITIVO'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN tc.tipo_cambio_por_usd IS NULL THEN 'SIN_TIPO_DE_CAMBIO'
                    WHEN ROUND(t.monto / tc.tipo_cambio_por_usd, 2) <= 0 THEN 'MONTO_USD_CERO' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        LEFT JOIN dw.dim_fecha fp ON fp.fecha = t.fecha_pago
        LEFT JOIN dw.dim_banco_cuenta bc ON bc.cuenta_id = t.cuenta_id
        LEFT JOIN dw.fact_facturas fa ON fa.factura_id = t.factura_id
        LEFT JOIN dw.dim_fecha vto ON vto.fecha_key = fa.fecha_vencimiento_key
        OUTER APPLY (SELECT TOP (1) x.tipo_cambio_por_usd FROM dw.fact_tipo_cambio x
                     WHERE x.moneda_key = m.moneda_key AND x.fecha_key <= fp.fecha_key
                     ORDER BY x.fecha_key DESC) tc
        OUTER APPLY (SELECT TOP (1) d.contraparte_key FROM dw.dim_contraparte d
                     WHERE d.contraparte_id = t.contraparte_id
                       AND t.fecha_pago BETWEEN d.vigente_desde AND d.vigente_hasta) cp
        WHERE COALESCE(t.fecha_pago, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha_pago) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha_pago <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET referencia_pago = c.referencia_pago, factura_id = c.factura_id, contraparte_key = c.contraparte_key,
            banco_cuenta_key = c.banco_cuenta_key, moneda_key = c.moneda_key, fecha_pago_key = c.fecha_pago_key,
            medio_pago = c.medio_pago, monto = c.monto, tipo_cambio_usd = c.tipo_cambio_usd, monto_usd = c.monto_usd,
            dias_vs_vencimiento = c.dias_vs_vencimiento, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_pagos f
        JOIN #cand c ON c.pago_id = f.pago_id AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.referencia_pago, c.factura_id, c.contraparte_key, c.banco_cuenta_key, c.moneda_key,
                             c.fecha_pago_key, c.medio_pago, c.monto, c.tipo_cambio_usd, c.monto_usd, c.dias_vs_vencimiento
                      EXCEPT
                      SELECT f.referencia_pago, f.factura_id, f.contraparte_key, f.banco_cuenta_key, f.moneda_key,
                             f.fecha_pago_key, f.medio_pago, f.monto, f.tipo_cambio_usd, f.monto_usd, f.dias_vs_vencimiento);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_pagos (pago_id, referencia_pago, factura_id, contraparte_key, banco_cuenta_key, moneda_key,
                    fecha_pago_key, medio_pago, monto, tipo_cambio_usd, monto_usd, dias_vs_vencimiento)
        SELECT c.pago_id, c.referencia_pago, c.factura_id, c.contraparte_key, c.banco_cuenta_key, c.moneda_key,
               c.fecha_pago_key, c.medio_pago, c.monto, c.tipo_cambio_usd, c.monto_usd, c.dias_vs_vencimiento
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_pagos f WHERE f.pago_id = c.pago_id)
        ORDER BY c.fecha_pago, c.pago_id;
        SET @ins = @@ROWCOUNT;

        -- Retiro (Fase 5): filas que ya estaban en el DW y cuyo origen ahora está en cuarentena,
        -- sin otra fila válida en staging con la misma clave. No se pierden: quedan en la cuarentena.
        DELETE f FROM dw.fact_pagos f
        WHERE EXISTS (SELECT 1 FROM audit.cuarentena_payments q WHERE q.payment_id = f.pago_id AND q.estado = 'EN_CUARENTENA')
          AND NOT EXISTS (SELECT 1 FROM stg.payments s
                          WHERE s.payment_id = f.pago_id
                            AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_payments q2
                                            WHERE q2.stg_row_id = s._row_id AND q2.estado = 'EN_CUARENTENA'));
        SET @elim = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_pagos', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos,
             @eliminadas = @elim;
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

/* ---------------------------------------------------------------- fact_cobranzas
   GRANO: una cobranza recibida. Espejo de fact_pagos; dias_atraso = cobro - vencimiento. */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_cobranzas
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_cobranzas';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @elim INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.collection_id AS cobranza_id, s.collection_reference AS referencia_cobranza,
                   s.invoice_id AS factura_id, s.counterparty_id AS contraparte_id, s.account_id AS cuenta_id,
                   s.currency AS moneda, s.collection_method AS medio_cobro,
                   TRY_CONVERT(DATE, s.collection_date, 23) AS fecha_cobranza,
                   TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.collection_id ORDER BY s._row_id) AS nro
            FROM stg.collections s
            -- Fase 5: lo que la calidad de datos puso en cuarentena no entra al DW.
            WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_collections q
                              WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA')
        )
        SELECT t.*, m.moneda_key, fc.fecha_key AS fecha_cobranza_key,
               ISNULL(cp.contraparte_key, -1) AS contraparte_key, ISNULL(bc.banco_cuenta_key, -1) AS banco_cuenta_key,
               tc.tipo_cambio_por_usd AS tipo_cambio_usd,
               CAST(ROUND(t.monto / tc.tipo_cambio_por_usd, 2) AS DECIMAL(19,2)) AS monto_usd,
               DATEDIFF(DAY, vto.fecha, t.fecha_cobranza) AS dias_atraso,
               CASE WHEN t.cobranza_id IS NULL THEN 'CLAVE_NULA'
                    WHEN t.referencia_cobranza IS NULL THEN 'REFERENCIA_NULA'
                    WHEN t.factura_id IS NULL THEN 'FACTURA_NULA'
                    WHEN t.medio_cobro IS NULL THEN 'MEDIO_NULO'
                    WHEN t.fecha_cobranza IS NULL THEN 'FECHA_INVALIDA'
                    WHEN fc.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN t.monto IS NULL THEN 'MONTO_INVALIDO'
                    WHEN t.monto <= 0 THEN 'MONTO_NO_POSITIVO'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN tc.tipo_cambio_por_usd IS NULL THEN 'SIN_TIPO_DE_CAMBIO'
                    WHEN ROUND(t.monto / tc.tipo_cambio_por_usd, 2) <= 0 THEN 'MONTO_USD_CERO' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        LEFT JOIN dw.dim_fecha fc ON fc.fecha = t.fecha_cobranza
        LEFT JOIN dw.dim_banco_cuenta bc ON bc.cuenta_id = t.cuenta_id
        LEFT JOIN dw.fact_facturas fa ON fa.factura_id = t.factura_id
        LEFT JOIN dw.dim_fecha vto ON vto.fecha_key = fa.fecha_vencimiento_key
        OUTER APPLY (SELECT TOP (1) x.tipo_cambio_por_usd FROM dw.fact_tipo_cambio x
                     WHERE x.moneda_key = m.moneda_key AND x.fecha_key <= fc.fecha_key
                     ORDER BY x.fecha_key DESC) tc
        OUTER APPLY (SELECT TOP (1) d.contraparte_key FROM dw.dim_contraparte d
                     WHERE d.contraparte_id = t.contraparte_id
                       AND t.fecha_cobranza BETWEEN d.vigente_desde AND d.vigente_hasta) cp
        WHERE COALESCE(t.fecha_cobranza, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha_cobranza) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha_cobranza <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET referencia_cobranza = c.referencia_cobranza, factura_id = c.factura_id, contraparte_key = c.contraparte_key,
            banco_cuenta_key = c.banco_cuenta_key, moneda_key = c.moneda_key, fecha_cobranza_key = c.fecha_cobranza_key,
            medio_cobro = c.medio_cobro, monto = c.monto, tipo_cambio_usd = c.tipo_cambio_usd, monto_usd = c.monto_usd,
            dias_atraso = c.dias_atraso, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_cobranzas f
        JOIN #cand c ON c.cobranza_id = f.cobranza_id AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.referencia_cobranza, c.factura_id, c.contraparte_key, c.banco_cuenta_key, c.moneda_key,
                             c.fecha_cobranza_key, c.medio_cobro, c.monto, c.tipo_cambio_usd, c.monto_usd, c.dias_atraso
                      EXCEPT
                      SELECT f.referencia_cobranza, f.factura_id, f.contraparte_key, f.banco_cuenta_key, f.moneda_key,
                             f.fecha_cobranza_key, f.medio_cobro, f.monto, f.tipo_cambio_usd, f.monto_usd, f.dias_atraso);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_cobranzas (cobranza_id, referencia_cobranza, factura_id, contraparte_key, banco_cuenta_key,
                    moneda_key, fecha_cobranza_key, medio_cobro, monto, tipo_cambio_usd, monto_usd, dias_atraso)
        SELECT c.cobranza_id, c.referencia_cobranza, c.factura_id, c.contraparte_key, c.banco_cuenta_key, c.moneda_key,
               c.fecha_cobranza_key, c.medio_cobro, c.monto, c.tipo_cambio_usd, c.monto_usd, c.dias_atraso
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_cobranzas f WHERE f.cobranza_id = c.cobranza_id)
        ORDER BY c.fecha_cobranza, c.cobranza_id;
        SET @ins = @@ROWCOUNT;

        -- Retiro (Fase 5): filas que ya estaban en el DW y cuyo origen ahora está en cuarentena,
        -- sin otra fila válida en staging con la misma clave. No se pierden: quedan en la cuarentena.
        DELETE f FROM dw.fact_cobranzas f
        WHERE EXISTS (SELECT 1 FROM audit.cuarentena_collections q WHERE q.collection_id = f.cobranza_id AND q.estado = 'EN_CUARENTENA')
          AND NOT EXISTS (SELECT 1 FROM stg.collections s
                          WHERE s.collection_id = f.cobranza_id
                            AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_collections q2
                                            WHERE q2.stg_row_id = s._row_id AND q2.estado = 'EN_CUARENTENA'));
        SET @elim = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_cobranzas', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos,
             @eliminadas = @elim;
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

/* ---------------------------------------------------------------- fact_movimientos_bancarios
   GRANO: una línea del extracto, una sola vez. El extracto trae el NÚMERO de cuenta
   (como un MT940), no nuestro id: se busca la cuenta por numero_cuenta. Ventana por
   fecha de imputación. */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_movimientos_bancarios
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_movimientos_bancarios';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @elim INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.statement_line_id AS linea_extracto_id, s.account_number AS numero_cuenta,
                   s.currency AS moneda, s.bank_tx_code AS codigo, s.description AS descripcion,
                   s.bank_reference AS referencia_banco,
                   TRY_CONVERT(DATE, s.booking_date, 23) AS fecha_imputacion,
                   TRY_CONVERT(DATE, s.value_date, 23) AS fecha_valor,
                   TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.statement_line_id ORDER BY s._row_id) AS nro
            FROM stg.bank_statements s
            -- Fase 5: lo que la calidad de datos puso en cuarentena no entra al DW.
            WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q
                              WHERE q.stg_row_id = s._row_id AND q.estado = 'EN_CUARENTENA')
        )
        SELECT t.*, m.moneda_key, fi.fecha_key AS fecha_imputacion_key, fv.fecha_key AS fecha_valor_key,
               ISNULL(bc.banco_cuenta_key, -1) AS banco_cuenta_key,
               ISNULL(tm.tipo_movimiento_key, -1) AS tipo_movimiento_key,
               tc.tipo_cambio_por_usd AS tipo_cambio_usd,
               CAST(ROUND(t.monto / tc.tipo_cambio_por_usd, 2) AS DECIMAL(19,2)) AS monto_usd,
               CASE WHEN t.linea_extracto_id IS NULL THEN 'CLAVE_NULA'
                    WHEN t.fecha_imputacion IS NULL THEN 'FECHA_INVALIDA'
                    WHEN t.fecha_valor IS NULL THEN 'FECHA_VALOR_INVALIDA'
                    WHEN fi.fecha_key IS NULL OR fv.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN t.monto IS NULL THEN 'MONTO_INVALIDO'
                    WHEN t.monto = 0 THEN 'MONTO_CERO'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN tc.tipo_cambio_por_usd IS NULL THEN 'SIN_TIPO_DE_CAMBIO' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        LEFT JOIN dw.dim_fecha fi ON fi.fecha = t.fecha_imputacion
        LEFT JOIN dw.dim_fecha fv ON fv.fecha = t.fecha_valor
        LEFT JOIN dw.dim_banco_cuenta bc ON bc.numero_cuenta = t.numero_cuenta
        LEFT JOIN dw.dim_tipo_movimiento tm ON tm.codigo = t.codigo
        OUTER APPLY (SELECT TOP (1) x.tipo_cambio_por_usd FROM dw.fact_tipo_cambio x
                     WHERE x.moneda_key = m.moneda_key AND x.fecha_key <= fi.fecha_key
                     ORDER BY x.fecha_key DESC) tc
        WHERE COALESCE(t.fecha_imputacion, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha_imputacion) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha_imputacion <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET banco_cuenta_key = c.banco_cuenta_key, moneda_key = c.moneda_key, tipo_movimiento_key = c.tipo_movimiento_key,
            fecha_imputacion_key = c.fecha_imputacion_key, fecha_valor_key = c.fecha_valor_key, monto = c.monto,
            tipo_cambio_usd = c.tipo_cambio_usd, monto_usd = c.monto_usd, descripcion = c.descripcion,
            referencia_banco = c.referencia_banco, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_movimientos_bancarios f
        JOIN #cand c ON c.linea_extracto_id = f.linea_extracto_id AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.banco_cuenta_key, c.moneda_key, c.tipo_movimiento_key, c.fecha_imputacion_key,
                             c.fecha_valor_key, c.monto, c.tipo_cambio_usd, c.monto_usd, c.descripcion, c.referencia_banco
                      EXCEPT
                      SELECT f.banco_cuenta_key, f.moneda_key, f.tipo_movimiento_key, f.fecha_imputacion_key,
                             f.fecha_valor_key, f.monto, f.tipo_cambio_usd, f.monto_usd, f.descripcion, f.referencia_banco);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_movimientos_bancarios (linea_extracto_id, banco_cuenta_key, moneda_key, tipo_movimiento_key,
                    fecha_imputacion_key, fecha_valor_key, monto, tipo_cambio_usd, monto_usd, descripcion, referencia_banco)
        SELECT c.linea_extracto_id, c.banco_cuenta_key, c.moneda_key, c.tipo_movimiento_key, c.fecha_imputacion_key,
               c.fecha_valor_key, c.monto, c.tipo_cambio_usd, c.monto_usd, c.descripcion, c.referencia_banco
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_movimientos_bancarios f WHERE f.linea_extracto_id = c.linea_extracto_id)
        ORDER BY c.fecha_imputacion, c.linea_extracto_id;
        SET @ins = @@ROWCOUNT;

        -- Retiro (Fase 5): filas que ya estaban en el DW y cuyo origen ahora está en cuarentena,
        -- sin otra fila válida en staging con la misma clave. No se pierden: quedan en la cuarentena.
        DELETE f FROM dw.fact_movimientos_bancarios f
        WHERE EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q WHERE q.statement_line_id = f.linea_extracto_id AND q.estado = 'EN_CUARENTENA')
          AND NOT EXISTS (SELECT 1 FROM stg.bank_statements s
                          WHERE s.statement_line_id = f.linea_extracto_id
                            AND NOT EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q2
                                            WHERE q2.stg_row_id = s._row_id AND q2.estado = 'EN_CUARENTENA'));
        SET @elim = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_movimientos_bancarios', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos,
             @eliminadas = @elim;
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

/* ---------------------------------------------------------------- fact_saldo_bancario_mensual
   GRANO: cuenta x mes. El período 'AAAA-MM' se convierte en la clave del último día del
   mes (EOMONTH). Si el saldo informado no cuadra (inicial + créditos + débitos <> final)
   se descarta: es exactamente lo que verifica la cuadratura de un extracto. */
CREATE OR ALTER PROCEDURE dw.usp_load_fact_saldo_bancario_mensual
    @ejecucion_id UNIQUEIDENTIFIER = NULL,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_saldo_bancario_mensual';
    DECLARE @log_id INT, @leidas INT, @ins INT, @upd INT, @descartadas INT, @duplicadas INT,
            @motivos NVARCHAR(4000), @max DATE;
    SELECT @ejecucion_id = ISNULL(@ejecucion_id, NEWID()), @fecha_desde = ISNULL(@fecha_desde, '19000101'),
           @fecha_hasta = ISNULL(@fecha_hasta, '99991231');
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        WITH tipado AS (
            SELECT s._row_id, s.account_number AS numero_cuenta, s.currency AS moneda,
                   EOMONTH(TRY_CONVERT(DATE, s.period + '-01', 23)) AS fecha_cierre,
                   TRY_CONVERT(DECIMAL(19,2), s.opening_balance) AS saldo_inicial,
                   TRY_CONVERT(DECIMAL(19,2), s.total_credits) AS total_creditos,
                   TRY_CONVERT(DECIMAL(19,2), s.total_debits) AS total_debitos,
                   TRY_CONVERT(DECIMAL(19,2), s.closing_balance) AS saldo_final,
                   TRY_CONVERT(INT, s.line_count) AS cantidad_movimientos,
                   TRY_CONVERT(DATE, LEFT(s._source_file, 7) + '-01', 23) AS mes_archivo,
                   ROW_NUMBER() OVER (PARTITION BY s.account_number, s.period ORDER BY s._row_id) AS nro
            FROM stg.bank_balances s
        )
        SELECT t.*, f.fecha_key AS fecha_cierre_key, m.moneda_key, bc.banco_cuenta_key,
               CASE WHEN t.fecha_cierre IS NULL THEN 'PERIODO_INVALIDO'
                    WHEN f.fecha_key IS NULL THEN 'FECHA_FUERA_DE_CALENDARIO'
                    WHEN bc.banco_cuenta_key IS NULL THEN 'CUENTA_DESCONOCIDA'
                    WHEN m.moneda_key IS NULL THEN 'MONEDA_DESCONOCIDA'
                    WHEN t.saldo_inicial IS NULL OR t.total_creditos IS NULL OR t.total_debitos IS NULL
                         OR t.saldo_final IS NULL OR t.cantidad_movimientos IS NULL THEN 'IMPORTE_INVALIDO'
                    WHEN t.total_creditos < 0 OR t.total_debitos > 0 OR t.cantidad_movimientos < 0 THEN 'TOTALES_INVALIDOS'
                    WHEN t.saldo_inicial + t.total_creditos + t.total_debitos <> t.saldo_final THEN 'NO_CUADRA' END AS motivo
        INTO #cand
        FROM tipado t
        LEFT JOIN dw.dim_fecha f ON f.fecha = t.fecha_cierre
        LEFT JOIN dw.dim_moneda m ON m.codigo_iso = t.moneda AND m.moneda_key > 0
        LEFT JOIN dw.dim_banco_cuenta bc ON bc.numero_cuenta = t.numero_cuenta AND bc.banco_cuenta_key > 0
        WHERE COALESCE(t.fecha_cierre, t.mes_archivo) BETWEEN @fecha_desde AND @fecha_hasta;

        SELECT @leidas = COUNT(*), @duplicadas = ISNULL(SUM(IIF(nro > 1, 1, 0)), 0),
               @descartadas = ISNULL(SUM(IIF(nro = 1 AND motivo IS NOT NULL, 1, 0)), 0)
        FROM #cand;
        -- Marca de agua = última fecha VÁLIDA y no futura. Una fecha futura (error de tipeo) la
        -- empujaría hacia adelante y la próxima corrida incremental se saltearía lo del medio.
        SELECT @max = MAX(fecha_cierre) FROM #cand
        WHERE nro = 1 AND motivo IS NULL AND fecha_cierre <= CAST(SYSUTCDATETIME() AS DATE);
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ') WITHIN GROUP (ORDER BY motivo)
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        UPDATE f
        SET moneda_key = c.moneda_key, saldo_inicial = c.saldo_inicial, total_creditos = c.total_creditos,
            total_debitos = c.total_debitos, saldo_final = c.saldo_final,
            cantidad_movimientos = c.cantidad_movimientos, fecha_carga_dw = SYSUTCDATETIME()
        FROM dw.fact_saldo_bancario_mensual f
        JOIN #cand c ON c.banco_cuenta_key = f.banco_cuenta_key AND c.fecha_cierre_key = f.fecha_cierre_key
                    AND c.nro = 1 AND c.motivo IS NULL
        WHERE EXISTS (SELECT c.moneda_key, c.saldo_inicial, c.total_creditos, c.total_debitos, c.saldo_final,
                             c.cantidad_movimientos
                      EXCEPT
                      SELECT f.moneda_key, f.saldo_inicial, f.total_creditos, f.total_debitos, f.saldo_final,
                             f.cantidad_movimientos);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dw.fact_saldo_bancario_mensual (banco_cuenta_key, fecha_cierre_key, moneda_key, saldo_inicial,
                    total_creditos, total_debitos, saldo_final, cantidad_movimientos)
        SELECT c.banco_cuenta_key, c.fecha_cierre_key, c.moneda_key, c.saldo_inicial, c.total_creditos,
               c.total_debitos, c.saldo_final, c.cantidad_movimientos
        FROM #cand c
        WHERE c.nro = 1 AND c.motivo IS NULL
          AND NOT EXISTS (SELECT 1 FROM dw.fact_saldo_bancario_mensual f
                          WHERE f.banco_cuenta_key = c.banco_cuenta_key AND f.fecha_cierre_key = c.fecha_cierre_key)
        ORDER BY c.fecha_cierre_key, c.banco_cuenta_key;
        SET @ins = @@ROWCOUNT;

        EXEC audit.usp_etl_avanzar_marca N'fact_saldo_bancario_mensual', @max;
        COMMIT;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos;
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
