/* =============================================================================
   Q3 — Partidas pendientes de conciliación, las más viejas primero (de 06_queries/01).

   Por qué es lenta: es la consulta que el tesorero corre todos los días y busca unas
   pocas decenas de partidas pendientes entre cientos de miles de partidas (casi todas
   ya conciliadas). Sin índice, lee la tabla entera para quedarse con el 0,1%.

   Índice: FILTRADO, solo con las partidas pendientes (WHERE estado IN (...)). Ocupa
   casi nada porque la gran mayoría está conciliada, y se mantiene solo cuando una
   partida entra o sale de "pendiente".

   OJO, detalle clave: el optimizador solo usa un índice filtrado si puede PROBAR que la
   condición de la consulta está contenida en el filtro del índice. La versión original
   (06_queries/01) filtra con estado LIKE 'PENDIENTE%' y el índice usa estado IN (...): con
   LIKE no lo usa. Por eso esta versión escribe la condición igual que el índice.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO
SET STATISTICS IO, TIME ON;
GO
SELECT c.alias AS cuenta, k.estado, k.origen,
       COALESCE(k.pago_id, k.cobranza_id, k.linea_extracto_id) AS partida,
       COALESCE(fl.fecha, fb.fecha) AS fecha,
       COALESCE(k.monto_libro, k.monto_banco) AS monto,
       DATEDIFF(DAY, COALESCE(fl.fecha, fb.fecha), '2026-10-31') AS dias_abierta,
       mv.descripcion AS descripcion_banco
FROM dw.fact_conciliacion k
JOIN dw.dim_banco_cuenta c ON c.banco_cuenta_key = k.banco_cuenta_key
LEFT JOIN dw.dim_fecha fl ON fl.fecha_key = k.fecha_libro_key AND fl.fecha_key > 0
LEFT JOIN dw.dim_fecha fb ON fb.fecha_key = k.fecha_banco_key AND fb.fecha_key > 0
LEFT JOIN dw.fact_movimientos_bancarios mv ON mv.linea_extracto_id = k.linea_extracto_id
WHERE k.estado IN ('PENDIENTE_EN_BANCO', 'PENDIENTE_EN_LIBROS')
ORDER BY dias_abierta DESC, cuenta;
GO
SET STATISTICS IO, TIME OFF;
GO
