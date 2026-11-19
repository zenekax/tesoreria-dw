/* =============================================================================
   01_dimensiones.sql — Dimensiones del esquema estrella (schema dw)

   Analogía: si los hechos son los asientos del libro (cuánto, cuándo), las
   dimensiones son los maestros con los que se lee cada asiento: el calendario,
   la moneda, la cuenta bancaria, la contraparte y el tipo de movimiento.
   Como en SAP, el asiento no repite el nombre del proveedor: guarda su número
   (acá, una clave surrogate) y el nombre se busca en el maestro.

   Convenciones (valen para todas las dimensiones):
   - Clave surrogate INT IDENTITY (`<dim>_key`): no depende del id del sistema
     fuente, ocupa 4 bytes en cada fila de hecho y permite versionar (SCD2), cosa
     imposible si la clave fuera el id de la fuente. Excepción: dim_fecha usa
     AAAAMMDD (ver abajo).
   - La clave del sistema fuente se guarda como "clave natural" con UNIQUE: es lo
     que usa el ETL para encontrar la fila (lookup).
   - Fila -1 "Desconocido" en cada dimensión (miembro desconocido de Kimball): si
     a un hecho le falta un dato, apunta a -1 en vez de NULL. Así los JOIN nunca
     pierden filas y los totales siempre cierran.
   - Columnas de auditoría: cuándo entró y cuándo cambió por última vez la fila.
   - CREATE TABLE solo si no existe: re-ejecutar no borra datos. Un cambio de
     estructura se haría con un script de migración nuevo y numerado.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- dim_fecha
   Una fila por día calendario (2019-2027) + 2 filas especiales.
   Clave AAAAMMDD (20260319) en vez de IDENTITY: es legible, se calcula sin
   lookup (el ETL convierte la fecha directo a clave) y ordena igual que la
   fecha, así que "vencimiento >= emisión" se puede chequear comparando claves.
   Filas especiales: -1 = fecha desconocida (dato inválido en la fuente),
                     -2 = todavía no ocurrió (hitos del snapshot acumulativo). */
IF OBJECT_ID(N'dw.dim_fecha', N'U') IS NULL
CREATE TABLE dw.dim_fecha (
    fecha_key           INT          NOT NULL CONSTRAINT pk_dim_fecha PRIMARY KEY,
    fecha               DATE         NULL,          -- NULL solo en las filas especiales
    anio                SMALLINT     NOT NULL,
    trimestre           TINYINT      NOT NULL,
    mes                 TINYINT      NOT NULL,
    nombre_mes          NVARCHAR(12) NOT NULL,
    anio_mes            CHAR(7)      NOT NULL,      -- '2026-03': práctico para agrupar y para Power BI
    dia                 TINYINT      NOT NULL,
    dia_semana          TINYINT      NOT NULL,      -- 1 = lunes ... 7 = domingo (ISO)
    nombre_dia          NVARCHAR(12) NOT NULL,
    semana_iso          TINYINT      NOT NULL,
    es_habil            BIT          NOT NULL,      -- lunes a viernes (sin feriados: ver docs/modelo.md)
    es_fin_de_mes       BIT          NOT NULL,
    es_ultimo_habil_mes BIT          NOT NULL,      -- día de cierre de tesorería
    descripcion         NVARCHAR(30) NOT NULL,      -- '19/03/2026' o 'Desconocida'
    CONSTRAINT ck_dim_fecha_key CHECK (
        (fecha_key IN (-1, -2) AND fecha IS NULL)
        OR fecha_key = YEAR(fecha) * 10000 + MONTH(fecha) * 100 + DAY(fecha))
);
GO
-- UNIQUE filtrado: una fila por fecha real (las 2 especiales tienen NULL y no cuentan).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_dim_fecha_fecha')
    CREATE UNIQUE INDEX ux_dim_fecha_fecha ON dw.dim_fecha (fecha) WHERE fecha IS NOT NULL;
GO

/* ---------------------------------------------------------------- dim_moneda */
IF OBJECT_ID(N'dw.dim_moneda', N'U') IS NULL
CREATE TABLE dw.dim_moneda (
    moneda_key   INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_moneda PRIMARY KEY,
    codigo_iso   CHAR(3)      NOT NULL CONSTRAINT uq_dim_moneda_codigo UNIQUE,  -- ISO 4217
    nombre       NVARCHAR(50) NOT NULL,
    simbolo      NVARCHAR(5)  NOT NULL,
    decimales    TINYINT      NOT NULL,
    pais_emisor  CHAR(2)      NULL,                -- ISO 3166 alfa-2
    fecha_alta_dw DATETIME2(3) NOT NULL CONSTRAINT df_dim_moneda_alta DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------- dim_tipo_movimiento
   Traduce los códigos del extracto (TRF_IN, FEE, TAX...) a categorías de negocio.
   es_conciliable: solo las transferencias se concilian contra pagos/cobranzas;
   comisiones, impuestos y FX son "del banco" y se explican solas. */
IF OBJECT_ID(N'dw.dim_tipo_movimiento', N'U') IS NULL
CREATE TABLE dw.dim_tipo_movimiento (
    tipo_movimiento_key INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_tipo_movimiento PRIMARY KEY,
    codigo              VARCHAR(20)   NOT NULL CONSTRAINT uq_dim_tipo_movimiento_codigo UNIQUE,
    descripcion         NVARCHAR(100) NOT NULL,
    categoria           VARCHAR(20)   NOT NULL
        CONSTRAINT ck_dim_tipo_movimiento_categoria
        CHECK (categoria IN ('OPERATIVO', 'COMISION', 'IMPUESTO', 'CAMBIO', 'N/D')),
    sentido             VARCHAR(10)   NOT NULL
        CONSTRAINT ck_dim_tipo_movimiento_sentido CHECK (sentido IN ('INGRESO', 'EGRESO', 'AMBOS', 'N/D')),
    es_conciliable      BIT           NOT NULL,
    fecha_alta_dw       DATETIME2(3)  NOT NULL CONSTRAINT df_dim_tipo_movimiento_alta DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------- dim_banco_cuenta
   Una fila por cuenta bancaria propia, con los datos del banco "aplanados" en la
   misma fila (banco_nombre, swift_bic...). No se hace una dim_banco aparte
   (snowflake) porque son 6 bancos: duplicar el nombre del banco en 9 filas no
   cuesta nada y ahorra un JOIN en cada consulta y en Power BI.
   SCD tipo 1: si cambia el alias o el banco corrige un dato, se pisa (no interesa
   la historia de un alias). */
IF OBJECT_ID(N'dw.dim_banco_cuenta', N'U') IS NULL
CREATE TABLE dw.dim_banco_cuenta (
    banco_cuenta_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_banco_cuenta PRIMARY KEY,
    cuenta_id         NVARCHAR(20)  NOT NULL CONSTRAINT uq_dim_banco_cuenta_cuenta UNIQUE,  -- clave natural
    numero_cuenta     NVARCHAR(34)  NOT NULL CONSTRAINT uq_dim_banco_cuenta_numero UNIQUE,  -- CBU/CLABE/IBAN (34 = máx. IBAN)
    moneda_iso        CHAR(3)       NOT NULL,
    tipo_cuenta       VARCHAR(10)   NOT NULL,      -- CC, CA, CHK
    alias             NVARCHAR(100) NOT NULL,
    fecha_apertura    DATE          NULL,
    banco_id          NVARCHAR(20)  NOT NULL,
    banco_nombre      NVARCHAR(200) NOT NULL,
    banco_pais        CHAR(2)       NOT NULL,
    swift_bic         VARCHAR(11)   NULL,          -- 8 u 11 caracteres
    fecha_alta_dw     DATETIME2(3)  NOT NULL CONSTRAINT df_dim_banco_cuenta_alta DEFAULT SYSUTCDATETIME(),
    fecha_modif_dw    DATETIME2(3)  NOT NULL CONSTRAINT df_dim_banco_cuenta_modif DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------- dim_contraparte (SCD tipo 2)
   Proveedores, clientes y corresponsales. Guarda HISTORIA de los atributos que
   cambian el análisis: si un cliente pasó de riesgo BAJO a ALTO en mayo, las
   cobranzas de marzo se tienen que seguir viendo como "riesgo BAJO".

   Analogía: es como guardar las versiones del maestro de proveedores (XK03) con
   "vigente desde / hasta" en vez de pisar el dato. Cada cambio de un atributo
   tipo 2 cierra la versión vigente (vigente_hasta = día anterior) y abre una nueva.
   Cada hecho apunta a la versión que estaba vigente en SU fecha.

   Atributos tipo 2 (con historia): segmento, calificacion_riesgo, plazo_pago_dias, activa.
   Atributos tipo 1 (se corrigen en todas las versiones): razón social, tax_id,
   email, país, moneda, tipo, fecha de alta. Un mail nuevo no cambia cómo
   analizamos un pago viejo; un cambio de riesgo sí. */
IF OBJECT_ID(N'dw.dim_contraparte', N'U') IS NULL
CREATE TABLE dw.dim_contraparte (
    contraparte_key     INT IDENTITY(1,1) NOT NULL CONSTRAINT pk_dim_contraparte PRIMARY KEY,
    contraparte_id      NVARCHAR(20)  NOT NULL,        -- clave natural (se repite entre versiones)
    tipo_contraparte    VARCHAR(20)   NOT NULL
        CONSTRAINT ck_dim_contraparte_tipo CHECK (tipo_contraparte IN ('PROVEEDOR', 'CLIENTE', 'CORRESPONSAL', 'N/D')),
    razon_social        NVARCHAR(300) NOT NULL,
    tax_id              NVARCHAR(50)  NULL,            -- NULL permitido: el control de calidad lo informa (Fase 5)
    email               NVARCHAR(320) NULL,
    pais                CHAR(2)       NOT NULL,
    moneda_default      CHAR(3)       NOT NULL,
    fecha_alta          DATE          NULL,
    -- tipo 2
    segmento            VARCHAR(20)   NOT NULL
        CONSTRAINT ck_dim_contraparte_segmento CHECK (segmento IN ('ESTRATEGICO', 'CORPORATIVO', 'PYME', 'N/D')),
    calificacion_riesgo VARCHAR(10)   NOT NULL
        CONSTRAINT ck_dim_contraparte_riesgo CHECK (calificacion_riesgo IN ('BAJO', 'MEDIO', 'ALTO', 'N/D')),
    plazo_pago_dias     SMALLINT      NOT NULL
        CONSTRAINT ck_dim_contraparte_plazo CHECK (plazo_pago_dias BETWEEN 0 AND 365),
    activa              BIT           NOT NULL,
    -- vigencia de la versión
    vigente_desde       DATE          NOT NULL,
    vigente_hasta       DATE          NOT NULL CONSTRAINT df_dim_contraparte_hasta DEFAULT '9999-12-31',
    es_vigente          BIT           NOT NULL CONSTRAINT df_dim_contraparte_vigente DEFAULT 1,
    /* Huellas para detectar cambios sin comparar columna por columna (las usa el ETL):
       si cambia hash_tipo2 -> nueva versión; si cambia solo hash_tipo1 -> UPDATE.
       PERSISTED: se calculan al escribir la fila, no en cada lectura. CONCAT_WS con
       separador evita falsos iguales ("AB"+"C" vs "A"+"BC"); estilo 112 en la fecha
       hace la conversión determinística (requisito para PERSISTED). */
    hash_tipo2 AS CAST(HASHBYTES('SHA2_256',
        CONCAT_WS(N'|', segmento, calificacion_riesgo, plazo_pago_dias, activa)) AS BINARY(32)) PERSISTED,
    hash_tipo1 AS CAST(HASHBYTES('SHA2_256',
        CONCAT_WS(N'|', tipo_contraparte, razon_social, tax_id, email, pais, moneda_default,
                  CONVERT(CHAR(8), fecha_alta, 112))) AS BINARY(32)) PERSISTED,
    fecha_alta_dw       DATETIME2(3)  NOT NULL CONSTRAINT df_dim_contraparte_alta DEFAULT SYSUTCDATETIME(),
    fecha_modif_dw      DATETIME2(3)  NOT NULL CONSTRAINT df_dim_contraparte_modif DEFAULT SYSUTCDATETIME(),
    CONSTRAINT uq_dim_contraparte_version UNIQUE (contraparte_id, vigente_desde),
    CONSTRAINT ck_dim_contraparte_vigencia CHECK (vigente_hasta >= vigente_desde),
    -- La versión vigente es la única "abierta" (hasta 9999-12-31); las cerradas tienen fecha real.
    CONSTRAINT ck_dim_contraparte_es_vigente CHECK (
        (es_vigente = 1 AND vigente_hasta = '9999-12-31') OR (es_vigente = 0 AND vigente_hasta < '9999-12-31'))
);
GO
-- Una sola versión vigente por contraparte. Un UNIQUE común no sirve (hay muchas
-- versiones cerradas); el índice filtrado aplica la regla solo a las vigentes.
-- También es el índice que usa el ETL para buscar "la versión actual de CP0012".
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_dim_contraparte_vigente')
    CREATE UNIQUE INDEX ux_dim_contraparte_vigente ON dw.dim_contraparte (contraparte_id)
        INCLUDE (hash_tipo1, hash_tipo2) WHERE es_vigente = 1;
GO

SELECT t.name AS dimension, COUNT(c.column_id) AS columnas
FROM sys.tables t JOIN sys.columns c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID(N'dw') AND t.name LIKE N'dim\_%' ESCAPE N'\'
GROUP BY t.name ORDER BY t.name;
GO
