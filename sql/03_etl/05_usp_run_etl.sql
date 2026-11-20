/* =============================================================================
   05_usp_run_etl.sql — Orquestador del ETL.

   Corre los pasos en orden de dependencia:
     dimensiones -> tipo de cambio -> facturas -> pagos / cobranzas -> movimientos
     -> saldos -> partidas de conciliación
   (los pagos necesitan la factura para calcular días vs. vencimiento, todos los hechos
   necesitan el tipo de cambio y las dimensiones para sus claves).

   Decisiones:
   - CADA PASO COMMITEA SU PROPIA TRANSACCIÓN (no una transacción gigante). Si falla el
     paso 6, los pasos 1-5 quedan cargados; como todo es idempotente, alcanza con volver
     a correr usp_run_etl y retoma sin duplicar. Una transacción única bloquearía el DW
     durante toda la carga y haría que un error al final tire abajo todo lo anterior.
   - FRENA EN EL PRIMER ERROR (fail fast): cargar hechos con dimensiones a medio cargar
     genera claves -1 que después hay que corregir.
   - Carga incremental: cada hecho procesa desde su marca de agua menos @dias_reproceso.
     @carga_completa = 1 reprocesa todo; @fecha_desde/@fecha_hasta fuerzan una ventana.
   - El usuario de la carga (rol_etl) solo tiene EXECUTE sobre ESTE procedimiento: los
     usp_load_* y las tablas dw.* los usa a través de él (ownership chaining: mismo
     dueño, dbo, así que SQL Server no vuelve a chequear permisos en cada objeto).

   Uso:
     EXEC dw.usp_run_etl;                                    -- incremental
     EXEC dw.usp_run_etl @carga_completa = 1;                -- todo desde cero
     EXEC dw.usp_run_etl @fecha_desde = '2026-03-01', @fecha_hasta = '2026-03-31';
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE dw.usp_run_etl
    @carga_completa BIT  = 0,
    @fecha_desde    DATE = NULL,
    @fecha_hasta    DATE = NULL,
    @dias_reproceso INT  = 7
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @ej UNIQUEIDENTIFIER = NEWID(), @log_id INT, @d DATE;
    EXEC audit.usp_etl_log_inicio @ej, N'dw.usp_run_etl', @fecha_desde, @fecha_hasta, @log_id OUTPUT;
    BEGIN TRY
        -- La validación va dentro del TRY: así un parámetro inválido también queda en la bitácora.
        IF @fecha_desde > @fecha_hasta
            THROW 50001, N'@fecha_desde no puede ser posterior a @fecha_hasta.', 1;
        IF @dias_reproceso < 0
            THROW 50002, N'@dias_reproceso no puede ser negativo.', 1;
        IF @@TRANCOUNT > 0
            THROW 50003, N'usp_run_etl maneja sus propias transacciones: llamarlo fuera de una transacción (autocommit).', 1;

        EXEC dw.usp_load_dim_banco_cuenta @ej;
        EXEC dw.usp_load_dim_contraparte @ej;

        EXEC audit.usp_etl_ventana N'fact_tipo_cambio', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_tipo_cambio @ej, @d, @fecha_hasta;

        EXEC audit.usp_etl_ventana N'fact_facturas', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_facturas @ej, @d, @fecha_hasta;

        EXEC audit.usp_etl_ventana N'fact_pagos', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_pagos @ej, @d, @fecha_hasta;

        EXEC audit.usp_etl_ventana N'fact_cobranzas', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_cobranzas @ej, @d, @fecha_hasta;

        EXEC audit.usp_etl_ventana N'fact_movimientos_bancarios', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_movimientos_bancarios @ej, @d, @fecha_hasta;

        EXEC audit.usp_etl_ventana N'fact_saldo_bancario_mensual', @carga_completa, @fecha_desde, @dias_reproceso, @d OUTPUT;
        EXEC dw.usp_load_fact_saldo_bancario_mensual @ej, @d, @fecha_hasta;

        EXEC dw.usp_load_fact_conciliacion @ej;

        DECLARE @resumen NVARCHAR(4000);
        SELECT @resumen = CONCAT(N'pasos=', COUNT(*), N', insertadas=', SUM(filas_insertadas),
                                 N', actualizadas=', SUM(filas_actualizadas), N', descartadas=', SUM(filas_descartadas),
                                 N', duplicadas=', SUM(filas_duplicadas))
        FROM audit.etl_log WHERE ejecucion_id = @ej AND etl_log_id <> @log_id;
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @mensaje = @resumen;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE(), @num INT = ERROR_NUMBER(), @lin INT = ERROR_LINE(),
                @prc NVARCHAR(128) = ERROR_PROCEDURE();
        EXEC audit.usp_etl_log_fin @log_id, 'ERROR', @mensaje = @msg, @error_numero = @num,
             @error_linea = @lin, @error_proc = @prc;
        THROW;
    END CATCH

    -- Resumen de la corrida (lo muestra quien la ejecuta: sqlcmd, Azure Data Studio o Python).
    SELECT etl_log_id, proceso, estado, fecha_desde, fecha_hasta, filas_leidas, filas_insertadas,
           filas_actualizadas, filas_descartadas, filas_duplicadas, duracion_ms, mensaje
    FROM audit.etl_log
    WHERE ejecucion_id = @ej
    ORDER BY etl_log_id;
END;
GO

-- Mínimo privilegio: el ETL ejecuta el orquestador y nada más.
GRANT EXECUTE ON OBJECT::dw.usp_run_etl TO rol_etl;
GO
