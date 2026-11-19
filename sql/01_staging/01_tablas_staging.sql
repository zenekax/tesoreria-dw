/* =============================================================================
   01_tablas_staging.sql
   Capa de staging: una tabla por archivo fuente, con el dato TAL CUAL llegó.

   Analogía: staging es el extracto bancario crudo abrochado en la carpeta. No se
   corrige nada acá; se corrige (o se rechaza a cuarentena) al pasar al libro (dw).

   Decisiones:
   - Columnas de negocio en NVARCHAR, incluso montos y fechas. Si `amount` fuera
     DECIMAL, la fila con "1.234.567,89" o la fecha "2026-02-30" haría fallar la carga
     y el error nunca llegaría a los controles de calidad (Fase 5). La conversión de
     tipos se hace después con TRY_CONVERT, que devuelve NULL en vez de romper.
   - NVARCHAR (Unicode) y no VARCHAR: nombres con ñ, acentos y ç de 5 países.
   - Tamaños holgados: un valor basura más largo de lo esperado también tiene que
     entrar. El cargador valida los largos antes de insertar y avisa con claridad.
   - Sin claves únicas de negocio: los duplicados de la fuente TIENEN que entrar
     para poder detectarlos. La única clave es la técnica (_row_id).
   - Metadatos de linaje en cada fila: de qué archivo y línea vino, cuándo y en qué carga.
     (_source_file, _source_line) coincide con (archivo, linea) del manifiesto de errores.
   - CREATE TABLE solo si no existe: re-ejecutar el script no borra datos cargados.

   Ejecutar con: scripts/run_sql.sh sql/01_staging/01_tablas_staging.sql
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- bitácora de cargas
   Una fila por archivo y por ejecución (append-only: es historia, no se pisa).
   El cargador la usa para decidir si un archivo ya está cargado (mismo sha256). */
IF OBJECT_ID(N'audit.carga_staging', N'U') IS NULL
CREATE TABLE audit.carga_staging (
    carga_id        INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_carga_staging PRIMARY KEY,
    ejecucion_id    UNIQUEIDENTIFIER  NOT NULL,      -- agrupa los archivos de una misma corrida
    archivo         NVARCHAR(260)     NOT NULL,      -- ruta relativa, ej. 2026-03/payments.csv
    tabla_destino   SYSNAME           NOT NULL,
    sha256          CHAR(64)          NULL,
    filas_archivo   INT               NULL,
    filas_cargadas  INT               NULL,
    resultado       VARCHAR(20)       NOT NULL
        CONSTRAINT ck_carga_staging_resultado
        CHECK (resultado IN ('EN_CURSO', 'CARGADO', 'REEMPLAZADO', 'OMITIDO', 'ERROR')),
    mensaje         NVARCHAR(2000)    NULL,
    inicio_utc      DATETIME2(3)      NOT NULL,
    fin_utc         DATETIME2(3)      NULL,
    usuario         SYSNAME           NOT NULL CONSTRAINT df_carga_staging_usuario DEFAULT SUSER_SNAME()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_carga_staging_archivo')
    CREATE INDEX ix_carga_staging_archivo ON audit.carga_staging (archivo, carga_id DESC)
        INCLUDE (sha256, filas_cargadas, resultado);
GO
GRANT UPDATE ON OBJECT::audit.carga_staging TO rol_etl;  -- para cerrar el registro EN_CURSO
GO

/* ---------------------------------------------------------------- tablas stg.*
   Las 5 columnas técnicas son iguales en todas las tablas (prefijo "_" para que no
   choquen con columnas de la fuente). El orden de las columnas de negocio es el del
   CSV: el cargador lo verifica contra el encabezado de cada archivo. */

IF OBJECT_ID(N'stg.banks', N'U') IS NULL
CREATE TABLE stg.banks (
    _row_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_banks PRIMARY KEY,
    _carga_id    INT           NOT NULL CONSTRAINT fk_stg_banks_carga REFERENCES audit.carga_staging (carga_id),
    _source_file NVARCHAR(260) NOT NULL,
    _source_line INT           NOT NULL,
    _loaded_at   DATETIME2(3)  NOT NULL,
    bank_id      NVARCHAR(50)  NULL,
    bank_name    NVARCHAR(200) NULL,
    country      NVARCHAR(50)  NULL,
    swift_bic    NVARCHAR(50)  NULL
);

IF OBJECT_ID(N'stg.bank_accounts', N'U') IS NULL
CREATE TABLE stg.bank_accounts (
    _row_id        BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_bank_accounts PRIMARY KEY,
    _carga_id      INT           NOT NULL CONSTRAINT fk_stg_bank_accounts_carga REFERENCES audit.carga_staging (carga_id),
    _source_file   NVARCHAR(260) NOT NULL,
    _source_line   INT           NOT NULL,
    _loaded_at     DATETIME2(3)  NOT NULL,
    account_id     NVARCHAR(50)  NULL,
    bank_id        NVARCHAR(50)  NULL,
    account_number NVARCHAR(100) NULL,
    currency       NVARCHAR(50)  NULL,
    account_type   NVARCHAR(50)  NULL,
    account_alias  NVARCHAR(200) NULL,
    opened_date    NVARCHAR(50)  NULL
);

-- Los dos snapshots del maestro van a la misma tabla; los distingue snapshot_date/_source_file.
IF OBJECT_ID(N'stg.counterparties', N'U') IS NULL
CREATE TABLE stg.counterparties (
    _row_id            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_counterparties PRIMARY KEY,
    _carga_id          INT           NOT NULL CONSTRAINT fk_stg_counterparties_carga REFERENCES audit.carga_staging (carga_id),
    _source_file       NVARCHAR(260) NOT NULL,
    _source_line       INT           NOT NULL,
    _loaded_at         DATETIME2(3)  NOT NULL,
    counterparty_id    NVARCHAR(50)  NULL,
    counterparty_type  NVARCHAR(50)  NULL,
    legal_name         NVARCHAR(300) NULL,
    tax_id             NVARCHAR(50)  NULL,
    country            NVARCHAR(50)  NULL,
    default_currency   NVARCHAR(50)  NULL,
    email              NVARCHAR(320) NULL,   -- 320 = largo máximo de un email (RFC 3696)
    segment            NVARCHAR(50)  NULL,
    risk_rating        NVARCHAR(50)  NULL,
    payment_terms_days NVARCHAR(50)  NULL,
    is_active          NVARCHAR(10)  NULL,
    created_at         NVARCHAR(50)  NULL,
    snapshot_date      NVARCHAR(50)  NULL
);

IF OBJECT_ID(N'stg.fx_rates', N'U') IS NULL
CREATE TABLE stg.fx_rates (
    _row_id      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_fx_rates PRIMARY KEY,
    _carga_id    INT           NOT NULL CONSTRAINT fk_stg_fx_rates_carga REFERENCES audit.carga_staging (carga_id),
    _source_file NVARCHAR(260) NOT NULL,
    _source_line INT           NOT NULL,
    _loaded_at   DATETIME2(3)  NOT NULL,
    rate_date    NVARCHAR(50)  NULL,
    currency     NVARCHAR(50)  NULL,
    rate_per_usd NVARCHAR(50)  NULL,
    source       NVARCHAR(100) NULL
);

IF OBJECT_ID(N'stg.invoices', N'U') IS NULL
CREATE TABLE stg.invoices (
    _row_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_invoices PRIMARY KEY,
    _carga_id       INT           NOT NULL CONSTRAINT fk_stg_invoices_carga REFERENCES audit.carga_staging (carga_id),
    _source_file    NVARCHAR(260) NOT NULL,
    _source_line    INT           NOT NULL,
    _loaded_at      DATETIME2(3)  NOT NULL,
    invoice_id      NVARCHAR(50)  NULL,
    invoice_number  NVARCHAR(100) NULL,
    counterparty_id NVARCHAR(50)  NULL,
    invoice_type    NVARCHAR(20)  NULL,
    issue_date      NVARCHAR(50)  NULL,
    due_date        NVARCHAR(50)  NULL,
    currency        NVARCHAR(50)  NULL,
    amount          NVARCHAR(50)  NULL,
    description     NVARCHAR(400) NULL
);

IF OBJECT_ID(N'stg.payments', N'U') IS NULL
CREATE TABLE stg.payments (
    _row_id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_payments PRIMARY KEY,
    _carga_id         INT           NOT NULL CONSTRAINT fk_stg_payments_carga REFERENCES audit.carga_staging (carga_id),
    _source_file      NVARCHAR(260) NOT NULL,
    _source_line      INT           NOT NULL,
    _loaded_at        DATETIME2(3)  NOT NULL,
    payment_id        NVARCHAR(50)  NULL,
    payment_reference NVARCHAR(100) NULL,
    invoice_id        NVARCHAR(50)  NULL,
    counterparty_id   NVARCHAR(50)  NULL,
    account_id        NVARCHAR(50)  NULL,
    payment_date      NVARCHAR(50)  NULL,
    currency          NVARCHAR(50)  NULL,
    amount            NVARCHAR(50)  NULL,
    payment_method    NVARCHAR(50)  NULL
);

IF OBJECT_ID(N'stg.collections', N'U') IS NULL
CREATE TABLE stg.collections (
    _row_id              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_collections PRIMARY KEY,
    _carga_id            INT           NOT NULL CONSTRAINT fk_stg_collections_carga REFERENCES audit.carga_staging (carga_id),
    _source_file         NVARCHAR(260) NOT NULL,
    _source_line         INT           NOT NULL,
    _loaded_at           DATETIME2(3)  NOT NULL,
    collection_id        NVARCHAR(50)  NULL,
    collection_reference NVARCHAR(100) NULL,
    invoice_id           NVARCHAR(50)  NULL,
    counterparty_id      NVARCHAR(50)  NULL,
    account_id           NVARCHAR(50)  NULL,
    collection_date      NVARCHAR(50)  NULL,
    currency             NVARCHAR(50)  NULL,
    amount               NVARCHAR(50)  NULL,
    collection_method    NVARCHAR(50)  NULL
);

IF OBJECT_ID(N'stg.bank_statements', N'U') IS NULL
CREATE TABLE stg.bank_statements (
    _row_id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_bank_statements PRIMARY KEY,
    _carga_id         INT           NOT NULL CONSTRAINT fk_stg_bank_statements_carga REFERENCES audit.carga_staging (carga_id),
    _source_file      NVARCHAR(260) NOT NULL,
    _source_line      INT           NOT NULL,
    _loaded_at        DATETIME2(3)  NOT NULL,
    statement_line_id NVARCHAR(100) NULL,
    account_number    NVARCHAR(100) NULL,
    booking_date      NVARCHAR(50)  NULL,
    value_date        NVARCHAR(50)  NULL,
    currency          NVARCHAR(50)  NULL,
    amount            NVARCHAR(50)  NULL,
    bank_tx_code      NVARCHAR(50)  NULL,
    description       NVARCHAR(400) NULL,
    bank_reference    NVARCHAR(100) NULL
);

IF OBJECT_ID(N'stg.bank_balances', N'U') IS NULL
CREATE TABLE stg.bank_balances (
    _row_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_stg_bank_balances PRIMARY KEY,
    _carga_id       INT           NOT NULL CONSTRAINT fk_stg_bank_balances_carga REFERENCES audit.carga_staging (carga_id),
    _source_file    NVARCHAR(260) NOT NULL,
    _source_line    INT           NOT NULL,
    _loaded_at      DATETIME2(3)  NOT NULL,
    account_number  NVARCHAR(100) NULL,
    period          NVARCHAR(20)  NULL,
    currency        NVARCHAR(50)  NULL,
    opening_balance NVARCHAR(50)  NULL,
    total_credits   NVARCHAR(50)  NULL,
    total_debits    NVARCHAR(50)  NULL,
    closing_balance NVARCHAR(50)  NULL,
    line_count      NVARCHAR(20)  NULL
);
GO

/* Índice por archivo en cada tabla: el cargador borra y cuenta "las filas del archivo X"
   en cada corrida; sin este índice serían scans completos que crecen con cada mes. */
DECLARE @t SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID(N'stg');
OPEN c;
FETCH NEXT FROM c INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stg.' + QUOTENAME(@t))
                   AND name = N'ix_' + @t + N'_source')
    BEGIN
        SET @sql = N'CREATE INDEX ' + QUOTENAME(N'ix_' + @t + N'_source') + N' ON stg.' + QUOTENAME(@t)
                 + N' (_source_file, _source_line);';
        EXEC sys.sp_executesql @sql;
    END
    FETCH NEXT FROM c INTO @t;
END
CLOSE c;
DEALLOCATE c;
GO

SELECT t.name AS tabla_staging,
       COUNT(c.column_id) AS columnas,
       SUM(CASE WHEN c.name LIKE N'\_%' ESCAPE N'\' THEN 1 ELSE 0 END) AS columnas_tecnicas
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N'stg')
GROUP BY t.name
ORDER BY t.name;
GO
