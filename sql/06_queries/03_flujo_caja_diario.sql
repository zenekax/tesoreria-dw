/* =============================================================================
   03_flujo_caja_diario.sql — Flujo de caja diario por moneda con saldo acumulado.

   PREGUNTA DE NEGOCIO: ¿cuánta plata entró y salió cada día, en cada moneda, y con qué
   saldo cerramos el día? Es la posición de caja diaria que arma tesorería todas las
   mañanas, pero con la historia completa.

   Saldo del día = saldo inicial del período (lo informa el banco: fact_saldo_bancario_mensual)
                 + suma acumulada de los movimientos hasta ese día.
   Se usa el calendario (dim_fecha) como base para que aparezcan TODOS los días, también
   los que no tuvieron movimientos (si no, el gráfico "salta" fines de semana y feriados).

   Técnicas: CROSS JOIN calendario x monedas, LEFT JOIN, SUM() OVER (ORDER BY ... ROWS
   UNBOUNDED PRECEDING) para el acumulado, LAG para la variación diaria, AVG() OVER con
   ventana móvil de 5 días.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

DECLARE @desde DATE = '2025-11-01', @hasta DATE = '2026-10-31';

WITH apertura AS (       -- saldo inicial del primer mes, sumado por moneda (todas las cuentas)
    SELECT s.moneda_key, SUM(s.saldo_inicial) AS saldo_inicial
    FROM dw.fact_saldo_bancario_mensual s
    WHERE s.fecha_cierre_key = (SELECT MIN(fecha_cierre_key) FROM dw.fact_saldo_bancario_mensual)
    GROUP BY s.moneda_key
), movimientos AS (      -- ingresos y egresos por día y moneda
    SELECT m.moneda_key, m.fecha_imputacion_key AS fecha_key,
           SUM(IIF(m.monto > 0, m.monto, 0)) AS ingresos,
           SUM(IIF(m.monto < 0, m.monto, 0)) AS egresos
    FROM dw.fact_movimientos_bancarios m
    GROUP BY m.moneda_key, m.fecha_imputacion_key
), diario AS (
    SELECT d.fecha, mo.codigo_iso AS moneda, d.es_habil,
           ISNULL(mv.ingresos, 0) AS ingresos, ISNULL(mv.egresos, 0) AS egresos,
           ISNULL(mv.ingresos, 0) + ISNULL(mv.egresos, 0) AS neto,
           a.saldo_inicial
             + SUM(ISNULL(mv.ingresos, 0) + ISNULL(mv.egresos, 0))
               OVER (PARTITION BY mo.codigo_iso ORDER BY d.fecha ROWS UNBOUNDED PRECEDING) AS saldo_cierre
    FROM dw.dim_fecha d
    CROSS JOIN apertura a
    JOIN dw.dim_moneda mo ON mo.moneda_key = a.moneda_key
    LEFT JOIN movimientos mv ON mv.moneda_key = a.moneda_key AND mv.fecha_key = d.fecha_key
    WHERE d.fecha BETWEEN @desde AND @hasta
)
SELECT fecha, moneda, ingresos, egresos, neto, saldo_cierre,
       saldo_cierre - LAG(saldo_cierre) OVER (PARTITION BY moneda ORDER BY fecha) AS variacion_vs_dia_anterior,
       -- promedio móvil del neto de los días hábiles de la última semana (7 días corridos):
       -- suaviza el ruido diario (los fines de semana no entran al promedio porque el IIF da NULL)
       AVG(IIF(es_habil = 1, neto, NULL)) OVER (PARTITION BY moneda ORDER BY fecha
                                                ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS neto_promedio_movil
FROM diario
ORDER BY moneda, fecha;

/* Resumen mensual por moneda (lo que se presenta en el comité de tesorería). */
WITH mensual AS (
    SELECT mo.codigo_iso AS moneda, d.anio_mes,
           SUM(IIF(m.monto > 0, m.monto, 0)) AS ingresos, SUM(IIF(m.monto < 0, m.monto, 0)) AS egresos
    FROM dw.fact_movimientos_bancarios m
    JOIN dw.dim_fecha d ON d.fecha_key = m.fecha_imputacion_key
    JOIN dw.dim_moneda mo ON mo.moneda_key = m.moneda_key
    WHERE d.fecha BETWEEN @desde AND @hasta
    GROUP BY mo.codigo_iso, d.anio_mes
)
SELECT moneda, anio_mes, ingresos, egresos, ingresos + egresos AS neto,
       SUM(ingresos + egresos) OVER (PARTITION BY moneda ORDER BY anio_mes ROWS UNBOUNDED PRECEDING) AS neto_acumulado
FROM mensual
ORDER BY moneda, anio_mes;
GO
