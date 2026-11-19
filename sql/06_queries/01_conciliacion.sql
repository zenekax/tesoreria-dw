/* =============================================================================
   01_conciliacion.sql — Estado de la conciliación bancaria.

   PREGUNTA DE NEGOCIO: ¿cuánto está conciliado, qué falta y dónde? Es la planilla de
   conciliación por cuenta: partidas conciliadas, con diferencia (comisiones que el banco
   descontó), pendientes en banco (pagué y el banco no lo muestra: en tránsito o
   rechazado) y pendientes en libros (el banco movió plata que nadie registró).

   La conciliación la hace dw.usp_conciliar (sql/03_etl/06_usp_conciliar.sql) dentro del
   ETL; estas consultas leen el resultado en dw.fact_conciliacion.
   Técnicas: CTE, agregación condicional, SUM() OVER para % del total, ROW_NUMBER.
   Ejecutar: scripts/run_sql.sh sql/06_queries/01_conciliacion.sql
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* 1. Resumen por cuenta: cantidad y monto por estado, y % conciliado. */
WITH partidas AS (
    SELECT c.alias AS cuenta, c.moneda_iso AS moneda, k.estado,
           COALESCE(k.monto_banco, k.monto_libro) AS monto
    FROM dw.fact_conciliacion k
    JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
)
SELECT cuenta, moneda,
       COUNT(*)                                                         AS partidas,
       SUM(IIF(estado = 'CONCILIADA', 1, 0))                            AS conciliadas,
       SUM(IIF(estado = 'CONCILIADA_CON_DIFERENCIA', 1, 0))             AS con_diferencia,
       SUM(IIF(estado = 'PENDIENTE_EN_BANCO', 1, 0))                    AS pend_en_banco,
       SUM(IIF(estado = 'PENDIENTE_EN_LIBROS', 1, 0))                   AS pend_en_libros,
       SUM(IIF(estado LIKE 'PENDIENTE%', ABS(monto), 0))                AS monto_pendiente,
       CAST(100.0 * SUM(IIF(estado LIKE 'CONCILIADA%', 1, 0)) / COUNT(*) AS DECIMAL(5,2)) AS pct_conciliado
FROM partidas
GROUP BY cuenta, moneda
ORDER BY moneda, cuenta;

/* 2. Calidad del matching: cómo se concilió y cuánto tardó el banco (días hábiles). */
SELECT metodo_match, estado, COUNT(*) AS partidas,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_del_total,
       AVG(CAST(dias_habiles_desfase AS DECIMAL(5,2))) AS desfase_promedio_dias_habiles,
       MAX(dias_habiles_desfase) AS desfase_maximo,
       SUM(diferencia) AS diferencia_total
FROM dw.fact_conciliacion
WHERE estado LIKE 'CONCILIADA%'
GROUP BY metodo_match, estado
ORDER BY metodo_match, estado;

/* 3. Partidas pendientes para revisar, las más viejas primero (lo que un tesorero mira
      el lunes a la mañana). ROW_NUMBER numera dentro de cada cuenta. */
SELECT ROW_NUMBER() OVER (PARTITION BY c.alias ORDER BY COALESCE(fb.fecha, fl.fecha)) AS nro,
       c.alias AS cuenta, k.estado, k.origen,
       COALESCE(k.pago_id, k.cobranza_id, k.linea_extracto_id) AS partida,
       COALESCE(fl.fecha, fb.fecha) AS fecha,
       COALESCE(k.monto_libro, k.monto_banco) AS monto,
       c.moneda_iso AS moneda,
       DATEDIFF(DAY, COALESCE(fl.fecha, fb.fecha), '2026-10-31') AS dias_abierta,
       mv.descripcion AS descripcion_banco
FROM dw.fact_conciliacion k
JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
LEFT JOIN dw.dim_fecha fl ON fl.fecha_key = k.fecha_libro_key AND fl.fecha_key > 0
LEFT JOIN dw.dim_fecha fb ON fb.fecha_key = k.fecha_banco_key AND fb.fecha_key > 0
LEFT JOIN dw.fact_movimientos_bancarios mv ON mv.linea_extracto_id = k.linea_extracto_id
WHERE k.estado LIKE 'PENDIENTE%'
ORDER BY dias_abierta DESC, cuenta;
GO
