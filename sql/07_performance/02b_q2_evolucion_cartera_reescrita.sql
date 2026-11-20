/* =============================================================================
   Q2 reescrita — misma pregunta y mismo resultado que 02_q2_evolucion_cartera.sql.

   Problema de la original: le pregunta a fact_cobranzas "¿cuánto se cobró de ESTA factura
   hasta ESTE cierre?" una vez por factura y por cierre (subconsulta correlacionada con
   OUTER APPLY): 12 cierres x decenas de miles de facturas = cientos de miles de búsquedas.
   Con índice cada búsqueda es barata (Index Seek) pero son demasiadas: el índice solo, bajó
   las lecturas un 8%.

   Primer intento (descartado, ver resultados.md): unir cierres con cobranzas por
   "fecha <= cierre" en un solo paso. Peor: una unión por DESIGUALDAD sobre una tabla grande
   termina en un spool (tabla temporal interna) que se relee: 20 s de CPU.

   Esta versión usa solo IGUALDADES y una window function:
     1. cobrado por factura y MES (un GROUP BY, una pasada por las cobranzas);
     2. la grilla factura x cierre (cada factura AR, en cada cierre posterior a su emisión);
     3. SUM() OVER (PARTITION BY factura ORDER BY cierre) = lo cobrado HASTA cada cierre.
   Analogía Excel: en vez de un SUMAR.SI.CONJUNTO por celda, una tabla dinámica factura x mes
   con "total acumulado".
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
), cobrado_mes AS (    -- 1. cobrado por factura y mes
    SELECT x.factura_id, EOMONTH(fc.fecha) AS cierre, SUM(x.monto) AS cobrado_mes
    FROM dw.fact_cobranzas x
    JOIN dw.dim_fecha fc ON fc.fecha_key = x.fecha_cobranza_key
    GROUP BY x.factura_id, EOMONTH(fc.fecha)
), grilla AS (         -- 2. cada factura AR en cada cierre desde su emisión
    SELECT c.cierre, f.factura_id, f.monto, f.monto_usd, f.fecha_vencimiento_key
    FROM cierres_key c
    JOIN dw.fact_facturas f ON f.tipo_factura = 'AR' AND f.fecha_emision_key <= c.cierre_key
), acumulado AS (      -- 3. lo cobrado hasta cada cierre = suma acumulada de los meses
    SELECT g.*, SUM(ISNULL(cm.cobrado_mes, 0)) OVER (PARTITION BY g.factura_id ORDER BY g.cierre
                                                     ROWS UNBOUNDED PRECEDING) AS cobrado
    FROM grilla g
    LEFT JOIN cobrado_mes cm ON cm.factura_id = g.factura_id AND cm.cierre = g.cierre
), saldos AS (
    SELECT a.cierre, a.monto_usd * (a.monto - a.cobrado) / a.monto AS saldo_usd,
           DATEDIFF(DAY, fv.fecha, a.cierre) AS dias_vencido
    FROM acumulado a
    JOIN dw.dim_fecha fv ON fv.fecha_key = a.fecha_vencimiento_key
    WHERE a.monto - a.cobrado > 0
)
SELECT cierre, COUNT(*) AS facturas_abiertas, CAST(SUM(saldo_usd) AS DECIMAL(19,2)) AS cartera_usd,
       CAST(SUM(IIF(dias_vencido > 30, saldo_usd, 0)) AS DECIMAL(19,2)) AS vencida_30_usd
FROM saldos
GROUP BY cierre
ORDER BY cierre
-- MAXDOP 1: medido a escala 20, el plan en paralelo terminaba casi igual de rápido (0,69 s vs 0,71 s)
-- pero usaba 5 veces más CPU (ordenar la window function en varios hilos). En un servidor con
-- varios usuarios, esa CPU se la saca a otras consultas: no vale la pena.
OPTION (MAXRECURSION 36, MAXDOP 1);
GO
SET STATISTICS IO, TIME OFF;
GO
