/* =============================================================================
   02_row_level_security.sql — Row-Level Security (RLS): cada analista ve SOLO sus monedas.

   Caso de negocio: la mesa de Argentina mira ARS y USD; la de Brasil, BRL. Comparten las
   mismas tablas y los mismos reportes, pero cada uno ve únicamente sus filas. Sin RLS habría
   que hacer una vista (o un tablero) por equipo, y cualquier consulta nueva podría olvidarse
   del filtro. Con RLS el filtro lo pone el MOTOR, en cada consulta, aunque el analista no lo
   escriba (y también a través de las vistas rpt y de Power BI).

   Cómo funciona:
     sec.usuario_moneda       = qué monedas ve cada usuario ('*' = todas)
     sec.fn_rls_moneda_*      = función que devuelve una fila si el usuario puede ver la fila
     sec.pol_rls_moneda       = política que aplica la función como FILTRO a cada tabla
   Ven todo, sin filtro: dbo/db_owner (administración), rol_etl (la carga necesita ver todo)
   y rol_auditoria.

   Detalle técnico: las funciones son WITH SCHEMABINDING (obligatorio para RLS: nadie puede
   cambiar las tablas que usan sin sacar antes la política) e inline (una sola SELECT), así
   el optimizador las "pega" en el plan como un JOIN más.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

IF OBJECT_ID(N'sec.usuario_moneda', N'U') IS NULL
CREATE TABLE sec.usuario_moneda (
    usuario    SYSNAME NOT NULL,
    moneda_iso CHAR(3) NOT NULL,   -- '*' = todas las monedas
    CONSTRAINT pk_usuario_moneda PRIMARY KEY (usuario, moneda_iso)
);
GO

-- Asignaciones (idempotente). En producción esto lo mantiene seguridad informática.
MERGE sec.usuario_moneda AS d
USING (VALUES (N'analista_ar', 'ARS'), (N'analista_ar', 'USD'), (N'analista_br', 'BRL'),
              (N'$(BI_USER)', '*')) AS s (usuario, moneda_iso)
    ON d.usuario = s.usuario AND d.moneda_iso = s.moneda_iso
WHEN NOT MATCHED BY TARGET THEN INSERT (usuario, moneda_iso) VALUES (s.usuario, s.moneda_iso);
GO

-- La política se saca antes de (re)crear las funciones: con SCHEMABINDING no se pueden
-- modificar mientras una política las use. Al final del script se vuelve a crear.
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = N'pol_rls_moneda')
    DROP SECURITY POLICY sec.pol_rls_moneda;
GO

CREATE OR ALTER FUNCTION sec.fn_rls_moneda_key (@moneda_key INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS permitido
    WHERE IS_MEMBER(N'db_owner') = 1
       OR IS_MEMBER(N'rol_etl') = 1
       OR IS_MEMBER(N'rol_auditoria') = 1
       OR EXISTS (SELECT 1
                  FROM sec.usuario_moneda um
                  JOIN dw.dim_moneda m ON um.moneda_iso IN (m.codigo_iso, '*')
                  WHERE um.usuario = USER_NAME() AND m.moneda_key = @moneda_key);
GO

CREATE OR ALTER FUNCTION sec.fn_rls_moneda_iso (@moneda_iso CHAR(3))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS permitido
    WHERE IS_MEMBER(N'db_owner') = 1
       OR IS_MEMBER(N'rol_etl') = 1
       OR IS_MEMBER(N'rol_auditoria') = 1
       OR EXISTS (SELECT 1 FROM sec.usuario_moneda um
                  WHERE um.usuario = USER_NAME() AND um.moneda_iso IN (@moneda_iso, '*'));
GO

CREATE SECURITY POLICY sec.pol_rls_moneda
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_facturas,
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_pagos,
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_cobranzas,
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_movimientos_bancarios,
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_saldo_bancario_mensual,
    ADD FILTER PREDICATE sec.fn_rls_moneda_key(moneda_key) ON dw.fact_conciliacion,
    ADD FILTER PREDICATE sec.fn_rls_moneda_iso(moneda_iso) ON dw.dim_banco_cuenta
WITH (STATE = ON, SCHEMABINDING = ON);
GO
