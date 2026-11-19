/* =============================================================================
   04_usp_load_conciliacion.sql — Alta y actualización de partidas de conciliación
   (fact_conciliacion, snapshot acumulativo).

   Qué hace el ETL (Fase 4) y qué hace la conciliación (Fase 6):
   - ACÁ: cada pago y cada cobranza del DW abre su partida (PENDIENTE_EN_BANCO) y cada
     transferencia del banco sin partida abre la suya (PENDIENTE_EN_LIBROS). Si el hecho
     de origen cambia (ej. se corrigió el monto), la partida pendiente se actualiza.
   - EN LA FASE 6: el proceso de matching (referencia, monto, fecha, tolerancia) une una
     partida de libros con una del banco y la pasa a CONCILIADA / CON_DIFERENCIA.
   Es como armar la planilla de conciliación: primero se vuelcan las dos columnas
   (libros y banco) y después se van tildando los pares.

   No usa ventana de fechas: trabaja sobre lo que ya está en el DW (hechos validados) y
   solo agrega lo que falta (NOT EXISTS), así que re-ejecutarlo no cambia nada.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE dw.usp_load_fact_conciliacion
    @ejecucion_id UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_fact_conciliacion';
    DECLARE @log_id INT, @pagos INT, @cobranzas INT, @banco INT, @upd_libro INT, @upd_banco INT, @leidas INT;
    DECLARE @altas TABLE (origen VARCHAR(10));
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        SELECT @leidas = (SELECT COUNT(*) FROM dw.fact_pagos) + (SELECT COUNT(*) FROM dw.fact_cobranzas)
                       + (SELECT COUNT(*) FROM dw.fact_movimientos_bancarios m
                          JOIN dw.dim_tipo_movimiento t ON t.tipo_movimiento_key = m.tipo_movimiento_key
                          WHERE t.es_conciliable = 1);

        -- Lado "libros" en un solo conjunto: pagos con signo negativo (salen del banco),
        -- cobranzas positivo (entran). Así se comparan directo con el monto del extracto.
        SELECT 'PAGO' AS origen, p.pago_id, CAST(NULL AS NVARCHAR(20)) AS cobranza_id, p.factura_id,
               p.contraparte_key, p.banco_cuenta_key, p.moneda_key, p.fecha_pago_key AS fecha_libro_key,
               -p.monto AS monto_libro
        INTO #libros
        FROM dw.fact_pagos p
        UNION ALL
        SELECT 'COBRANZA', NULL, c.cobranza_id, c.factura_id, c.contraparte_key, c.banco_cuenta_key, c.moneda_key,
               c.fecha_cobranza_key, c.monto
        FROM dw.fact_cobranzas c;

        BEGIN TRANSACTION;

        -- 1. Partidas pendientes de libros que cambiaron en el hecho de origen (snapshot acumulativo:
        --    la fila se actualiza). Las ya conciliadas no se tocan desde acá.
        UPDATE k
        SET contraparte_key = l.contraparte_key, banco_cuenta_key = l.banco_cuenta_key, moneda_key = l.moneda_key,
            factura_id = l.factura_id, fecha_libro_key = l.fecha_libro_key, monto_libro = l.monto_libro,
            fecha_emision_factura_key = ISNULL(f.fecha_emision_key, -1),
            fecha_vencimiento_key = ISNULL(f.fecha_vencimiento_key, -1),
            fecha_actualizacion_dw = SYSUTCDATETIME()
        FROM dw.fact_conciliacion k
        JOIN #libros l ON (l.pago_id = k.pago_id OR l.cobranza_id = k.cobranza_id)
        LEFT JOIN dw.fact_facturas f ON f.factura_id = l.factura_id
        WHERE k.estado = 'PENDIENTE_EN_BANCO'
          AND EXISTS (SELECT l.contraparte_key, l.banco_cuenta_key, l.moneda_key, l.factura_id, l.fecha_libro_key,
                             l.monto_libro, ISNULL(f.fecha_emision_key, -1), ISNULL(f.fecha_vencimiento_key, -1)
                      EXCEPT
                      SELECT k.contraparte_key, k.banco_cuenta_key, k.moneda_key, k.factura_id, k.fecha_libro_key,
                             k.monto_libro, k.fecha_emision_factura_key, k.fecha_vencimiento_key);
        SET @upd_libro = @@ROWCOUNT;

        -- 2. Alta de partidas de libros nuevas. Factura inexistente -> hitos de factura en -1 (desconocida).
        INSERT INTO dw.fact_conciliacion (origen, pago_id, cobranza_id, factura_id, contraparte_key, banco_cuenta_key,
                    moneda_key, fecha_emision_factura_key, fecha_vencimiento_key, fecha_libro_key, monto_libro, estado)
        OUTPUT inserted.origen INTO @altas
        SELECT l.origen, l.pago_id, l.cobranza_id, l.factura_id, l.contraparte_key, l.banco_cuenta_key, l.moneda_key,
               ISNULL(f.fecha_emision_key, -1), ISNULL(f.fecha_vencimiento_key, -1), l.fecha_libro_key, l.monto_libro,
               'PENDIENTE_EN_BANCO'
        FROM #libros l
        LEFT JOIN dw.fact_facturas f ON f.factura_id = l.factura_id
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_conciliacion k
                          WHERE k.pago_id = l.pago_id OR k.cobranza_id = l.cobranza_id)
        ORDER BY l.fecha_libro_key, l.origen, l.pago_id, l.cobranza_id;
        SELECT @pagos = ISNULL(SUM(IIF(origen = 'PAGO', 1, 0)), 0), @cobranzas = ISNULL(SUM(IIF(origen = 'COBRANZA', 1, 0)), 0)
        FROM @altas;   -- lo que devolvió el OUTPUT del INSERT: exactamente las filas nuevas

        -- 3. Partidas del banco pendientes cuyo movimiento cambió.
        UPDATE k
        SET banco_cuenta_key = m.banco_cuenta_key, moneda_key = m.moneda_key, fecha_banco_key = m.fecha_imputacion_key,
            monto_banco = m.monto, fecha_actualizacion_dw = SYSUTCDATETIME()
        FROM dw.fact_conciliacion k
        JOIN dw.fact_movimientos_bancarios m ON m.linea_extracto_id = k.linea_extracto_id
        WHERE k.estado = 'PENDIENTE_EN_LIBROS'
          AND EXISTS (SELECT m.banco_cuenta_key, m.moneda_key, m.fecha_imputacion_key, m.monto
                      EXCEPT SELECT k.banco_cuenta_key, k.moneda_key, k.fecha_banco_key, k.monto_banco);
        SET @upd_banco = @@ROWCOUNT;

        -- 4. Alta de partidas del banco: solo movimientos conciliables (transferencias) que
        --    todavía no están en ninguna partida. Comisiones, impuestos y FX no se concilian.
        INSERT INTO dw.fact_conciliacion (origen, linea_extracto_id, contraparte_key, banco_cuenta_key, moneda_key,
                    fecha_banco_key, monto_banco, estado)
        SELECT 'BANCO', m.linea_extracto_id, -1, m.banco_cuenta_key, m.moneda_key, m.fecha_imputacion_key, m.monto,
               'PENDIENTE_EN_LIBROS'
        FROM dw.fact_movimientos_bancarios m
        JOIN dw.dim_tipo_movimiento t ON t.tipo_movimiento_key = m.tipo_movimiento_key AND t.es_conciliable = 1
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_conciliacion k WHERE k.linea_extracto_id = m.linea_extracto_id)
        ORDER BY m.fecha_imputacion_key, m.linea_extracto_id;
        SET @banco = @@ROWCOUNT;

        COMMIT;
        DECLARE @ins INT = ISNULL(@pagos, 0) + ISNULL(@cobranzas, 0) + @banco, @upd INT = @upd_libro + @upd_banco;
        DECLARE @msg_ok NVARCHAR(4000) = CONCAT(N'partidas nuevas: pagos=', ISNULL(@pagos, 0), N', cobranzas=',
                ISNULL(@cobranzas, 0), N', banco=', @banco);
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, 0, 0, @msg_ok;
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
