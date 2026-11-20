/* =============================================================================
   01_roles_y_permisos.sql — Roles, permisos por schema y usuarios.

   Analogía: en tesorería no todos tienen la misma llave. El analista consulta el libro
   (dw) y los reportes (rpt), pero no entra a la carpeta de extractos crudos (stg) ni a la
   bitácora de auditoría (audit). El auditor lee todo pero no puede tocar nada. El proceso
   de carga (ETL) escribe, pero solo a través de sus procedimientos.

   Principio de mínimo privilegio, implementado con:
   - Permisos a ROLES, nunca a personas: se agrega o se saca gente del rol.
   - GRANT a nivel de SCHEMA: cubre las tablas de hoy y las que se creen mañana.
   - DENY explícito donde importa: un DENY le gana a cualquier GRANT (aunque alguien agregue
     al usuario a otro rol por error, sigue sin poder leer staging).

   Usuarios:
   - analista_ar, analista_br, auditor_demo: usuarios SIN LOGIN, para demostrar y probar los
     permisos con EXECUTE AS (no pueden conectarse: solo se "suplanta" su identidad).
   - $(BI_USER): login real de solo lectura para Power BI (Fase 9).
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

IF SCHEMA_ID(N'rpt') IS NULL EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');   -- vistas para Power BI (Fase 9)
GO

IF DATABASE_PRINCIPAL_ID(N'rol_lectura_analistas') IS NULL CREATE ROLE rol_lectura_analistas AUTHORIZATION dbo;
IF DATABASE_PRINCIPAL_ID(N'rol_auditoria') IS NULL CREATE ROLE rol_auditoria AUTHORIZATION dbo;
GO

-- Analistas: leen el modelo y los reportes. Nada de staging, auditoría ni seguridad.
GRANT SELECT ON SCHEMA::dw  TO rol_lectura_analistas;
GRANT SELECT ON SCHEMA::rpt TO rol_lectura_analistas;
DENY  SELECT ON SCHEMA::stg   TO rol_lectura_analistas;
DENY  SELECT ON SCHEMA::audit TO rol_lectura_analistas;
DENY  SELECT ON SCHEMA::sec   TO rol_lectura_analistas;
-- El reporte mensual dinámico (06_queries/06) se puede ejecutar si existe.
IF OBJECT_ID(N'dw.usp_reporte_mensual') IS NOT NULL
    GRANT EXECUTE ON OBJECT::dw.usp_reporte_mensual TO rol_lectura_analistas;
GO

-- Auditoría: lee TODO (incluida la cuarentena y la bitácora) y no escribe NADA.
GRANT SELECT ON SCHEMA::dw    TO rol_auditoria;
GRANT SELECT ON SCHEMA::rpt   TO rol_auditoria;
GRANT SELECT ON SCHEMA::stg   TO rol_auditoria;
GRANT SELECT ON SCHEMA::audit TO rol_auditoria;
GRANT SELECT ON SCHEMA::sec   TO rol_auditoria;
DENY INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::dw    TO rol_auditoria;
DENY INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::stg   TO rol_auditoria;
DENY INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::audit TO rol_auditoria;
DENY INSERT, UPDATE, DELETE          ON SCHEMA::sec   TO rol_auditoria;
GO

-- Usuarios de demostración (sin login).
IF USER_ID(N'analista_ar') IS NULL  CREATE USER analista_ar  WITHOUT LOGIN WITH DEFAULT_SCHEMA = rpt;
IF USER_ID(N'analista_br') IS NULL  CREATE USER analista_br  WITHOUT LOGIN WITH DEFAULT_SCHEMA = rpt;
IF USER_ID(N'auditor_demo') IS NULL CREATE USER auditor_demo WITHOUT LOGIN WITH DEFAULT_SCHEMA = dw;
GO
IF IS_ROLEMEMBER(N'rol_lectura_analistas', N'analista_ar') = 0 ALTER ROLE rol_lectura_analistas ADD MEMBER analista_ar;
IF IS_ROLEMEMBER(N'rol_lectura_analistas', N'analista_br') = 0 ALTER ROLE rol_lectura_analistas ADD MEMBER analista_br;
IF IS_ROLEMEMBER(N'rol_auditoria', N'auditor_demo') = 0        ALTER ROLE rol_auditoria ADD MEMBER auditor_demo;
GO

-- Login real de Power BI (misma lógica que el del ETL: la clave sale del .env y se re-sincroniza).
USE master;
GO
IF SUSER_ID(N'$(BI_USER)') IS NULL
    CREATE LOGIN [$(BI_USER)] WITH PASSWORD = N'$(BI_PASSWORD)', DEFAULT_DATABASE = [$(DB_NAME)],
        CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [$(BI_USER)] WITH PASSWORD = N'$(BI_PASSWORD)';
GO
USE [$(DB_NAME)];
GO
IF USER_ID(N'$(BI_USER)') IS NULL CREATE USER [$(BI_USER)] FOR LOGIN [$(BI_USER)] WITH DEFAULT_SCHEMA = rpt;
GO
IF IS_ROLEMEMBER(N'rol_lectura_analistas', N'$(BI_USER)') = 0 ALTER ROLE rol_lectura_analistas ADD MEMBER [$(BI_USER)];
GO
