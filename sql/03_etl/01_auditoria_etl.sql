/* =============================================================================
   01_auditoria_etl.sql — Bitácora del ETL y marcas de agua para la carga incremental.

   Analogía: audit.etl_log es el "libro de novedades" del cierre: quién corrió qué,
   cuándo, cuántos comprobantes entraron, cuántos se rechazaron y por qué. Si algo
   falla, queda escrito el error con número y línea.

   Detalle técnico clave: el registro de inicio se escribe ANTES de abrir la
   transacción de carga y el de fin DESPUÉS del COMMIT/ROLLBACK. Así, si la carga
   falla y se revierte, el registro del error NO se revierte con ella.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

IF OBJECT_ID(N'audit.etl_log', N'U') IS NULL
CREATE TABLE audit.etl_log (
    etl_log_id          INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_etl_log PRIMARY KEY,
    ejecucion_id        UNIQUEIDENTIFIER  NOT NULL,    -- agrupa todos los pasos de una corrida de usp_run_etl
    proceso             SYSNAME           NOT NULL,    -- ej. dw.usp_load_fact_pagos
    estado              VARCHAR(10)       NOT NULL
        CONSTRAINT ck_etl_log_estado CHECK (estado IN ('EN_CURSO', 'OK', 'ERROR')),
    fecha_desde         DATE              NULL,        -- ventana procesada (carga incremental)
    fecha_hasta         DATE              NULL,
    filas_leidas        INT               NULL,        -- filas de staging dentro de la ventana
    filas_insertadas    INT               NULL,
    filas_actualizadas  INT               NULL,
    filas_descartadas   INT               NULL,        -- no cumplen las reglas del DW (motivo en `mensaje`)
    filas_duplicadas    INT               NULL,        -- misma clave de negocio más de una vez en staging
    mensaje             NVARCHAR(4000)    NULL,
    error_numero        INT               NULL,
    error_linea         INT               NULL,
    error_procedimiento NVARCHAR(128)     NULL,
    inicio_utc          DATETIME2(3)      NOT NULL CONSTRAINT df_etl_log_inicio DEFAULT SYSUTCDATETIME(),
    fin_utc             DATETIME2(3)      NULL,
    duracion_ms         AS DATEDIFF(MILLISECOND, inicio_utc, fin_utc),
    -- ORIGINAL_LOGIN y no SUSER_SNAME: si algún día un proceso usa EXECUTE AS, igual queda quién lo lanzó.
    usuario             SYSNAME           NOT NULL CONSTRAINT df_etl_log_usuario DEFAULT ORIGINAL_LOGIN()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_etl_log_ejecucion')
    CREATE INDEX ix_etl_log_ejecucion ON audit.etl_log (ejecucion_id, etl_log_id);
GO

/* Marca de agua: hasta qué fecha de negocio se cargó cada entidad. La próxima corrida
   incremental arranca unos días ANTES (ventana de reproceso) para tomar movimientos
   que llegan tarde (el banco imputa un débito del 30/10 en el extracto de noviembre). */
IF OBJECT_ID(N'audit.etl_marca_agua', N'U') IS NULL
CREATE TABLE audit.etl_marca_agua (
    entidad          SYSNAME      NOT NULL CONSTRAINT pk_etl_marca_agua PRIMARY KEY,
    fecha_max        DATE         NOT NULL,
    actualizado_utc  DATETIME2(3) NOT NULL CONSTRAINT df_etl_marca_agua_act DEFAULT SYSUTCDATETIME()
);
GO

CREATE OR ALTER PROCEDURE audit.usp_etl_log_inicio
    @ejecucion_id UNIQUEIDENTIFIER,
    @proceso      SYSNAME,
    @fecha_desde  DATE = NULL,
    @fecha_hasta  DATE = NULL,
    @log_id       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO audit.etl_log (ejecucion_id, proceso, estado, fecha_desde, fecha_hasta)
    VALUES (@ejecucion_id, @proceso, 'EN_CURSO', @fecha_desde, @fecha_hasta);
    SET @log_id = SCOPE_IDENTITY();   -- SCOPE_IDENTITY y no @@IDENTITY: ignora identities de triggers
END;
GO

CREATE OR ALTER PROCEDURE audit.usp_etl_log_fin
    @log_id         INT,
    @estado         VARCHAR(10),
    @leidas         INT = NULL,
    @insertadas     INT = NULL,
    @actualizadas   INT = NULL,
    @descartadas    INT = NULL,
    @duplicadas     INT = NULL,
    @mensaje        NVARCHAR(4000) = NULL,
    @error_numero   INT = NULL,
    @error_linea    INT = NULL,
    @error_proc     NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE audit.etl_log
    SET estado = @estado, filas_leidas = @leidas, filas_insertadas = @insertadas,
        filas_actualizadas = @actualizadas, filas_descartadas = @descartadas, filas_duplicadas = @duplicadas,
        mensaje = @mensaje, error_numero = @error_numero, error_linea = @error_linea,
        error_procedimiento = @error_proc, fin_utc = SYSUTCDATETIME()
    WHERE etl_log_id = @log_id;
END;
GO

/* Calcula desde qué fecha procesar una entidad:
     - si se pasa @fecha_desde explícita, esa;
     - si es carga completa o nunca se cargó, desde el principio;
     - si no, marca de agua menos @dias_reproceso. */
CREATE OR ALTER PROCEDURE audit.usp_etl_ventana
    @entidad        SYSNAME,
    @carga_completa BIT,
    @fecha_desde    DATE,
    @dias_reproceso INT,
    @desde          DATE OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @desde = @fecha_desde;
    IF @desde IS NULL AND @carga_completa = 0
        SELECT @desde = DATEADD(DAY, -@dias_reproceso, fecha_max) FROM audit.etl_marca_agua WHERE entidad = @entidad;
    SET @desde = ISNULL(@desde, '19000101');
END;
GO

/* Avanza la marca de agua (nunca la retrocede). Se topea en HOY: una fila con fecha
   futura (ej. un pago fechado en 2027 por error de tipeo) "envenenaría" la marca y las
   corridas incrementales siguientes saltearían todo lo que hay en el medio. */
CREATE OR ALTER PROCEDURE audit.usp_etl_avanzar_marca
    @entidad SYSNAME,
    @fecha   DATE
AS
BEGIN
    SET NOCOUNT ON;
    IF @fecha IS NULL RETURN;
    SET @fecha = LEAST(@fecha, CAST(SYSUTCDATETIME() AS DATE));   -- LEAST/GREATEST: nuevos en SQL Server 2022
    UPDATE audit.etl_marca_agua
    SET fecha_max = GREATEST(fecha_max, @fecha), actualizado_utc = SYSUTCDATETIME()
    WHERE entidad = @entidad;
    IF @@ROWCOUNT = 0
        INSERT INTO audit.etl_marca_agua (entidad, fecha_max) VALUES (@entidad, @fecha);
END;
GO
