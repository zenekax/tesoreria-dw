/* =============================================================================
   04_indices.sql — Índices para las consultas de análisis (resultado de la Fase 7).

   Cada índice está justificado con evidencia (planes de ejecución y STATISTICS IO/TIME
   antes/después) en sql/07_performance/resultados.md. Un índice no es gratis: ocupa
   espacio y hace más lentos los INSERT/UPDATE del ETL; por eso solo hay los que una
   consulta real necesita.
   Idempotente: se crean solo si no existen.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* Q1 (flujo de caja): columnstore no agrupado sobre el hecho más grande. Se elige
   NO agrupado (y no un clustered columnstore que reemplace la tabla) para mantener la
   PK y el UNIQUE de linea_extracto_id que usa la carga idempotente del ETL. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ncci_fact_movimientos_bancarios')
    CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_fact_movimientos_bancarios
        ON dw.fact_movimientos_bancarios (fecha_imputacion_key, moneda_key, banco_cuenta_key, tipo_movimiento_key,
                                          monto, monto_usd);
GO

/* Q2 (evolución de cartera / aging): "¿cuánto se cobró de esta factura hasta tal fecha?"
   Clave (factura_id, fecha) para buscar directo; INCLUDE (monto) para no volver a la tabla. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_fact_cobranzas_factura')
    CREATE NONCLUSTERED INDEX ix_fact_cobranzas_factura
        ON dw.fact_cobranzas (factura_id, fecha_cobranza_key) INCLUDE (monto);
GO

/* Q2: solo las facturas de clientes (AR), ordenadas por emisión. Filtrado: la mitad AP
   de la tabla no ocupa lugar en el índice. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'fx_fact_facturas_ar_emision')
    CREATE NONCLUSTERED INDEX fx_fact_facturas_ar_emision
        ON dw.fact_facturas (fecha_emision_key)
        INCLUDE (factura_id, monto, monto_usd, fecha_vencimiento_key)
        WHERE tipo_factura = 'AR';
GO

/* Q3 (pendientes de conciliación): filtrado a las partidas pendientes, que son una
   fracción mínima de la tabla. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'fx_fact_conciliacion_pendientes')
    CREATE NONCLUSTERED INDEX fx_fact_conciliacion_pendientes
        ON dw.fact_conciliacion (estado, banco_cuenta_key)
        INCLUDE (origen, pago_id, cobranza_id, linea_extracto_id, fecha_libro_key, fecha_banco_key,
                 monto_libro, monto_banco)
        WHERE estado IN ('PENDIENTE_EN_BANCO', 'PENDIENTE_EN_LIBROS');
GO
