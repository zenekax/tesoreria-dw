/* =============================================================================
   02_datos_estaticos.sql — Datos de referencia que NO vienen de las fuentes:
   calendario, monedas, tipos de movimiento bancario y miembros "Desconocido".

   Idempotente con el patrón "insertar lo que falta + actualizar lo que cambió"
   (en vez de MERGE): cada parte se lee por separado y las claves IDENTITY se
   asignan en un orden fijo (INSERT ... SELECT ... ORDER BY), así la reconstrucción
   desde cero da las mismas claves. La elección MERGE vs. insert/update se discute
   en la Fase 4.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ---------------------------------------------------------------- dim_fecha
   GENERATE_SERIES (nuevo en SQL Server 2022) genera los números 0..N sin tablas
   auxiliares ni CTE recursiva; cada número se convierte en un día.
   Todo se calcula sin depender de SET LANGUAGE ni SET DATEFIRST del servidor:
   - día de la semana: días desde el 01/01/1900 (que fue lunes) módulo 7;
   - nombres de mes y día en castellano con CHOOSE. */
DECLARE @desde DATE = '2019-01-01', @hasta DATE = '2027-12-31';

WITH dias AS (
    SELECT DATEADD(DAY, s.value, @desde) AS fecha
    FROM GENERATE_SERIES(0, DATEDIFF(DAY, @desde, @hasta)) AS s
), base AS (
    SELECT fecha, YEAR(fecha) AS anio, MONTH(fecha) AS mes, DAY(fecha) AS dia,
           DATEDIFF(DAY, '19000101', fecha) % 7 + 1 AS dia_semana
    FROM dias
), calc AS (
    SELECT *,
           CASE WHEN dia_semana <= 5 THEN 1 ELSE 0 END AS es_habil,
           -- último día hábil de cada mes: el máximo de los hábiles del mes (window function)
           -- (ELSE con una fecha mínima en vez de NULL: evita el warning "Null value is eliminated")
           MAX(CASE WHEN dia_semana <= 5 THEN fecha ELSE '19000101' END) OVER (PARTITION BY anio, mes) AS ultimo_habil
    FROM base
)
INSERT INTO dw.dim_fecha (fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, dia_semana,
                          nombre_dia, semana_iso, es_habil, es_fin_de_mes, es_ultimo_habil_mes, descripcion)
SELECT anio * 10000 + mes * 100 + dia, fecha, anio, DATEPART(QUARTER, fecha), mes,
       CHOOSE(mes, N'enero', N'febrero', N'marzo', N'abril', N'mayo', N'junio', N'julio',
                   N'agosto', N'septiembre', N'octubre', N'noviembre', N'diciembre'),
       CONVERT(CHAR(7), fecha, 23),                                  -- 'AAAA-MM'
       dia, dia_semana,
       CHOOSE(dia_semana, N'lunes', N'martes', N'miércoles', N'jueves', N'viernes', N'sábado', N'domingo'),
       DATEPART(ISO_WEEK, fecha), es_habil,
       CASE WHEN fecha = EOMONTH(fecha) THEN 1 ELSE 0 END,
       CASE WHEN fecha = ultimo_habil THEN 1 ELSE 0 END,
       CONVERT(NVARCHAR(30), fecha, 103)                             -- 'DD/MM/AAAA'
FROM calc c
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_fecha d WHERE d.fecha_key = c.anio * 10000 + c.mes * 100 + c.dia);

INSERT INTO dw.dim_fecha (fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, dia_semana,
                          nombre_dia, semana_iso, es_habil, es_fin_de_mes, es_ultimo_habil_mes, descripcion)
SELECT v.fecha_key, NULL, 0, 0, 0, N'N/D', 'N/D', 0, 0, N'N/D', 0, 0, 0, 0, v.descripcion
FROM (VALUES (-1, N'Desconocida'), (-2, N'Todavía no ocurrió')) AS v (fecha_key, descripcion)
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_fecha d WHERE d.fecha_key = v.fecha_key);
GO

/* ---------------------------------------------------------------- dim_moneda */
IF NOT EXISTS (SELECT 1 FROM dw.dim_moneda WHERE moneda_key = -1)
BEGIN
    SET IDENTITY_INSERT dw.dim_moneda ON;   -- permite escribir la clave -1 a mano
    INSERT INTO dw.dim_moneda (moneda_key, codigo_iso, nombre, simbolo, decimales, pais_emisor)
    VALUES (-1, 'N/D', N'Desconocida', N'?', 2, NULL);
    SET IDENTITY_INSERT dw.dim_moneda OFF;
END;

DECLARE @monedas TABLE (orden INT, codigo_iso CHAR(3), nombre NVARCHAR(50), simbolo NVARCHAR(5),
                        decimales TINYINT, pais_emisor CHAR(2));
INSERT INTO @monedas VALUES
    (1, 'ARS', N'Peso argentino',    N'$',   2, 'AR'),
    (2, 'USD', N'Dólar estadounidense', N'US$', 2, 'US'),
    (3, 'BRL', N'Real brasileño',    N'R$',  2, 'BR'),
    (4, 'MXN', N'Peso mexicano',     N'MX$', 2, 'MX'),
    (5, 'COP', N'Peso colombiano',   N'COL$', 2, 'CO');

UPDATE d SET nombre = s.nombre, simbolo = s.simbolo, decimales = s.decimales, pais_emisor = s.pais_emisor
FROM dw.dim_moneda d JOIN @monedas s ON s.codigo_iso = d.codigo_iso
WHERE d.nombre <> s.nombre OR d.simbolo <> s.simbolo OR d.decimales <> s.decimales
   OR ISNULL(d.pais_emisor, '') <> ISNULL(s.pais_emisor, '');

INSERT INTO dw.dim_moneda (codigo_iso, nombre, simbolo, decimales, pais_emisor)
SELECT codigo_iso, nombre, simbolo, decimales, pais_emisor
FROM @monedas s
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_moneda d WHERE d.codigo_iso = s.codigo_iso)
ORDER BY orden;   -- el orden define qué clave IDENTITY recibe cada moneda
GO

/* ---------------------------------------------------------------- dim_tipo_movimiento */
IF NOT EXISTS (SELECT 1 FROM dw.dim_tipo_movimiento WHERE tipo_movimiento_key = -1)
BEGIN
    SET IDENTITY_INSERT dw.dim_tipo_movimiento ON;
    INSERT INTO dw.dim_tipo_movimiento (tipo_movimiento_key, codigo, descripcion, categoria, sentido, es_conciliable)
    VALUES (-1, 'N/D', N'Desconocido', 'N/D', 'N/D', 0);
    SET IDENTITY_INSERT dw.dim_tipo_movimiento OFF;
END;

DECLARE @tipos TABLE (orden INT, codigo VARCHAR(20), descripcion NVARCHAR(100), categoria VARCHAR(20),
                      sentido VARCHAR(10), es_conciliable BIT);
INSERT INTO @tipos VALUES
    (1, 'TRF_IN',  N'Transferencia recibida',                  'OPERATIVO', 'INGRESO', 1),
    (2, 'TRF_OUT', N'Transferencia enviada',                   'OPERATIVO', 'EGRESO',  1),
    (3, 'FEE',     N'Comisión bancaria',                       'COMISION',  'EGRESO',  0),
    (4, 'TAX',     N'Impuesto a los débitos y créditos (Ley 25.413)', 'IMPUESTO', 'EGRESO', 0),
    (5, 'FX',      N'Compra/venta de moneda extranjera',       'CAMBIO',    'AMBOS',   0);

UPDATE d SET descripcion = s.descripcion, categoria = s.categoria, sentido = s.sentido, es_conciliable = s.es_conciliable
FROM dw.dim_tipo_movimiento d JOIN @tipos s ON s.codigo = d.codigo
WHERE d.descripcion <> s.descripcion OR d.categoria <> s.categoria OR d.sentido <> s.sentido
   OR d.es_conciliable <> s.es_conciliable;

INSERT INTO dw.dim_tipo_movimiento (codigo, descripcion, categoria, sentido, es_conciliable)
SELECT codigo, descripcion, categoria, sentido, es_conciliable
FROM @tipos s
WHERE NOT EXISTS (SELECT 1 FROM dw.dim_tipo_movimiento d WHERE d.codigo = s.codigo)
ORDER BY orden;
GO

/* ---------------------------------------------------------------- miembros "Desconocido"
   Las cuentas y contrapartes reales las carga el ETL (Fase 4); acá solo la fila -1. */
IF NOT EXISTS (SELECT 1 FROM dw.dim_banco_cuenta WHERE banco_cuenta_key = -1)
BEGIN
    SET IDENTITY_INSERT dw.dim_banco_cuenta ON;
    INSERT INTO dw.dim_banco_cuenta (banco_cuenta_key, cuenta_id, numero_cuenta, moneda_iso, tipo_cuenta, alias,
                                     fecha_apertura, banco_id, banco_nombre, banco_pais, swift_bic)
    VALUES (-1, N'N/D', N'N/D', 'N/D', 'N/D', N'Desconocida', NULL, N'N/D', N'Desconocido', 'ZZ', NULL);
    SET IDENTITY_INSERT dw.dim_banco_cuenta OFF;
END;

IF NOT EXISTS (SELECT 1 FROM dw.dim_contraparte WHERE contraparte_key = -1)
BEGIN
    SET IDENTITY_INSERT dw.dim_contraparte ON;
    INSERT INTO dw.dim_contraparte (contraparte_key, contraparte_id, tipo_contraparte, razon_social, tax_id, email,
                                    pais, moneda_default, fecha_alta, segmento, calificacion_riesgo,
                                    plazo_pago_dias, activa, vigente_desde, vigente_hasta, es_vigente)
    VALUES (-1, N'N/D', 'N/D', N'Desconocida', NULL, NULL, 'ZZ', 'N/D', NULL, 'N/D', 'N/D', 0, 0,
            '1900-01-01', '9999-12-31', 1);
    SET IDENTITY_INSERT dw.dim_contraparte OFF;
END;
GO

SELECT 'dim_fecha' AS dimension, COUNT(*) AS filas, MIN(fecha) AS desde, MAX(fecha) AS hasta FROM dw.dim_fecha
UNION ALL SELECT 'dim_moneda', COUNT(*), NULL, NULL FROM dw.dim_moneda
UNION ALL SELECT 'dim_tipo_movimiento', COUNT(*), NULL, NULL FROM dw.dim_tipo_movimiento
UNION ALL SELECT 'dim_banco_cuenta', COUNT(*), NULL, NULL FROM dw.dim_banco_cuenta
UNION ALL SELECT 'dim_contraparte', COUNT(*), NULL, NULL FROM dw.dim_contraparte;
GO
