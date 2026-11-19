/* =============================================================================
   Q2 — Evolución mensual de la cartera a cobrar (de 06_queries/07, CTE recursiva).

   Por qué es lenta: para cada uno de los 12 cierres, para cada factura de cliente emitida
   hasta ese cierre, suma sus cobranzas hasta ese cierre. Sin índice por factura_id en
   fact_cobranzas, cada "¿cuánto se cobró de esta factura?" recorre todas las cobranzas;
   y para elegir las facturas AR recorre también las AP (la mitad de la tabla no sirve).

   Índices:
     - fact_cobranzas (factura_id, fecha_cobranza_key) INCLUDE (monto): NONCLUSTERED con
       INCLUDE -> busca directo las cobranzas de una factura y tiene el monto "a mano"
       (índice CUBRIENTE: no necesita volver a la tabla, sin Key Lookup).
     - fact_facturas (fecha_emision_key) INCLUDE (...) WHERE tipo_factura = 'AR':
       FILTRADO -> solo contiene las facturas de clientes: más chico y más rápido.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO
SET STATISTICS IO, TIME ON;
GO
WITH cierres AS (
    SELECT EOMONTH(CAST('2025-11-01' AS DATE)) AS cierre, 1 AS nro
    UNION ALL
    SELECT EOMONTH(DATEADD(MONTH, 1, cierre)), nro + 1 FROM cierres WHERE cierre < '2026-10-31'
), cierres_key AS (
    SELECT cierre, nro, CONVERT(INT, CONVERT(CHAR(8), cierre, 112)) AS cierre_key FROM cierres
)
SELECT c.cierre, cartera.facturas_abiertas, CAST(cartera.cartera_usd AS DECIMAL(19,2)) AS cartera_usd,
       CAST(cartera.vencida_30_usd AS DECIMAL(19,2)) AS vencida_30_usd
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
ORDER BY c.cierre
OPTION (MAXRECURSION 36);
GO
SET STATISTICS IO, TIME OFF;
GO
