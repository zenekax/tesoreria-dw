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

   Para cada cierre, CROSS APPLY calcula la cartera "a esa fecha" (lo facturado hasta ese
   día menos lo cobrado hasta ese día). Saldos en USD al TC de emisión (para comparar meses
   sin el efecto de la devaluación; el aging de 02_aging_cobranzas.sql revalúa al cierre).
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
)
SELECT c.nro, c.cierre, cartera.facturas_abiertas,
       CAST(cartera.cartera_usd AS DECIMAL(19,2)) AS cartera_usd,
       CAST(cartera.vencida_30_usd AS DECIMAL(19,2)) AS vencida_30_usd,
       CAST(100.0 * cartera.vencida_30_usd / NULLIF(cartera.cartera_usd, 0) AS DECIMAL(5,2)) AS pct_vencida_30,
       ventas.ventas_90d_usd,
       CAST(cartera.cartera_usd / NULLIF(ventas.ventas_90d_usd, 0) * 90 AS DECIMAL(9,1)) AS dso_dias,
       CAST(cartera.cartera_usd - LAG(cartera.cartera_usd) OVER (ORDER BY c.cierre) AS DECIMAL(19,2)) AS variacion_cartera_usd
FROM cierres_key c
CROSS APPLY (
    SELECT COUNT(*) AS facturas_abiertas, ISNULL(SUM(a.saldo_usd), 0) AS cartera_usd,
           ISNULL(SUM(IIF(a.dias_vencido > 30, a.saldo_usd, 0)), 0) AS vencida_30_usd
    FROM (
        SELECT f.monto_usd * (f.monto - ISNULL(cb.cobrado, 0)) / f.monto AS saldo_usd,
               DATEDIFF(DAY, fv.fecha, c.cierre) AS dias_vencido
        FROM dw.fact_facturas f
        JOIN dw.dim_fecha fv ON fv.fecha_key = f.fecha_vencimiento_key
        OUTER APPLY (SELECT SUM(x.monto) AS cobrado FROM dw.fact_cobranzas x
                     WHERE x.factura_id = f.factura_id AND x.fecha_cobranza_key <= c.cierre_key) cb
        WHERE f.tipo_factura = 'AR' AND f.fecha_emision_key <= c.cierre_key
          AND f.monto - ISNULL(cb.cobrado, 0) > 0
    ) a
) cartera
CROSS APPLY (
    SELECT SUM(f.monto_usd) AS ventas_90d_usd
    FROM dw.fact_facturas f
    JOIN dw.dim_fecha fe ON fe.fecha_key = f.fecha_emision_key
    WHERE f.tipo_factura = 'AR' AND fe.fecha > DATEADD(DAY, -90, c.cierre) AND fe.fecha <= c.cierre
) ventas
ORDER BY c.cierre
OPTION (MAXRECURSION 36);
GO
