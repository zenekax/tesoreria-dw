/* =============================================================================
   04_top_contrapartes.sql — Ranking y concentración de contrapartes.

   PREGUNTA DE NEGOCIO: ¿a quién le pagamos más y de quién cobramos más? ¿Qué tan
   concentrado está el volumen (riesgo de depender de pocos clientes o corresponsales)?

   Volumen en USD a TC de la operación. Se agrupa por contraparte_id (la clave natural),
   no por la clave surrogate: una contraparte con dos versiones SCD2 sigue siendo una.
   Nombre: el de la versión vigente.

   Técnicas: RANK, NTILE(4) (cuartiles), SUM() OVER para participación y Pareto
   acumulado, CROSS APPLY TOP 3 (últimos movimientos de cada una).
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

WITH volumen AS (
    SELECT cp.contraparte_id, 'PAGOS' AS flujo, p.monto_usd FROM dw.fact_pagos p
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = p.contraparte_key WHERE cp.contraparte_key > 0
    UNION ALL
    SELECT cp.contraparte_id, 'COBRANZAS', c.monto_usd FROM dw.fact_cobranzas c
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = c.contraparte_key WHERE cp.contraparte_key > 0
), totales AS (
    SELECT v.flujo, v.contraparte_id, actual.razon_social, actual.tipo_contraparte, actual.pais,
           COUNT(*) AS operaciones, SUM(v.monto_usd) AS total_usd
    FROM volumen v
    JOIN dw.dim_contraparte actual ON actual.contraparte_id = v.contraparte_id AND actual.es_vigente = 1
    GROUP BY v.flujo, v.contraparte_id, actual.razon_social, actual.tipo_contraparte, actual.pais
), ranking AS (
    SELECT *,
           RANK() OVER (PARTITION BY flujo ORDER BY total_usd DESC) AS puesto,
           NTILE(4) OVER (PARTITION BY flujo ORDER BY total_usd DESC) AS cuartil,
           CAST(100.0 * total_usd / SUM(total_usd) OVER (PARTITION BY flujo) AS DECIMAL(5,2)) AS pct_del_total,
           CAST(100.0 * SUM(total_usd) OVER (PARTITION BY flujo ORDER BY total_usd DESC ROWS UNBOUNDED PRECEDING)
                / SUM(total_usd) OVER (PARTITION BY flujo) AS DECIMAL(5,2)) AS pct_acumulado
    FROM totales
)
SELECT * INTO #ranking FROM ranking;

/* 1. Top 10 de cada flujo, con participación y Pareto acumulado. */
SELECT flujo, puesto, contraparte_id, razon_social, tipo_contraparte, pais, operaciones, total_usd,
       pct_del_total, pct_acumulado, cuartil
FROM #ranking
WHERE puesto <= 10
ORDER BY flujo, puesto;

/* 2. Concentración por cuartil: si el cuartil 1 (el 25% más grande) tiene el 80% del
      volumen, hay riesgo de concentración. */
SELECT flujo, cuartil, COUNT(*) AS contrapartes, SUM(total_usd) AS total_usd,
       CAST(100.0 * SUM(total_usd) / SUM(SUM(total_usd)) OVER (PARTITION BY flujo) AS DECIMAL(5,2)) AS pct
FROM #ranking
GROUP BY flujo, cuartil
ORDER BY flujo, cuartil;

/* 3. Para el top 5 de pagos: sus 3 últimos pagos (CROSS APPLY = "para cada fila de la
      izquierda, ejecutá esta subconsulta", como un BUSCARV que devuelve varias filas). */
SELECT r.puesto, r.razon_social, ult.pago_id, ult.fecha, ult.monto, ult.moneda, ult.monto_usd
FROM #ranking r
CROSS APPLY (SELECT TOP (3) p.pago_id, f.fecha, p.monto, m.codigo_iso AS moneda, p.monto_usd
             FROM dw.fact_pagos p
             JOIN dw.dim_contraparte cp ON cp.contraparte_key = p.contraparte_key
             JOIN dw.dim_fecha f ON f.fecha_key = p.fecha_pago_key
             JOIN dw.dim_moneda m ON m.moneda_key = p.moneda_key
             WHERE cp.contraparte_id = r.contraparte_id
             ORDER BY p.fecha_pago_key DESC, p.pago_id DESC) ult
WHERE r.flujo = 'PAGOS' AND r.puesto <= 5
ORDER BY r.puesto, ult.fecha DESC;

DROP TABLE #ranking;
GO
