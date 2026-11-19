/* =============================================================================
   05_anomalias.sql — Detección simple de anomalías en pagos y cobranzas.

   PREGUNTA DE NEGOCIO: ¿hay pagos que "no se parecen" a los habituales y que conviene
   revisar antes de que se vuelvan un problema? No son errores de datos (esos los ataja la
   Fase 5): son datos válidos pero sospechosos. Es el control que haría un auditor.

   1. PAGO ATÍPICO: el pago es más de 5 veces la MEDIANA de los pagos a esa contraparte.
      Mediana y no promedio: un solo pago gigante infla el promedio y se "esconde" a sí
      mismo; la mediana no se mueve. Mínimo 5 pagos para tener una base.
   2. POSIBLE DOBLE PAGO: misma contraparte, misma moneda y mismo importe dentro de 3 días
      HÁBILES (LAG mira el pago anterior de ese mismo grupo; los días hábiles se cuentan con
      el calendario: un viernes y el martes siguiente están a 2 días hábiles, no a 4).
   3. FACTURA PAGADA DE MÁS: la suma de pagos supera el monto de la factura.
   4. CLIENTE QUE SE ATRASA CADA VEZ MÁS: el atraso promedio del último trimestre es más
      del doble que el de los trimestres anteriores.

   Técnicas: PERCENTILE_CONT como window function, LAG, COUNT() OVER, CTE, agregaciones.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* 1. Pagos atípicos (más de 5 veces la mediana de la contraparte). */
WITH pagos AS (
    SELECT p.pago_id, p.factura_id, cp.contraparte_id, cp.razon_social, m.codigo_iso AS moneda, f.fecha,
           p.monto, p.monto_usd,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.monto_usd)
               OVER (PARTITION BY cp.contraparte_id) AS mediana_usd,
           COUNT(*) OVER (PARTITION BY cp.contraparte_id) AS pagos_de_la_contraparte
    FROM dw.fact_pagos p
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = p.contraparte_key
    JOIN dw.dim_moneda m ON m.moneda_key = p.moneda_key
    JOIN dw.dim_fecha f ON f.fecha_key = p.fecha_pago_key
    WHERE cp.contraparte_key > 0
)
SELECT 'PAGO_ATIPICO' AS anomalia, pago_id, factura_id, contraparte_id, razon_social, fecha, moneda, monto,
       monto_usd, CAST(mediana_usd AS DECIMAL(19,2)) AS mediana_usd,
       CAST(monto_usd / mediana_usd AS DECIMAL(9,1)) AS veces_la_mediana
FROM pagos
WHERE pagos_de_la_contraparte >= 5 AND monto_usd > 5 * mediana_usd
ORDER BY veces_la_mediana DESC;

/* 2. Posibles dobles pagos (mismo proveedor, moneda e importe en 3 días hábiles). */
WITH pagos AS (
    SELECT p.pago_id, p.factura_id, cp.contraparte_id, cp.razon_social, p.moneda_key, f.fecha, p.monto,
           LAG(p.pago_id) OVER (PARTITION BY cp.contraparte_id, p.moneda_key, p.monto ORDER BY f.fecha, p.pago_id) AS pago_anterior,
           LAG(f.fecha)   OVER (PARTITION BY cp.contraparte_id, p.moneda_key, p.monto ORDER BY f.fecha, p.pago_id) AS fecha_anterior,
           LAG(p.factura_id) OVER (PARTITION BY cp.contraparte_id, p.moneda_key, p.monto ORDER BY f.fecha, p.pago_id) AS factura_anterior
    FROM dw.fact_pagos p
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = p.contraparte_key
    JOIN dw.dim_fecha f ON f.fecha_key = p.fecha_pago_key
    WHERE cp.contraparte_key > 0
)
SELECT 'POSIBLE_DOBLE_PAGO' AS anomalia, pago_anterior AS primer_pago, pago_id AS segundo_pago, contraparte_id,
       razon_social, fecha_anterior, fecha, monto, hab.dias_habiles AS dias_habiles_entre_pagos,
       IIF(factura_anterior = factura_id, N'misma factura', N'otra factura') AS factura
FROM pagos
CROSS APPLY (SELECT COUNT(*) AS dias_habiles FROM dw.dim_fecha d
             WHERE d.fecha > pagos.fecha_anterior AND d.fecha <= pagos.fecha AND d.es_habil = 1) hab
WHERE pago_anterior IS NOT NULL AND hab.dias_habiles <= 3
ORDER BY fecha;

/* 3. Facturas pagadas de más (suma de pagos > monto facturado). */
SELECT 'FACTURA_PAGADA_DE_MAS' AS anomalia, f.factura_id, cp.razon_social, f.monto AS facturado,
       SUM(p.monto) AS pagado, SUM(p.monto) - f.monto AS exceso, COUNT(*) AS pagos
FROM dw.fact_facturas f
JOIN dw.fact_pagos p ON p.factura_id = f.factura_id
JOIN dw.dim_contraparte cp ON cp.contraparte_key = f.contraparte_key
GROUP BY f.factura_id, cp.razon_social, f.monto
HAVING SUM(p.monto) > f.monto
ORDER BY exceso DESC;

/* 4. Clientes cuyo atraso promedio del último trimestre duplica el de los anteriores. */
WITH atrasos AS (
    SELECT cp.contraparte_id, cp.razon_social, f.fecha, c.dias_atraso,
           IIF(f.fecha > DATEADD(MONTH, -3, '2026-10-31'), 'ultimo_trimestre', 'anterior') AS periodo
    FROM dw.fact_cobranzas c
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = c.contraparte_key
    JOIN dw.dim_fecha f ON f.fecha_key = c.fecha_cobranza_key
    WHERE c.dias_atraso IS NOT NULL AND cp.contraparte_key > 0
), resumen AS (
    SELECT contraparte_id, MAX(razon_social) AS razon_social,
           AVG(IIF(periodo = 'anterior', CAST(dias_atraso AS DECIMAL(9,2)), NULL)) AS atraso_antes,
           AVG(IIF(periodo = 'ultimo_trimestre', CAST(dias_atraso AS DECIMAL(9,2)), NULL)) AS atraso_ultimo_trim,
           SUM(IIF(periodo = 'ultimo_trimestre', 1, 0)) AS cobranzas_ultimo_trim
    FROM atrasos GROUP BY contraparte_id
)
SELECT 'CLIENTE_EMPEORA' AS anomalia, contraparte_id, razon_social, atraso_antes, atraso_ultimo_trim,
       cobranzas_ultimo_trim
FROM resumen
WHERE cobranzas_ultimo_trim >= 3 AND atraso_antes > 5 AND atraso_ultimo_trim > 2 * atraso_antes
ORDER BY atraso_ultimo_trim DESC;
GO
