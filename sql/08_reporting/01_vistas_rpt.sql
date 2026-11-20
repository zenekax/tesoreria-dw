/* =============================================================================
   01_vistas_rpt.sql — Capa de consumo para Power BI (schema rpt).

   Por qué vistas y no las tablas dw directo:
   - Nombres de negocio y solo las columnas que un reporte necesita (sin claves técnicas de
     auditoría, sin hashes, sin datos sensibles que no se usan).
   - Un "contrato" estable: si mañana cambia una tabla de dw, se ajusta la vista y el tablero
     no se rompe.
   - La seguridad viaja sola: RLS y masking se aplican sobre las tablas de dw, así que un
     analista que abre el tablero ve solo sus monedas y los CBU enmascarados, sin configurar
     nada en Power BI.

   Dos tipos de vista:
   - ESTRELLA (dim_* y fact_*): para que Power BI arme el modelo con relaciones por clave.
   - CALCULADAS (v_*): flujo de caja con saldo acumulado, aging al último cierre, evolución
     mensual de la cartera. Lógica de SQL que en DAX sería más difícil de leer y de mantener.

   Las vistas no admiten ORDER BY ni OPTION(...): el orden lo pone el reporte.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* ------------------------------------------------------------------ dimensiones */
CREATE OR ALTER VIEW rpt.dim_fecha AS
SELECT fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, nombre_dia, semana_iso,
       CAST(es_habil AS BIT) AS es_habil, CAST(es_ultimo_habil_mes AS BIT) AS es_ultimo_habil_mes, descripcion
FROM dw.dim_fecha;
GO

CREATE OR ALTER VIEW rpt.dim_moneda AS
SELECT moneda_key, codigo_iso AS moneda, nombre AS moneda_nombre, simbolo
FROM dw.dim_moneda;
GO

CREATE OR ALTER VIEW rpt.dim_cuenta AS
SELECT banco_cuenta_key, alias AS cuenta, banco_nombre AS banco, banco_pais AS pais_banco, moneda_iso AS moneda,
       tipo_cuenta, numero_cuenta          -- enmascarado para quien no tenga UNMASK
FROM dw.dim_banco_cuenta;
GO

CREATE OR ALTER VIEW rpt.dim_contraparte AS
SELECT contraparte_key, contraparte_id, razon_social, tipo_contraparte, pais, moneda_default, segmento,
       calificacion_riesgo, plazo_pago_dias, CAST(activa AS BIT) AS activa, vigente_desde, vigente_hasta,
       CAST(es_vigente AS BIT) AS es_version_vigente
FROM dw.dim_contraparte;
GO

/* ------------------------------------------------------------------ hechos */
CREATE OR ALTER VIEW rpt.fact_movimientos AS
SELECT m.linea_extracto_id, m.fecha_imputacion_key AS fecha_key, m.moneda_key, m.banco_cuenta_key,
       t.codigo AS tipo_movimiento, t.descripcion AS tipo_descripcion, t.categoria,
       m.monto, m.monto_usd,
       IIF(m.monto > 0, m.monto, 0) AS ingreso, IIF(m.monto < 0, -m.monto, 0) AS egreso,
       m.descripcion
FROM dw.fact_movimientos_bancarios m
JOIN dw.dim_tipo_movimiento t ON t.tipo_movimiento_key = m.tipo_movimiento_key;
GO

CREATE OR ALTER VIEW rpt.fact_pagos AS
SELECT pago_id, factura_id, fecha_pago_key AS fecha_key, contraparte_key, banco_cuenta_key, moneda_key,
       medio_pago, monto, monto_usd, dias_vs_vencimiento,
       IIF(dias_vs_vencimiento > 0, N'Pagado con atraso', N'Pagado en término') AS puntualidad
FROM dw.fact_pagos;
GO

CREATE OR ALTER VIEW rpt.fact_cobranzas AS
SELECT cobranza_id, factura_id, fecha_cobranza_key AS fecha_key, contraparte_key, banco_cuenta_key, moneda_key,
       medio_cobro, monto, monto_usd, dias_atraso
FROM dw.fact_cobranzas;
GO

CREATE OR ALTER VIEW rpt.fact_facturas AS
SELECT factura_id, numero_factura, IIF(tipo_factura = 'AR', N'A cobrar', N'A pagar') AS tipo,
       fecha_emision_key, fecha_vencimiento_key, contraparte_key, moneda_key, monto, monto_usd
FROM dw.fact_facturas;
GO

CREATE OR ALTER VIEW rpt.fact_conciliacion AS
SELECT conciliacion_key, origen, COALESCE(pago_id, cobranza_id, linea_extracto_id) AS partida,
       banco_cuenta_key, moneda_key, contraparte_key,
       fecha_libro_key, fecha_banco_key, fecha_conciliacion_key,
       -- fecha de la partida: la del libro, o la del banco si es una partida "solo banco"
       -- (los hitos que no ocurrieron valen -2, no NULL: COALESCE no sirve acá)
       IIF(fecha_libro_key > 0, fecha_libro_key, fecha_banco_key) AS fecha_key,
       estado,
       CASE estado WHEN 'CONCILIADA' THEN N'Conciliada'
                   WHEN 'CONCILIADA_CON_DIFERENCIA' THEN N'Conciliada con diferencia'
                   WHEN 'PENDIENTE_EN_BANCO' THEN N'Pendiente en banco'
                   ELSE N'Pendiente en libros' END AS estado_descripcion,
       CAST(IIF(estado LIKE 'CONCILIADA%', 1, 0) AS BIT) AS esta_conciliada,
       metodo_match, monto_libro, monto_banco, diferencia, dias_habiles_desfase
FROM dw.fact_conciliacion;
GO

/* ------------------------------------------------------------------ vistas calculadas */
-- Flujo de caja diario por moneda: todos los días (con o sin movimientos) y saldo acumulado.
CREATE OR ALTER VIEW rpt.v_flujo_caja_diario AS
WITH apertura AS (
    SELECT s.moneda_key, SUM(s.saldo_inicial) AS saldo_inicial,
           MIN(EOMONTH(f.fecha, -1)) AS dia_anterior_al_inicio
    FROM dw.fact_saldo_bancario_mensual s
    JOIN dw.dim_fecha f ON f.fecha_key = s.fecha_cierre_key
    WHERE s.fecha_cierre_key = (SELECT MIN(fecha_cierre_key) FROM dw.fact_saldo_bancario_mensual)
    GROUP BY s.moneda_key
), rango AS (
    SELECT MIN(f.fecha) AS desde, MAX(f.fecha) AS hasta
    FROM dw.fact_saldo_bancario_mensual s JOIN dw.dim_fecha f ON f.fecha_key = s.fecha_cierre_key
), movimientos AS (
    SELECT moneda_key, fecha_imputacion_key AS fecha_key,
           SUM(IIF(monto > 0, monto, 0)) AS ingresos, SUM(IIF(monto < 0, -monto, 0)) AS egresos
    FROM dw.fact_movimientos_bancarios
    GROUP BY moneda_key, fecha_imputacion_key
)
SELECT d.fecha_key, d.fecha, a.moneda_key, mo.codigo_iso AS moneda,
       ISNULL(mv.ingresos, 0) AS ingresos, ISNULL(mv.egresos, 0) AS egresos,
       ISNULL(mv.ingresos, 0) - ISNULL(mv.egresos, 0) AS neto,
       a.saldo_inicial + SUM(ISNULL(mv.ingresos, 0) - ISNULL(mv.egresos, 0))
           OVER (PARTITION BY a.moneda_key ORDER BY d.fecha ROWS UNBOUNDED PRECEDING) AS saldo_cierre
FROM dw.dim_fecha d
CROSS JOIN rango r
CROSS JOIN apertura a
JOIN dw.dim_moneda mo ON mo.moneda_key = a.moneda_key
LEFT JOIN movimientos mv ON mv.moneda_key = a.moneda_key AND mv.fecha_key = d.fecha_key
WHERE d.fecha > a.dia_anterior_al_inicio AND d.fecha <= r.hasta;
GO

-- Aging de cuentas a cobrar al ÚLTIMO cierre informado por el banco, revaluado al TC de ese día.
CREATE OR ALTER VIEW rpt.v_aging_cobranzas AS
WITH corte AS (
    SELECT MAX(fecha_cierre_key) AS corte_key FROM dw.fact_saldo_bancario_mensual
), cobrado AS (
    SELECT c.factura_id, SUM(c.monto) AS cobrado
    FROM dw.fact_cobranzas c CROSS JOIN corte
    WHERE c.fecha_cobranza_key <= corte.corte_key
    GROUP BY c.factura_id
), abiertas AS (
    SELECT f.factura_id, f.numero_factura, f.contraparte_key, f.moneda_key, fc.fecha AS fecha_corte,
           fv.fecha AS vencimiento, f.monto - ISNULL(cb.cobrado, 0) AS saldo,
           DATEDIFF(DAY, fv.fecha, fc.fecha) AS dias_vencido, corte.corte_key
    FROM dw.fact_facturas f
    CROSS JOIN corte
    JOIN dw.dim_fecha fc ON fc.fecha_key = corte.corte_key
    JOIN dw.dim_fecha fv ON fv.fecha_key = f.fecha_vencimiento_key
    LEFT JOIN cobrado cb ON cb.factura_id = f.factura_id
    WHERE f.tipo_factura = 'AR' AND f.fecha_emision_key <= corte.corte_key AND f.monto - ISNULL(cb.cobrado, 0) > 0
)
SELECT a.factura_id, a.numero_factura, a.contraparte_key, a.moneda_key, a.fecha_corte, a.vencimiento,
       a.saldo, CAST(a.saldo / tc.tipo_cambio_por_usd AS DECIMAL(19,2)) AS saldo_usd_cierre, a.dias_vencido,
       CASE WHEN a.dias_vencido <= 0 THEN N'No vencido' WHEN a.dias_vencido <= 30 THEN N'1-30'
            WHEN a.dias_vencido <= 60 THEN N'31-60' WHEN a.dias_vencido <= 90 THEN N'61-90' ELSE N'+90' END AS tramo,
       CASE WHEN a.dias_vencido <= 0 THEN 0 WHEN a.dias_vencido <= 30 THEN 1
            WHEN a.dias_vencido <= 60 THEN 2 WHEN a.dias_vencido <= 90 THEN 3 ELSE 4 END AS orden_tramo   -- "Ordenar por columna" en Power BI
FROM abiertas a
CROSS APPLY (SELECT TOP (1) t.tipo_cambio_por_usd FROM dw.fact_tipo_cambio t
             WHERE t.moneda_key = a.moneda_key AND t.fecha_key <= a.corte_key ORDER BY t.fecha_key DESC) tc;
GO

-- Evolución mensual de la cartera y DSO (misma lógica que sql/06_queries/07, sin los hints de
-- consulta, que una vista no admite).
CREATE OR ALTER VIEW rpt.v_evolucion_cartera AS
WITH cierres AS (
    SELECT DISTINCT f.fecha AS cierre, s.fecha_cierre_key AS cierre_key
    FROM dw.fact_saldo_bancario_mensual s JOIN dw.dim_fecha f ON f.fecha_key = s.fecha_cierre_key
), cobrado_mes AS (
    SELECT x.factura_id, EOMONTH(fc.fecha) AS cierre, SUM(x.monto) AS cobrado_mes
    FROM dw.fact_cobranzas x JOIN dw.dim_fecha fc ON fc.fecha_key = x.fecha_cobranza_key
    GROUP BY x.factura_id, EOMONTH(fc.fecha)
), acumulado AS (
    SELECT c.cierre, f.monto, f.monto_usd, f.fecha_vencimiento_key,
           SUM(ISNULL(cm.cobrado_mes, 0)) OVER (PARTITION BY f.factura_id ORDER BY c.cierre ROWS UNBOUNDED PRECEDING) AS cobrado
    FROM cierres c
    JOIN dw.fact_facturas f ON f.tipo_factura = 'AR' AND f.fecha_emision_key <= c.cierre_key
    LEFT JOIN cobrado_mes cm ON cm.factura_id = f.factura_id AND cm.cierre = c.cierre
), cartera AS (
    SELECT a.cierre, COUNT(*) AS facturas_abiertas,
           SUM(a.monto_usd * (a.monto - a.cobrado) / a.monto) AS cartera_usd,
           SUM(IIF(DATEDIFF(DAY, fv.fecha, a.cierre) > 30, a.monto_usd * (a.monto - a.cobrado) / a.monto, 0)) AS vencida_30_usd
    FROM acumulado a JOIN dw.dim_fecha fv ON fv.fecha_key = a.fecha_vencimiento_key
    WHERE a.monto - a.cobrado > 0
    GROUP BY a.cierre
)
SELECT c.cierre, c.cierre_key AS fecha_key, ca.facturas_abiertas,
       CAST(ca.cartera_usd AS DECIMAL(19,2)) AS cartera_usd, CAST(ca.vencida_30_usd AS DECIMAL(19,2)) AS vencida_30_usd,
       v.ventas_90d_usd, CAST(ca.cartera_usd / NULLIF(v.ventas_90d_usd, 0) * 90 AS DECIMAL(9,1)) AS dso_dias
FROM cierres c
JOIN cartera ca ON ca.cierre = c.cierre
CROSS APPLY (SELECT SUM(f.monto_usd) AS ventas_90d_usd FROM dw.fact_facturas f
             WHERE f.tipo_factura = 'AR'
               AND f.fecha_emision_key > CONVERT(INT, CONVERT(CHAR(8), DATEADD(DAY, -90, c.cierre), 112))
               AND f.fecha_emision_key <= c.cierre_key) v;
GO

SELECT name AS vista_rpt FROM sys.views WHERE schema_id = SCHEMA_ID(N'rpt') ORDER BY name;
GO
