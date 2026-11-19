/* =============================================================================
   01_dq_estructura.sql — Tablas del control de calidad de datos (DQ) y cuarentenas.

   Analogía de tesorería:
     dq_reglas      = el manual de controles ("todo pago tiene que tener factura")
     dq_resultados  = el informe de cada control en cada cierre: cuántos comprobantes
                      se revisaron y cuántos fallaron (por regla)
     dq_errores     = el detalle: qué comprobante, de qué archivo y línea, con qué valor
     cuarentena_*   = la bandeja de "comprobantes observados": no se contabilizan hasta
                      que se corrijan, pero NO se tiran (quedan con el motivo)

   Severidad:
     ERROR       -> la fila va a cuarentena y no entra al DW.
     ADVERTENCIA -> la fila entra al DW y el problema se informa (ej. email inválido de
                    un proveedor: no impide registrar el pago; partidas sin contrapartida:
                    las resuelve la conciliación).
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

IF OBJECT_ID(N'audit.dq_reglas', N'U') IS NULL
CREATE TABLE audit.dq_reglas (
    regla_id     VARCHAR(40)   NOT NULL CONSTRAINT pk_dq_reglas PRIMARY KEY,
    descripcion  NVARCHAR(300) NOT NULL,
    categoria    VARCHAR(30)   NOT NULL CONSTRAINT ck_dq_reglas_categoria CHECK (categoria IN
                 ('completitud', 'unicidad', 'formato', 'rango', 'integridad_referencial', 'consistencia',
                  'totales_control')),
    tabla        SYSNAME       NOT NULL,     -- tabla de staging (o de DW, para los controles post-carga)
    severidad    VARCHAR(12)   NOT NULL CONSTRAINT ck_dq_reglas_severidad CHECK (severidad IN ('ERROR', 'ADVERTENCIA')),
    momento      VARCHAR(12)   NOT NULL CONSTRAINT ck_dq_reglas_momento CHECK (momento IN ('PRE_CARGA', 'POST_CARGA')),
    accion       AS (CASE severidad WHEN 'ERROR' THEN 'CUARENTENA' ELSE 'INFORMAR' END),
    activa       BIT           NOT NULL CONSTRAINT df_dq_reglas_activa DEFAULT 1
);
GO

IF OBJECT_ID(N'audit.dq_resultados', N'U') IS NULL
CREATE TABLE audit.dq_resultados (
    dq_resultado_id  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dq_resultados PRIMARY KEY,
    ejecucion_id     UNIQUEIDENTIFIER  NOT NULL,
    regla_id         VARCHAR(40)       NOT NULL CONSTRAINT fk_dq_resultados_regla REFERENCES audit.dq_reglas,
    tabla            SYSNAME           NOT NULL,
    categoria        VARCHAR(30)       NOT NULL,
    severidad        VARCHAR(12)       NOT NULL,
    filas_evaluadas  INT               NOT NULL,
    filas_con_error  INT               NOT NULL,
    pct_error        AS CAST(100.0 * filas_con_error / NULLIF(filas_evaluadas, 0) AS DECIMAL(9,4)),
    fecha_utc        DATETIME2(3)      NOT NULL CONSTRAINT df_dq_resultados_fecha DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_dq_resultados_ejecucion')
    CREATE INDEX ix_dq_resultados_ejecucion ON audit.dq_resultados (ejecucion_id, regla_id);
GO

IF OBJECT_ID(N'audit.dq_errores', N'U') IS NULL
CREATE TABLE audit.dq_errores (
    dq_error_id  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dq_errores PRIMARY KEY,
    ejecucion_id UNIQUEIDENTIFIER NOT NULL,
    regla_id     VARCHAR(40)      NOT NULL CONSTRAINT fk_dq_errores_regla REFERENCES audit.dq_reglas,
    tabla        SYSNAME          NOT NULL,
    stg_row_id   BIGINT           NULL,     -- NULL en reglas sin fila de origen (ej. "falta la cotización del día")
    source_file  NVARCHAR(260)    NULL,
    source_line  INT              NULL,
    clave        NVARCHAR(200)    NULL,     -- clave de negocio (ej. PAY-0000123)
    valor        NVARCHAR(400)    NULL,     -- valor observado que viola la regla
    fecha_utc    DATETIME2(3)     NOT NULL CONSTRAINT df_dq_errores_fecha DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_dq_errores_ejecucion')
    CREATE INDEX ix_dq_errores_ejecucion ON audit.dq_errores (ejecucion_id, regla_id) INCLUDE (stg_row_id);
GO

/* ---------------------------------------------------------------- tablas de cuarentena
   Una por fuente con reglas de severidad ERROR, con las MISMAS columnas de negocio que
   staging (NVARCHAR crudo: la fila se guarda tal como vino, con el error adentro).
   Se generan con SQL dinámico leyendo la estructura de stg.* desde sys.columns, así nunca
   quedan desalineadas con staging. SQL dinámico SEGURO: los nombres pasan por QUOTENAME y
   salen de una lista fija (no de un parámetro de usuario), y se ejecuta con sp_executesql.
   Es SQL dinámico de DESPLIEGUE (lo corre el administrador); en tiempo de ejecución el
   ETL usa SQL estático, porque el SQL dinámico corta el ownership chaining y obligaría a
   darle al usuario del ETL permisos directos sobre las tablas. */
DECLARE @fuentes TABLE (tabla SYSNAME PRIMARY KEY, clave SYSNAME NOT NULL);
INSERT INTO @fuentes VALUES (N'invoices', N'invoice_id'), (N'payments', N'payment_id'),
       (N'collections', N'collection_id'), (N'bank_statements', N'statement_line_id'), (N'fx_rates', N'rate_date');

DECLARE @t SYSNAME, @clave SYSNAME, @cols NVARCHAR(MAX), @sql NVARCHAR(MAX), @no_nvarchar INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT tabla, clave FROM @fuentes;
OPEN c;
FETCH NEXT FROM c INTO @t, @clave;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'audit.' + QUOTENAME(N'cuarentena_' + @t), N'U') IS NULL
    BEGIN
        SELECT @no_nvarchar = COUNT(*) FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'stg.' + QUOTENAME(@t)) AND c.name NOT LIKE N'\_%' ESCAPE N'\'
          AND TYPE_NAME(c.user_type_id) <> N'nvarchar';
        IF @no_nvarchar > 0
            THROW 50010, N'La cuarentena espera columnas de negocio NVARCHAR en staging.', 1;

        SELECT @cols = STRING_AGG(CAST(QUOTENAME(c.name) + N' NVARCHAR(' + CAST(c.max_length / 2 AS NVARCHAR(10))
                                       + N') NULL' AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.column_id)
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'stg.' + QUOTENAME(@t)) AND c.name NOT LIKE N'\_%' ESCAPE N'\';

        SET @sql = N'CREATE TABLE audit.' + QUOTENAME(N'cuarentena_' + @t) + N' (
            stg_row_id              BIGINT           NOT NULL CONSTRAINT ' + QUOTENAME(N'pk_cuarentena_' + @t) + N' PRIMARY KEY,
            _source_file            NVARCHAR(260)    NOT NULL,
            _source_line            INT              NOT NULL, ' + @cols + N',
            reglas                  NVARCHAR(1000)   NOT NULL,
            estado                  VARCHAR(15)      NOT NULL CONSTRAINT ' + QUOTENAME(N'ck_cuarentena_' + @t + N'_estado')
                                                     + N' CHECK (estado IN (''EN_CUARENTENA'', ''LIBERADA'')),
            primera_ejecucion_id    UNIQUEIDENTIFIER NOT NULL,
            ultima_ejecucion_id     UNIQUEIDENTIFIER NOT NULL,
            fecha_ingreso_utc       DATETIME2(3)     NOT NULL CONSTRAINT ' + QUOTENAME(N'df_cuarentena_' + @t + N'_ingreso')
                                                     + N' DEFAULT SYSUTCDATETIME(),
            fecha_liberacion_utc    DATETIME2(3)     NULL);';
        EXEC sys.sp_executesql @sql;

        -- Índice por clave de negocio: el ETL pregunta "¿esta clave está en cuarentena?".
        SET @sql = N'CREATE INDEX ' + QUOTENAME(N'ix_cuarentena_' + @t + N'_clave') + N' ON audit.'
                 + QUOTENAME(N'cuarentena_' + @t) + N' (' + QUOTENAME(@clave) + N', estado);';
        EXEC sys.sp_executesql @sql;
    END
    FETCH NEXT FROM c INTO @t, @clave;
END
CLOSE c;
DEALLOCATE c;
GO

SELECT t.name AS tabla_dq, COUNT(c.column_id) AS columnas
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N'audit') AND (t.name LIKE N'dq\_%' ESCAPE N'\' OR t.name LIKE N'cuarentena\_%' ESCAPE N'\')
GROUP BY t.name ORDER BY t.name;
GO
