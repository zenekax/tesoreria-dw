/* =============================================================================
   00_quitar_indices.sql — Vuelve a la LÍNEA BASE (sin los índices de la Fase 7) para medir
   el "antes". Solo se usa en la base de performance; el despliegue normal los crea con
   sql/02_dw/04_indices.sql.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO
DROP INDEX IF EXISTS ncci_fact_movimientos_bancarios ON dw.fact_movimientos_bancarios;
DROP INDEX IF EXISTS ix_fact_cobranzas_factura ON dw.fact_cobranzas;
DROP INDEX IF EXISTS fx_fact_facturas_ar_emision ON dw.fact_facturas;
DROP INDEX IF EXISTS fx_fact_conciliacion_pendientes ON dw.fact_conciliacion;
GO
