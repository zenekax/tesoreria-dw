/* =============================================================================
   Q1 — Flujo de caja diario por moneda con saldo acumulado (de 06_queries/03).

   Por qué es lenta: agrega TODOS los movimientos bancarios (cientos de miles de filas)
   por moneda y día. Sin índice adecuado, SQL Server lee la tabla entera fila por fila
   (Clustered Index Scan sobre la PK) aunque solo use 3 columnas de las 13.

   Índice: COLUMNSTORE no agrupado sobre las columnas que usan los reportes.
   Analogía: el rowstore es un fichero de comprobantes (cada ficha con todos los datos);
   el columnstore es una planilla por columna (todas las fechas juntas, todos los montos
   juntos), comprimida. Para "sumar montos por fecha" alcanza con leer dos columnas, y
   además se procesa en BATCH MODE (de a ~900 filas por operación, no de a una).
   Ver sql/02_dw/04_indices.sql y sql/07_performance/resultados.md.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO
SET STATISTICS IO, TIME ON;
GO
WITH apertura AS (
    SELECT s.moneda_key, SUM(s.saldo_inicial) AS saldo_inicial
    FROM dw.fact_saldo_bancario_mensual s
    WHERE s.fecha_cierre_key = (SELECT MIN(fecha_cierre_key) FROM dw.fact_saldo_bancario_mensual)
    GROUP BY s.moneda_key
), movimientos AS (
    SELECT m.moneda_key, m.fecha_imputacion_key AS fecha_key,
           SUM(IIF(m.monto > 0, m.monto, 0)) AS ingresos, SUM(IIF(m.monto < 0, m.monto, 0)) AS egresos
    FROM dw.fact_movimientos_bancarios m
    GROUP BY m.moneda_key, m.fecha_imputacion_key
)
SELECT d.fecha, mo.codigo_iso AS moneda, ISNULL(mv.ingresos, 0) AS ingresos, ISNULL(mv.egresos, 0) AS egresos,
       a.saldo_inicial + SUM(ISNULL(mv.ingresos, 0) + ISNULL(mv.egresos, 0))
           OVER (PARTITION BY mo.codigo_iso ORDER BY d.fecha ROWS UNBOUNDED PRECEDING) AS saldo_cierre
FROM dw.dim_fecha d
CROSS JOIN apertura a
JOIN dw.dim_moneda mo ON mo.moneda_key = a.moneda_key
LEFT JOIN movimientos mv ON mv.moneda_key = a.moneda_key AND mv.fecha_key = d.fecha_key
WHERE d.fecha BETWEEN '2025-11-01' AND '2026-10-31'
ORDER BY moneda, d.fecha;
GO
SET STATISTICS IO, TIME OFF;
GO
