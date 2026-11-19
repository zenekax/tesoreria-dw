/* =============================================================================
   02_aging_cobranzas.sql — Antigüedad de saldos de clientes (aging de cuentas a cobrar).

   PREGUNTA DE NEGOCIO: al cierre, ¿cuánto nos deben los clientes y hace cuánto venció?
   Es el FBL5N con "partidas abiertas a fecha" agrupado por tramos de vencimiento. Sirve
   para priorizar la gestión de cobranza y estimar previsiones por incobrabilidad.

   Saldo abierto de una factura = monto - cobranzas recibidas hasta el corte.
   Tramos por días desde el vencimiento: no vencido, 1-30, 31-60, 61-90, más de 90.
   Revaluación: el saldo en moneda de origen se pasa a USD al TC DEL CIERRE (no al de la
   emisión), que es lo que vale hoy esa deuda. Para eso está fact_tipo_cambio.

   Técnicas: CTE encadenadas, CROSS APPLY (último TC a la fecha), PIVOT, SUM() OVER.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

DECLARE @corte DATE = '2026-10-31';
DECLARE @corte_key INT = CONVERT(INT, CONVERT(CHAR(8), @corte, 112));

WITH cobrado AS (       -- cobranzas recibidas hasta el corte, por factura
    SELECT c.factura_id, SUM(c.monto) AS cobrado
    FROM dw.fact_cobranzas c
    WHERE c.fecha_cobranza_key <= @corte_key
    GROUP BY c.factura_id
), abiertas AS (        -- facturas AR emitidas hasta el corte con saldo pendiente
    SELECT f.factura_id, cp.contraparte_id, cp.razon_social, m.codigo_iso AS moneda, f.moneda_key,
           fv.fecha AS vencimiento, f.monto - ISNULL(cb.cobrado, 0) AS saldo,
           DATEDIFF(DAY, fv.fecha, @corte) AS dias_vencido
    FROM dw.fact_facturas f
    JOIN dw.dim_fecha fv ON fv.fecha_key = f.fecha_vencimiento_key
    JOIN dw.dim_moneda m ON m.moneda_key = f.moneda_key
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = f.contraparte_key
    LEFT JOIN cobrado cb ON cb.factura_id = f.factura_id
    WHERE f.tipo_factura = 'AR' AND f.fecha_emision_key <= @corte_key
      AND f.monto - ISNULL(cb.cobrado, 0) > 0
), tramos AS (
    SELECT a.*,
           -- El número adelante ordena los tramos (si no, '+90' queda primero por orden alfabético).
           CASE WHEN a.dias_vencido <= 0 THEN '0 no vencido'
                WHEN a.dias_vencido <= 30 THEN '1 de 1 a 30'
                WHEN a.dias_vencido <= 60 THEN '2 de 31 a 60'
                WHEN a.dias_vencido <= 90 THEN '3 de 61 a 90'
                ELSE '4 mas de 90' END AS tramo,
           CAST(a.saldo / tc.tipo_cambio_por_usd AS DECIMAL(19,2)) AS saldo_usd_cierre
    FROM abiertas a
    CROSS APPLY (SELECT TOP (1) t.tipo_cambio_por_usd FROM dw.fact_tipo_cambio t
                 WHERE t.moneda_key = a.moneda_key AND t.fecha_key <= @corte_key
                 ORDER BY t.fecha_key DESC) tc
)
SELECT * INTO #aging FROM tramos;

/* 1. Resumen por tramo (USD al cierre), con % del total y acumulado. */
SELECT tramo, COUNT(*) AS facturas, SUM(saldo_usd_cierre) AS saldo_usd,
       CAST(100.0 * SUM(saldo_usd_cierre) / SUM(SUM(saldo_usd_cierre)) OVER () AS DECIMAL(5,2)) AS pct,
       SUM(SUM(saldo_usd_cierre)) OVER (ORDER BY tramo ROWS UNBOUNDED PRECEDING) AS saldo_acumulado_usd
FROM #aging
GROUP BY tramo
ORDER BY tramo;

/* 2. Aging por cliente: un PIVOT pone los tramos como columnas (como la vista clásica de
      antigüedad). Top 15 clientes por deuda. */
SELECT TOP (15) razon_social AS cliente,
       ISNULL([0 no vencido], 0) AS no_vencido, ISNULL([1 de 1 a 30], 0) AS d1_30,
       ISNULL([2 de 31 a 60], 0) AS d31_60, ISNULL([3 de 61 a 90], 0) AS d61_90, ISNULL([4 mas de 90], 0) AS mas_90,
       ISNULL([0 no vencido], 0) + ISNULL([1 de 1 a 30], 0) + ISNULL([2 de 31 a 60], 0) + ISNULL([3 de 61 a 90], 0)
           + ISNULL([4 mas de 90], 0) AS total_usd
FROM (SELECT razon_social, tramo, saldo_usd_cierre FROM #aging) AS fuente
PIVOT (SUM(saldo_usd_cierre) FOR tramo IN ([0 no vencido], [1 de 1 a 30], [2 de 31 a 60], [3 de 61 a 90], [4 mas de 90])) AS p
ORDER BY total_usd DESC;

/* 3. Por moneda de origen: cuánto de la cartera está en cada moneda (riesgo cambiario). */
SELECT moneda, COUNT(*) AS facturas, SUM(saldo) AS saldo_moneda_origen, SUM(saldo_usd_cierre) AS saldo_usd,
       SUM(IIF(dias_vencido > 0, saldo_usd_cierre, 0)) AS vencido_usd
FROM #aging
GROUP BY moneda
ORDER BY saldo_usd DESC;

DROP TABLE #aging;
GO
