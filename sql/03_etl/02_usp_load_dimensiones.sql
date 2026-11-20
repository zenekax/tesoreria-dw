/* =============================================================================
   02_usp_load_dimensiones.sql — Carga de dimensiones desde staging.

   Patrón común de todos los usp_load_* (dimensiones y hechos):
     1. registrar inicio en audit.etl_log (fuera de la transacción);
     2. leer staging, convertir tipos con TRY_CONVERT (devuelve NULL en vez de romper)
        y decidir, fila por fila, si es válida o el MOTIVO por el que se descarta;
     3. dentro de UNA transacción: actualizar lo que cambió e insertar lo nuevo;
     4. registrar fin con los conteos (y los motivos de descarte) o el error.
   SET XACT_ABORT ON: ante cualquier error, la transacción se marca para revertir
   entera (sin XACT_ABORT, algunos errores dejan la transacción abierta "a medias").

   MERGE vs. INSERT/UPDATE explícito (consigna de la Fase 4):
   - dim_banco_cuenta usa MERGE: upsert simple (tipo 1) sobre 9 filas; MERGE expresa
     "si existe actualizo, si no inserto" en una sola sentencia y OUTPUT $action da los
     conteos. Con HOLDLOCK, para que dos cargas concurrentes no inserten la misma cuenta.
   - dim_contraparte (SCD2) y los hechos usan UPDATE + INSERT explícitos: el SCD2 tiene
     tres operaciones distintas (corregir tipo 1, cerrar versión, abrir versión) que en
     un MERGE quedan enredadas; separadas, cada paso se lee, se prueba y se cuenta por
     separado. Además MERGE tuvo bugs conocidos en SQL Server y, sin HOLDLOCK, problemas
     de concurrencia: en procesos críticos se prefiere lo explícito.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- dw.usp_load_dim_banco_cuenta
   SCD tipo 1 con MERGE. Fuente: la última versión de cada cuenta en stg.bank_accounts,
   con los datos del banco "aplanados" desde stg.banks. */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_banco_cuenta
    @ejecucion_id UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_dim_banco_cuenta';
    DECLARE @log_id INT, @leidas INT, @descartadas INT, @duplicadas INT, @motivos NVARCHAR(4000);
    DECLARE @acciones TABLE (accion NVARCHAR(10));
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        WITH bancos AS (   -- última versión de cada banco
            SELECT *, ROW_NUMBER() OVER (PARTITION BY bank_id ORDER BY _row_id DESC) AS nro FROM stg.banks
        ), cuentas AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY _row_id DESC) AS nro FROM stg.bank_accounts
        )
        SELECT c.account_id AS cuenta_id, c.account_number AS numero_cuenta, c.currency AS moneda_iso,
               c.account_type AS tipo_cuenta, c.account_alias AS alias,
               TRY_CONVERT(DATE, c.opened_date, 23) AS fecha_apertura,
               c.bank_id AS banco_id, b.bank_name AS banco_nombre, b.country AS banco_pais, b.swift_bic, c.nro,
               CASE WHEN c.account_id IS NULL OR c.account_number IS NULL THEN 'CLAVE_NULA'
                    WHEN LEN(c.currency) <> 3 OR c.currency IS NULL THEN 'MONEDA_INVALIDA'
                    WHEN b.bank_id IS NULL THEN 'BANCO_INEXISTENTE'
                    WHEN LEN(c.account_number) > 34 THEN 'NUMERO_CUENTA_INVALIDO' END AS motivo
        INTO #cand
        FROM cuentas c
        LEFT JOIN bancos b ON b.bank_id = c.bank_id AND b.nro = 1;

        SELECT @leidas = COUNT(*), @duplicadas = SUM(CASE WHEN nro > 1 THEN 1 ELSE 0 END),
               @descartadas = SUM(CASE WHEN nro = 1 AND motivo IS NOT NULL THEN 1 ELSE 0 END)
        FROM #cand;
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ')
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        MERGE dw.dim_banco_cuenta WITH (HOLDLOCK) AS d
        USING (SELECT * FROM #cand WHERE nro = 1 AND motivo IS NULL) AS s
            ON d.cuenta_id = s.cuenta_id
        -- EXISTS (SELECT origen EXCEPT SELECT destino): "¿hay alguna diferencia?" tratando
        -- NULL = NULL (con "<>" columna por columna, un NULL haría que no se detecte el cambio).
        WHEN MATCHED AND EXISTS (
                SELECT s.numero_cuenta, s.moneda_iso, s.tipo_cuenta, s.alias, s.fecha_apertura,
                       s.banco_id, s.banco_nombre, s.banco_pais, s.swift_bic
                EXCEPT
                SELECT d.numero_cuenta, d.moneda_iso, d.tipo_cuenta, d.alias, d.fecha_apertura,
                       d.banco_id, d.banco_nombre, d.banco_pais, d.swift_bic) THEN
            UPDATE SET numero_cuenta = s.numero_cuenta, moneda_iso = s.moneda_iso, tipo_cuenta = s.tipo_cuenta,
                       alias = s.alias, fecha_apertura = s.fecha_apertura, banco_id = s.banco_id,
                       banco_nombre = s.banco_nombre, banco_pais = s.banco_pais, swift_bic = s.swift_bic,
                       fecha_modif_dw = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (cuenta_id, numero_cuenta, moneda_iso, tipo_cuenta, alias, fecha_apertura,
                    banco_id, banco_nombre, banco_pais, swift_bic)
            VALUES (s.cuenta_id, s.numero_cuenta, s.moneda_iso, s.tipo_cuenta, s.alias, s.fecha_apertura,
                    s.banco_id, s.banco_nombre, s.banco_pais, s.swift_bic)
        -- (sin WHEN NOT MATCHED BY SOURCE: una cuenta que no viene en el archivo no se borra del DW)
        OUTPUT $action INTO @acciones;
        COMMIT;

        DECLARE @ins INT = (SELECT COUNT(*) FROM @acciones WHERE accion = N'INSERT'),
                @upd INT = (SELECT COUNT(*) FROM @acciones WHERE accion = N'UPDATE');
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, @ins, @upd, @descartadas, @duplicadas, @motivos;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE(), @num INT = ERROR_NUMBER(), @lin INT = ERROR_LINE(),
                @prc NVARCHAR(128) = ERROR_PROCEDURE();
        EXEC audit.usp_etl_log_fin @log_id, 'ERROR', @mensaje = @msg, @error_numero = @num,
             @error_linea = @lin, @error_proc = @prc;
        THROW;   -- re-lanza el error original: el orquestador se entera y frena
    END CATCH
END;
GO

/* ---------------------------------------------------------------- dw.usp_load_dim_contraparte (SCD2)
   Los snapshots del maestro se aplican EN ORDEN de fecha (por eso el cursor: aplicar el
   de mayo y después el de noviembre "desharía" la historia). Por cada snapshot:
     1. Tipo 1 (email, razón social, tax_id...): si cambió, se corrige en TODAS las versiones.
     2. Tipo 2 (segmento, riesgo, plazo, activa): si cambió, se CIERRA la versión vigente
        (vigente_hasta = día anterior al snapshot) y se ABRE una nueva desde el snapshot.
     3. Contrapartes nuevas: primera versión, vigente desde su fecha de alta (así los
        hechos anteriores al primer snapshot también encuentran su versión).
   Los cambios se detectan comparando hashes (hash_tipo1/hash_tipo2 de la dimensión vs.
   el mismo cálculo sobre staging), no columna por columna.
   Idempotente: la marca de agua guarda el último snapshot aplicado; re-ejecutar vuelve a
   aplicar ese (sin cambios) y nunca uno anterior. */
CREATE OR ALTER PROCEDURE dw.usp_load_dim_contraparte
    @ejecucion_id UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Nombre fijo y no OBJECT_NAME(@@PROCID): con mínimo privilegio, el usuario del ETL no
    -- "ve" la metadata de este procedimiento y OBJECT_NAME devolvería NULL.
    DECLARE @proc SYSNAME = N'dw.usp_load_dim_contraparte';
    DECLARE @log_id INT, @snap DATE, @ultimo DATE,
            @leidas INT = 0, @descartadas INT = 0, @duplicadas INT = 0,
            @nuevas INT = 0, @versiones INT = 0, @tipo1 INT = 0, @en_lugar INT = 0, @motivos NVARCHAR(4000);
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        SELECT @ultimo = fecha_max FROM audit.etl_marca_agua WHERE entidad = N'dim_contraparte';

        -- Staging tipado y traducido al vocabulario del DW, para todos los snapshots pendientes.
        WITH tipado AS (
            SELECT s._row_id, TRY_CONVERT(DATE, s.snapshot_date, 23) AS snapshot,
                   s.counterparty_id AS contraparte_id,
                   CAST(CASE s.counterparty_type WHEN 'SUPPLIER' THEN 'PROVEEDOR' WHEN 'CUSTOMER' THEN 'CLIENTE'
                        WHEN 'CORRESPONDENT' THEN 'CORRESPONSAL' END AS VARCHAR(20)) AS tipo_contraparte,
                   CAST(s.legal_name AS NVARCHAR(300)) AS razon_social,
                   CAST(s.tax_id AS NVARCHAR(50)) AS tax_id, CAST(s.email AS NVARCHAR(320)) AS email,
                   CAST(s.country AS CHAR(2)) AS pais, CAST(s.default_currency AS CHAR(3)) AS moneda_default,
                   TRY_CONVERT(DATE, s.created_at, 23) AS fecha_alta,
                   CAST(CASE s.segment WHEN 'STRATEGIC' THEN 'ESTRATEGICO' WHEN 'ENTERPRISE' THEN 'CORPORATIVO'
                        WHEN 'SME' THEN 'PYME' END AS VARCHAR(20)) AS segmento,
                   CAST(CASE s.risk_rating WHEN 'LOW' THEN 'BAJO' WHEN 'MEDIUM' THEN 'MEDIO'
                        WHEN 'HIGH' THEN 'ALTO' END AS VARCHAR(10)) AS calificacion_riesgo,
                   TRY_CONVERT(SMALLINT, s.payment_terms_days) AS plazo_pago_dias,
                   CAST(CASE s.is_active WHEN 'Y' THEN 1 WHEN 'N' THEN 0 END AS BIT) AS activa,
                   LEN(s.country) AS largo_pais, LEN(s.default_currency) AS largo_moneda
            FROM stg.counterparties s
        )
        SELECT t.*,
               ROW_NUMBER() OVER (PARTITION BY t.snapshot, t.contraparte_id ORDER BY t._row_id DESC) AS nro,
               CASE WHEN t.snapshot IS NULL THEN 'SNAPSHOT_INVALIDO'
                    WHEN t.contraparte_id IS NULL THEN 'CLAVE_NULA'
                    WHEN t.tipo_contraparte IS NULL THEN 'TIPO_DESCONOCIDO'
                    WHEN t.razon_social IS NULL THEN 'RAZON_SOCIAL_NULA'
                    WHEN t.largo_pais IS NULL OR t.largo_pais <> 2 THEN 'PAIS_INVALIDO'
                    WHEN t.largo_moneda IS NULL OR t.largo_moneda <> 3 THEN 'MONEDA_INVALIDA'
                    WHEN t.segmento IS NULL OR t.calificacion_riesgo IS NULL THEN 'CATEGORIA_DESCONOCIDA'
                    WHEN t.plazo_pago_dias IS NULL OR t.plazo_pago_dias NOT BETWEEN 0 AND 365 THEN 'PLAZO_INVALIDO'
                    WHEN t.activa IS NULL THEN 'ESTADO_INVALIDO' END AS motivo,
               -- Mismo cálculo que las columnas calculadas de dw.dim_contraparte (si difieren, cambió algo).
               CAST(HASHBYTES('SHA2_256', CONCAT_WS(N'|', t.segmento, t.calificacion_riesgo, t.plazo_pago_dias,
                    t.activa)) AS BINARY(32)) AS hash_tipo2,
               CAST(HASHBYTES('SHA2_256', CONCAT_WS(N'|', t.tipo_contraparte, t.razon_social, t.tax_id, t.email,
                    t.pais, t.moneda_default, CONVERT(CHAR(8), t.fecha_alta, 112))) AS BINARY(32)) AS hash_tipo1
        INTO #cand
        FROM tipado t
        WHERE t.snapshot IS NULL OR t.snapshot >= ISNULL(@ultimo, '19000101');

        SELECT @leidas = COUNT(*), @duplicadas = SUM(CASE WHEN nro > 1 THEN 1 ELSE 0 END),
               @descartadas = SUM(CASE WHEN nro = 1 AND motivo IS NOT NULL THEN 1 ELSE 0 END)
        FROM #cand;
        SELECT @motivos = STRING_AGG(CONCAT(motivo, N'=', n), N', ')
        FROM (SELECT motivo, COUNT(*) AS n FROM #cand WHERE nro = 1 AND motivo IS NOT NULL GROUP BY motivo) x;

        BEGIN TRANSACTION;
        DECLARE c_snap CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT snapshot FROM #cand WHERE nro = 1 AND motivo IS NULL ORDER BY snapshot;
        OPEN c_snap;
        FETCH NEXT FROM c_snap INTO @snap;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT * INTO #src FROM #cand WHERE snapshot = @snap AND nro = 1 AND motivo IS NULL;

            -- 1. Tipo 1: corrige en todas las versiones (pisa el dato, sin historia).
            UPDATE d
            SET tipo_contraparte = s.tipo_contraparte, razon_social = s.razon_social, tax_id = s.tax_id,
                email = s.email, pais = s.pais, moneda_default = s.moneda_default, fecha_alta = s.fecha_alta,
                fecha_modif_dw = SYSUTCDATETIME()
            FROM dw.dim_contraparte d
            JOIN #src s ON s.contraparte_id = d.contraparte_id
            WHERE d.hash_tipo1 <> s.hash_tipo1;
            SET @tipo1 += @@ROWCOUNT;

            -- 2a. Tipo 2 sobre una versión que abrió ESTE mismo snapshot (re-proceso de un archivo
            --     corregido): no se puede cerrar una versión el día antes de abrirla; se corrige en el lugar.
            UPDATE d
            SET segmento = s.segmento, calificacion_riesgo = s.calificacion_riesgo,
                plazo_pago_dias = s.plazo_pago_dias, activa = s.activa, fecha_modif_dw = SYSUTCDATETIME()
            FROM dw.dim_contraparte d
            JOIN #src s ON s.contraparte_id = d.contraparte_id
            WHERE d.es_vigente = 1 AND d.vigente_desde >= @snap AND d.hash_tipo2 <> s.hash_tipo2;
            SET @en_lugar += @@ROWCOUNT;

            -- 2b. Tipo 2 normal: cerrar la versión vigente...
            SELECT s.* INTO #cambios
            FROM #src s
            JOIN dw.dim_contraparte d ON d.contraparte_id = s.contraparte_id AND d.es_vigente = 1
            WHERE d.vigente_desde < @snap AND d.hash_tipo2 <> s.hash_tipo2;

            UPDATE d
            SET vigente_hasta = DATEADD(DAY, -1, @snap), es_vigente = 0, fecha_modif_dw = SYSUTCDATETIME()
            FROM dw.dim_contraparte d
            JOIN #cambios c ON c.contraparte_id = d.contraparte_id
            WHERE d.es_vigente = 1;

            -- ... y abrir la nueva desde la fecha del snapshot.
            INSERT INTO dw.dim_contraparte (contraparte_id, tipo_contraparte, razon_social, tax_id, email, pais,
                        moneda_default, fecha_alta, segmento, calificacion_riesgo, plazo_pago_dias, activa,
                        vigente_desde, vigente_hasta, es_vigente)
            SELECT contraparte_id, tipo_contraparte, razon_social, tax_id, email, pais, moneda_default, fecha_alta,
                   segmento, calificacion_riesgo, plazo_pago_dias, activa, @snap, '9999-12-31', 1
            FROM #cambios
            ORDER BY contraparte_id;
            SET @versiones += @@ROWCOUNT;

            -- 3. Contrapartes nuevas: primera versión desde su fecha de alta (o el snapshot, lo que sea antes).
            INSERT INTO dw.dim_contraparte (contraparte_id, tipo_contraparte, razon_social, tax_id, email, pais,
                        moneda_default, fecha_alta, segmento, calificacion_riesgo, plazo_pago_dias, activa,
                        vigente_desde, vigente_hasta, es_vigente)
            SELECT s.contraparte_id, s.tipo_contraparte, s.razon_social, s.tax_id, s.email, s.pais, s.moneda_default,
                   s.fecha_alta, s.segmento, s.calificacion_riesgo, s.plazo_pago_dias, s.activa,
                   LEAST(ISNULL(s.fecha_alta, @snap), @snap), '9999-12-31', 1
            FROM #src s
            WHERE NOT EXISTS (SELECT 1 FROM dw.dim_contraparte d WHERE d.contraparte_id = s.contraparte_id)
            ORDER BY s.contraparte_id;   -- orden fijo -> mismas claves surrogate al reconstruir
            SET @nuevas += @@ROWCOUNT;

            EXEC audit.usp_etl_avanzar_marca N'dim_contraparte', @snap;
            DROP TABLE #src, #cambios;
            FETCH NEXT FROM c_snap INTO @snap;
        END
        CLOSE c_snap;
        DEALLOCATE c_snap;
        COMMIT;

        SET @motivos = CONCAT_WS(N' | ', CONCAT(N'nuevas=', @nuevas, N', versiones_nuevas=', @versiones,
                                 N', correcciones_tipo1=', @tipo1, N', tipo2_en_lugar=', @en_lugar), @motivos);
        DECLARE @ins INT = @nuevas + @versiones, @upd INT = @tipo1 + @en_lugar;
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
