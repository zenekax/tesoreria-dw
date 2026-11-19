/* =============================================================================
   03_hechos.sql — Tablas de hechos del esquema estrella (schema dw)

   GRANO = qué representa exactamente UNA fila. Es la decisión más importante de
   cada hecho: define qué se puede sumar y qué no. Si el grano se mezcla (algunas
   filas por pago, otras por factura), los totales se duplican sin avisar.

   Los tres tipos de hecho de Kimball aparecen acá:
   - TRANSACCIÓN: una fila por evento, nunca se actualiza (facturas, pagos,
     cobranzas, movimientos bancarios). Es el libro diario.
   - SNAPSHOT PERIÓDICO: una foto a intervalos fijos (saldo bancario mensual,
     tipo de cambio diario). Es el "saldo al cierre".
   - SNAPSHOT ACUMULATIVO: una fila por proceso que se va completando a medida
     que pasan los hitos (conciliación). Es la planilla de conciliación que se
     actualiza cada día.

   Convenciones:
   - Montos DECIMAL(19,2): exactos (nunca FLOAT para plata). No se usa MONEY
     porque redondea a 4 decimales en multiplicaciones/divisiones intermedias y
     es propietario de SQL Server. 19 dígitos alcanzan para un billón de COP.
   - Cada hecho guarda monto en moneda original + tipo de cambio usado + monto en
     USD al día de la operación: así se consolida en USD sin recalcular y queda
     registrado con qué TC se convirtió (auditable). Para revaluar a TC de cierre
     está fact_tipo_cambio.
   - Claves foráneas DECLARADAS y verificadas (WITH CHECK): cuestan un poco en la
     carga, pero garantizan que ningún hecho apunte a una dimensión inexistente y
     le permiten al optimizador eliminar JOINs innecesarios. Lo que no tiene
     dimensión válida apunta al miembro -1, nunca a NULL.
   - Los ids de la fuente (pago_id, factura_id...) quedan en el hecho como
     "dimensiones degeneradas": sirven para buscar y auditar, sin tabla propia.
   - Índices: solo la PK y los UNIQUE de negocio (los necesita la carga
     idempotente). Los índices para consultas se agregan en la Fase 7, con evidencia.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- fact_facturas (transacción)
   GRANO: una fila por factura del ERP (AP = de un proveedor/corresponsal a pagar;
   AR = nuestra, a cobrar a un cliente). Base del aging y del "pagado vs. facturado". */
IF OBJECT_ID(N'dw.fact_facturas', N'U') IS NULL
CREATE TABLE dw.fact_facturas (
    factura_key            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_facturas PRIMARY KEY,
    factura_id             NVARCHAR(20)  NOT NULL CONSTRAINT uq_fact_facturas_id UNIQUE,   -- degenerada
    numero_factura         NVARCHAR(50)  NOT NULL,
    tipo_factura           CHAR(2)       NOT NULL CONSTRAINT ck_fact_facturas_tipo CHECK (tipo_factura IN ('AP', 'AR')),
    contraparte_key        INT           NOT NULL CONSTRAINT fk_fact_facturas_contraparte REFERENCES dw.dim_contraparte,
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_facturas_moneda REFERENCES dw.dim_moneda,
    fecha_emision_key      INT           NOT NULL CONSTRAINT fk_fact_facturas_emision REFERENCES dw.dim_fecha,
    fecha_vencimiento_key  INT           NOT NULL CONSTRAINT fk_fact_facturas_vencimiento REFERENCES dw.dim_fecha,
    monto                  DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_facturas_monto CHECK (monto > 0),
    tipo_cambio_usd        DECIMAL(19,6) NOT NULL CONSTRAINT ck_fact_facturas_tc CHECK (tipo_cambio_usd > 0),
    monto_usd              DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_facturas_monto_usd CHECK (monto_usd > 0),
    descripcion            NVARCHAR(400) NULL,
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_facturas_carga DEFAULT SYSUTCDATETIME(),
    -- La clave AAAAMMDD ordena igual que la fecha: se puede comparar sin JOIN.
    CONSTRAINT ck_fact_facturas_fechas CHECK (fecha_vencimiento_key >= fecha_emision_key)
);
GO

/* ---------------------------------------------------------------- fact_pagos (transacción)
   GRANO: una fila por pago ejecutado (una línea de la corrida de pagos, F110).
   Una factura puede tener varios pagos (parciales): el pago es el grano, no la factura. */
IF OBJECT_ID(N'dw.fact_pagos', N'U') IS NULL
CREATE TABLE dw.fact_pagos (
    pago_key               BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_pagos PRIMARY KEY,
    pago_id                NVARCHAR(20)  NOT NULL CONSTRAINT uq_fact_pagos_id UNIQUE,
    referencia_pago        NVARCHAR(50)  NOT NULL,
    factura_id             NVARCHAR(20)  NOT NULL,   -- degenerada: enlaza con fact_facturas
    contraparte_key        INT           NOT NULL CONSTRAINT fk_fact_pagos_contraparte REFERENCES dw.dim_contraparte,
    banco_cuenta_key       INT           NOT NULL CONSTRAINT fk_fact_pagos_cuenta REFERENCES dw.dim_banco_cuenta,
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_pagos_moneda REFERENCES dw.dim_moneda,
    fecha_pago_key         INT           NOT NULL CONSTRAINT fk_fact_pagos_fecha REFERENCES dw.dim_fecha,
    medio_pago             VARCHAR(20)   NOT NULL,   -- SWIFT, PIX, SPEI...: pocos valores, no justifica dimensión
    monto                  DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_pagos_monto CHECK (monto > 0),
    tipo_cambio_usd        DECIMAL(19,6) NOT NULL CONSTRAINT ck_fact_pagos_tc CHECK (tipo_cambio_usd > 0),
    monto_usd              DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_pagos_monto_usd CHECK (monto_usd > 0),
    dias_vs_vencimiento    INT           NULL,       -- pago - vencimiento (negativo = anticipado)
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_pagos_carga DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------- fact_cobranzas (transacción)
   GRANO: una fila por cobranza recibida (un ingreso imputado a una factura AR). */
IF OBJECT_ID(N'dw.fact_cobranzas', N'U') IS NULL
CREATE TABLE dw.fact_cobranzas (
    cobranza_key           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_cobranzas PRIMARY KEY,
    cobranza_id            NVARCHAR(20)  NOT NULL CONSTRAINT uq_fact_cobranzas_id UNIQUE,
    referencia_cobranza    NVARCHAR(50)  NOT NULL,   -- la que puso el cliente en la transferencia
    factura_id             NVARCHAR(20)  NOT NULL,
    contraparte_key        INT           NOT NULL CONSTRAINT fk_fact_cobranzas_contraparte REFERENCES dw.dim_contraparte,
    banco_cuenta_key       INT           NOT NULL CONSTRAINT fk_fact_cobranzas_cuenta REFERENCES dw.dim_banco_cuenta,
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_cobranzas_moneda REFERENCES dw.dim_moneda,
    fecha_cobranza_key     INT           NOT NULL CONSTRAINT fk_fact_cobranzas_fecha REFERENCES dw.dim_fecha,
    medio_cobro            VARCHAR(20)   NOT NULL,
    monto                  DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_cobranzas_monto CHECK (monto > 0),
    tipo_cambio_usd        DECIMAL(19,6) NOT NULL CONSTRAINT ck_fact_cobranzas_tc CHECK (tipo_cambio_usd > 0),
    monto_usd              DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_cobranzas_monto_usd CHECK (monto_usd > 0),
    dias_atraso            INT           NULL,       -- cobranza - vencimiento (negativo = cobró antes)
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_cobranzas_carga DEFAULT SYSUTCDATETIME()
);
GO

/* ---------------------------------------------------------------- fact_movimientos_bancarios (transacción)
   GRANO: una fila por línea del extracto bancario, una sola vez (si el banco reenvía
   la misma línea en el extracto siguiente, el duplicado va a cuarentena en la Fase 5).
   Monto CON SIGNO (débitos negativos), igual que el extracto: así el flujo de caja
   es un SUM directo, sin CASE por tipo. */
IF OBJECT_ID(N'dw.fact_movimientos_bancarios', N'U') IS NULL
CREATE TABLE dw.fact_movimientos_bancarios (
    movimiento_key         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_movimientos_bancarios PRIMARY KEY,
    linea_extracto_id      NVARCHAR(50)  NOT NULL CONSTRAINT uq_fact_movimientos_linea UNIQUE,
    banco_cuenta_key       INT           NOT NULL CONSTRAINT fk_fact_movimientos_cuenta REFERENCES dw.dim_banco_cuenta,
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_movimientos_moneda REFERENCES dw.dim_moneda,
    tipo_movimiento_key    INT           NOT NULL CONSTRAINT fk_fact_movimientos_tipo REFERENCES dw.dim_tipo_movimiento,
    fecha_imputacion_key   INT           NOT NULL CONSTRAINT fk_fact_movimientos_imputacion REFERENCES dw.dim_fecha,
    fecha_valor_key        INT           NOT NULL CONSTRAINT fk_fact_movimientos_valor REFERENCES dw.dim_fecha,
    monto                  DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_movimientos_monto CHECK (monto <> 0),
    tipo_cambio_usd        DECIMAL(19,6) NOT NULL CONSTRAINT ck_fact_movimientos_tc CHECK (tipo_cambio_usd > 0),
    monto_usd              DECIMAL(19,2) NOT NULL,
    descripcion            NVARCHAR(400) NULL,
    referencia_banco       NVARCHAR(50)  NULL,
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_movimientos_carga DEFAULT SYSUTCDATETIME(),
    CONSTRAINT ck_fact_movimientos_signo_usd CHECK (SIGN(monto_usd) = SIGN(monto) OR monto_usd = 0)
);
GO

/* ---------------------------------------------------------------- fact_saldo_bancario_mensual (snapshot periódico)
   GRANO: una fila por cuenta bancaria y mes (saldo que informa el banco al cierre).
   Sirve de saldo inicial del flujo de caja y de TOTAL DE CONTROL: el CHECK obliga a
   que inicial + créditos + débitos = final, como la cuadratura de un extracto. */
IF OBJECT_ID(N'dw.fact_saldo_bancario_mensual', N'U') IS NULL
CREATE TABLE dw.fact_saldo_bancario_mensual (
    banco_cuenta_key       INT           NOT NULL CONSTRAINT fk_fact_saldo_cuenta REFERENCES dw.dim_banco_cuenta,
    fecha_cierre_key       INT           NOT NULL CONSTRAINT fk_fact_saldo_fecha REFERENCES dw.dim_fecha,  -- último día del mes
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_saldo_moneda REFERENCES dw.dim_moneda,
    saldo_inicial          DECIMAL(19,2) NOT NULL,
    total_creditos         DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_saldo_creditos CHECK (total_creditos >= 0),
    total_debitos          DECIMAL(19,2) NOT NULL CONSTRAINT ck_fact_saldo_debitos CHECK (total_debitos <= 0),
    saldo_final            DECIMAL(19,2) NOT NULL,
    cantidad_movimientos   INT           NOT NULL CONSTRAINT ck_fact_saldo_cantidad CHECK (cantidad_movimientos >= 0),
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_saldo_carga DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_fact_saldo_bancario_mensual PRIMARY KEY (banco_cuenta_key, fecha_cierre_key),
    CONSTRAINT ck_fact_saldo_cuadra CHECK (saldo_inicial + total_creditos + total_debitos = saldo_final)
);
GO

/* ---------------------------------------------------------------- fact_tipo_cambio (snapshot periódico)
   GRANO: una cotización por moneda y día hábil (unidades de moneda por 1 USD).
   Se usa para convertir los hechos al cargarlos y para revaluar a TC de cierre. */
IF OBJECT_ID(N'dw.fact_tipo_cambio', N'U') IS NULL
CREATE TABLE dw.fact_tipo_cambio (
    fecha_key              INT           NOT NULL CONSTRAINT fk_fact_tc_fecha REFERENCES dw.dim_fecha,
    moneda_key             INT           NOT NULL CONSTRAINT fk_fact_tc_moneda REFERENCES dw.dim_moneda,
    tipo_cambio_por_usd    DECIMAL(19,6) NOT NULL CONSTRAINT ck_fact_tc_valor CHECK (tipo_cambio_por_usd > 0),
    fuente                 NVARCHAR(50)  NOT NULL,
    fecha_carga_dw         DATETIME2(3)  NOT NULL CONSTRAINT df_fact_tc_carga DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_fact_tipo_cambio PRIMARY KEY (fecha_key, moneda_key)
);
GO

/* ---------------------------------------------------------------- fact_conciliacion (snapshot acumulativo)
   GRANO: una PARTIDA DE CONCILIACIÓN, como en la planilla de conciliación bancaria:
     - cada pago o cobranza del ERP genera una partida (origen PAGO / COBRANZA);
     - cada movimiento conciliable del banco que no matchea con nada genera una
       partida propia (origen BANCO);
     - si un movimiento del ERP y uno del banco matchean, comparten la MISMA fila.
   La fila se va completando con los hitos: emisión de la factura -> vencimiento ->
   registro en libros (ERP) -> movimiento en el banco -> conciliación. Un hito que
   todavía no pasó apunta a la fecha -2 ("Todavía no ocurrió").
   Montos con el signo del banco (pagos negativos, cobranzas positivas), para que
   libro y banco se comparen directo.
   Estados:
     CONCILIADA                 libro y banco presentes, misma plata
     CONCILIADA_CON_DIFERENCIA  presentes los dos, con diferencia (ej. comisión SWIFT descontada)
     PENDIENTE_EN_BANCO         está en libros y todavía no en el banco (en tránsito o rechazado)
     PENDIENTE_EN_LIBROS        está en el banco y nadie lo registró en el ERP */
IF OBJECT_ID(N'dw.fact_conciliacion', N'U') IS NULL
CREATE TABLE dw.fact_conciliacion (
    conciliacion_key            BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT pk_fact_conciliacion PRIMARY KEY,
    origen                      VARCHAR(10)   NOT NULL
        CONSTRAINT ck_fact_conciliacion_origen CHECK (origen IN ('PAGO', 'COBRANZA', 'BANCO')),
    pago_id                     NVARCHAR(20)  NULL,
    cobranza_id                 NVARCHAR(20)  NULL,
    linea_extracto_id           NVARCHAR(50)  NULL,
    factura_id                  NVARCHAR(20)  NULL,
    contraparte_key             INT           NOT NULL CONSTRAINT fk_fact_conciliacion_contraparte REFERENCES dw.dim_contraparte,
    banco_cuenta_key            INT           NOT NULL CONSTRAINT fk_fact_conciliacion_cuenta REFERENCES dw.dim_banco_cuenta,
    moneda_key                  INT           NOT NULL CONSTRAINT fk_fact_conciliacion_moneda REFERENCES dw.dim_moneda,
    -- hitos (todos contra dim_fecha; -2 = todavía no ocurrió)
    fecha_emision_factura_key   INT NOT NULL CONSTRAINT df_fact_conc_emision DEFAULT -2
                                CONSTRAINT fk_fact_conciliacion_emision REFERENCES dw.dim_fecha,
    fecha_vencimiento_key       INT NOT NULL CONSTRAINT df_fact_conc_vencimiento DEFAULT -2
                                CONSTRAINT fk_fact_conciliacion_vencimiento REFERENCES dw.dim_fecha,
    fecha_libro_key             INT NOT NULL CONSTRAINT df_fact_conc_libro DEFAULT -2
                                CONSTRAINT fk_fact_conciliacion_libro REFERENCES dw.dim_fecha,
    fecha_banco_key             INT NOT NULL CONSTRAINT df_fact_conc_banco DEFAULT -2
                                CONSTRAINT fk_fact_conciliacion_banco REFERENCES dw.dim_fecha,
    fecha_conciliacion_key      INT NOT NULL CONSTRAINT df_fact_conc_conciliacion DEFAULT -2
                                CONSTRAINT fk_fact_conciliacion_conciliacion REFERENCES dw.dim_fecha,
    monto_libro                 DECIMAL(19,2) NULL,
    monto_banco                 DECIMAL(19,2) NULL,
    diferencia                  AS (monto_banco - monto_libro) PERSISTED,
    dias_habiles_desfase        INT           NULL,   -- de libro a banco
    estado                      VARCHAR(30)   NOT NULL
        CONSTRAINT ck_fact_conciliacion_estado CHECK (estado IN
            ('CONCILIADA', 'CONCILIADA_CON_DIFERENCIA', 'PENDIENTE_EN_BANCO', 'PENDIENTE_EN_LIBROS')),
    metodo_match                VARCHAR(20)   NULL
        CONSTRAINT ck_fact_conciliacion_metodo CHECK (metodo_match IN ('REFERENCIA', 'MONTO_FECHA', 'MANUAL')),
    fecha_alta_dw               DATETIME2(3)  NOT NULL CONSTRAINT df_fact_conc_alta DEFAULT SYSUTCDATETIME(),
    fecha_actualizacion_dw      DATETIME2(3)  NOT NULL CONSTRAINT df_fact_conc_actualizacion DEFAULT SYSUTCDATETIME(),

    -- El origen define qué id tiene que estar: una partida del ERP tiene su pago O su
    -- cobranza (nunca los dos); una partida del banco no tiene ninguno pero sí la línea.
    CONSTRAINT ck_fact_conciliacion_ids CHECK (
           (origen = 'PAGO'     AND pago_id IS NOT NULL AND cobranza_id IS NULL AND monto_libro < 0)
        OR (origen = 'COBRANZA' AND cobranza_id IS NOT NULL AND pago_id IS NULL AND monto_libro > 0)
        OR (origen = 'BANCO'    AND pago_id IS NULL AND cobranza_id IS NULL
                                AND linea_extracto_id IS NOT NULL AND monto_libro IS NULL)),
    -- El estado tiene que ser coherente con lo que hay en la fila (no se puede decir
    -- "conciliada" sin la línea del banco, ni "conciliada" con diferencia distinta de cero).
    CONSTRAINT ck_fact_conciliacion_estado_coherente CHECK (
           (estado = 'CONCILIADA'                AND linea_extracto_id IS NOT NULL AND monto_libro IS NOT NULL
                                                 AND monto_banco = monto_libro AND fecha_conciliacion_key > 0)
        OR (estado = 'CONCILIADA_CON_DIFERENCIA' AND linea_extracto_id IS NOT NULL AND monto_libro IS NOT NULL
                                                 AND monto_banco <> monto_libro AND fecha_conciliacion_key > 0)
        OR (estado = 'PENDIENTE_EN_BANCO'        AND origen <> 'BANCO' AND linea_extracto_id IS NULL
                                                 AND monto_banco IS NULL AND fecha_conciliacion_key = -2)
        OR (estado = 'PENDIENTE_EN_LIBROS'       AND origen = 'BANCO' AND monto_banco IS NOT NULL
                                                 AND fecha_conciliacion_key = -2)),
    -- (T-SQL no tiene booleanos comparables: "A = B" entre condiciones no existe; se escribe con OR.)
    CONSTRAINT ck_fact_conciliacion_metodo_coherente CHECK (
           (metodo_match IS NULL     AND estado IN ('PENDIENTE_EN_BANCO', 'PENDIENTE_EN_LIBROS'))
        OR (metodo_match IS NOT NULL AND estado IN ('CONCILIADA', 'CONCILIADA_CON_DIFERENCIA')))
);
GO
-- Cada pago, cobranza y línea de extracto puede estar en UNA sola partida (una línea
-- del banco no puede "conciliar" dos pagos). UNIQUE filtrado: ignora los NULL.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_fact_conciliacion_pago')
    CREATE UNIQUE INDEX ux_fact_conciliacion_pago ON dw.fact_conciliacion (pago_id) WHERE pago_id IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_fact_conciliacion_cobranza')
    CREATE UNIQUE INDEX ux_fact_conciliacion_cobranza ON dw.fact_conciliacion (cobranza_id) WHERE cobranza_id IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ux_fact_conciliacion_linea')
    CREATE UNIQUE INDEX ux_fact_conciliacion_linea ON dw.fact_conciliacion (linea_extracto_id) WHERE linea_extracto_id IS NOT NULL;
GO

SELECT t.name AS hecho,
       (SELECT COUNT(*) FROM sys.foreign_keys fk WHERE fk.parent_object_id = t.object_id) AS fks,
       (SELECT COUNT(*) FROM sys.check_constraints ck WHERE ck.parent_object_id = t.object_id) AS checks
FROM sys.tables t
WHERE t.schema_id = SCHEMA_ID(N'dw') AND t.name LIKE N'fact\_%' ESCAPE N'\'
ORDER BY t.name;
GO
