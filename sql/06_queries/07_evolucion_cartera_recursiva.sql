/* =============================================================================
   07_evolucion_cartera_recursiva.sql — Evolución mensual de la cartera a cobrar y del DSO.

   PREGUNTA DE NEGOCIO: mes a mes, ¿cuánto nos debían los clientes al cierre, cuánto de eso
   estaba vencido hace más de 30 días, y cuántos días de ventas tardamos en cobrar (DSO)?
   Si el DSO sube, los clientes pagan más tarde y tesorería necesita más capital de trabajo.

   DSO (Days Sales Outstanding) = cartera al cierre / ventas de los últimos 90 días x 90.

   CTE RECURSIVA: genera la serie de cierres de mes (anchor: el primer cierre; parte
   recursiva: el cierre siguiente, hasta llegar al último). Es la técnica para "iterar
   períodos" en SQL sin un cursor. En este DW también se podría filtrar dim_fecha por
   es_fin_de_mes = 1; la recursiva es la opción cuando no hay tabla calendario (o para
   series que no son de fechas). MAXRECURSION limita las vueltas: un error en la condición
   de corte no se convierte en un bucle infinito.

   Para cada cierre, la cartera "a esa fecha" = lo facturado hasta ese día menos lo cobrado
   hasta ese día. Lo cobrado hasta cada cierre sale de una SUMA ACUMULADA por factura
   (SUM() OVER ... ORDER BY cierre), no de una subconsulta por factura y por cierre: la Fase 7
   midió que la subconsulta correlacionada hacía 1,2 millones de lecturas a escala 20 y esta
   forma, menos de 5 mil (ver sql/07_performance/resultados.md).
   Saldos en USD al TC de emisión (para comparar meses sin el efecto de la devaluación; el
   aging de 02_aging_cobranzas.sql revalúa al cierre).
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

WITH cierres AS (
    SELECT EOMONTH(CAST('2025-11-01' AS DATE)) AS cierre, 1 AS nro                 -- anchor
    UNION ALL
    SELECT EOMONTH(DATEADD(MONTH, 1, cierre)), nro + 1                              -- parte recursiva
    FROM cierres
    WHERE cierre < '2026-10-31'                                                     -- condición de corte
), cierres_key AS (
    SELECT cierre, nro, CONVERT(INT, CONVERT(CHAR(8), cierre, 112)) AS cierre_key FROM cierres
), cobrado_mes AS (      -- cobrado por factura y mes (una pasada por las cobranzas)
    SELECT x.factura_id, EOMONTH(fc.fecha) AS cierre, SUM(x.monto) AS cobrado_mes
    FROM dw.fact_cobranzas x
    JOIN dw.dim_fecha fc ON fc.fecha_key = x.fecha_cobranza_key
    GROUP BY x.factura_id, EOMONTH(fc.fecha)
), acumulado AS (        -- cada factura AR en cada cierre desde su emisión, con lo cobrado HASTA ese cierre
    SELECT c.cierre, f.monto, f.monto_usd, f.fecha_vencimiento_key,
           SUM(ISNULL(cm.cobrado_mes, 0)) OVER (PARTITION BY f.factura_id ORDER BY c.cierre
                                                ROWS UNBOUNDED PRECEDING) AS cobrado
    FROM cierres_key c
    JOIN dw.fact_facturas f ON f.tipo_factura = 'AR' AND f.fecha_emision_key <= c.cierre_key
    LEFT JOIN cobrado_mes cm ON cm.factura_id = f.factura_id AND cm.cierre = c.cierre
), cartera AS (
    SELECT a.cierre, COUNT(*) AS facturas_abiertas,
           SUM(a.monto_usd * (a.monto - a.cobrado) / a.monto) AS cartera_usd,
           SUM(IIF(DATEDIFF(DAY, fv.fecha, a.cierre) > 30, a.monto_usd * (a.monto - a.cobrado) / a.monto, 0)) AS vencida_30_usd
    FROM acumulado a
    JOIN dw.dim_fecha fv ON fv.fecha_key = a.fecha_vencimiento_key
    WHERE a.monto - a.cobrado > 0
    GROUP BY a.cierre
)
SELECT c.nro, c.cierre, ca.facturas_abiertas,
       CAST(ca.cartera_usd AS DECIMAL(19,2)) AS cartera_usd,
       CAST(ca.vencida_30_usd AS DECIMAL(19,2)) AS vencida_30_usd,
       CAST(100.0 * ca.vencida_30_usd / NULLIF(ca.cartera_usd, 0) AS DECIMAL(5,2)) AS pct_vencida_30,
       ventas.ventas_90d_usd,
       CAST(ca.cartera_usd / NULLIF(ventas.ventas_90d_usd, 0) * 90 AS DECIMAL(9,1)) AS dso_dias,
       CAST(ca.cartera_usd - LAG(ca.cartera_usd) OVER (ORDER BY c.cierre) AS DECIMAL(19,2)) AS variacion_cartera_usd
FROM cierres_key c
JOIN cartera ca ON ca.cierre = c.cierre
CROSS APPLY (
    SELECT SUM(f.monto_usd) AS ventas_90d_usd
    FROM dw.fact_facturas f
    WHERE f.tipo_factura = 'AR'
      AND f.fecha_emision_key > CONVERT(INT, CONVERT(CHAR(8), DATEADD(DAY, -90, c.cierre), 112))
      AND f.fecha_emision_key <= c.cierre_key
) ventas
ORDER BY c.cierre
-- MAXDOP 1: medido a escala 20, el plan en paralelo terminaba casi igual de rápido (0,69 s vs 0,71 s)
-- pero usaba 5 veces más CPU (ordenar la window function en varios hilos). En un servidor con
-- varios usuarios, esa CPU se la saca a otras consultas: no vale la pena.
OPTION (MAXRECURSION 36, MAXDOP 1);
GO
