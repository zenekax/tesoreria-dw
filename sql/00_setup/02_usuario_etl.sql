/* =============================================================================
   02_usuario_etl.sql
   Login de aplicación para la carga (nada de `sa` en scripts de aplicación).

   Principio de mínimo privilegio, en criollo: el cadete que lleva los extractos al
   archivo puede dejar papeles en la carpeta "stg" y anotar en la bitácora, pero no
   puede abrir el libro conciliado (dw) ni cambiar la estructura de las carpetas.

   Variables SQLCMD (las pasa scripts/run_sql.sh desde .env):
     $(DB_NAME), $(ETL_USER), $(ETL_PASSWORD)
   En la Fase 8 se agregan los roles de analistas y auditoría, RLS y masking.
   ============================================================================= */
SET NOCOUNT ON;
USE master;
GO

-- El login es del servidor (sirve para cualquier base). Si ya existe se le
-- re-sincroniza la clave con la del .env: así el script siempre deja todo igual.
IF SUSER_ID(N'$(ETL_USER)') IS NULL
    CREATE LOGIN [$(ETL_USER)] WITH PASSWORD = N'$(ETL_PASSWORD)',
        DEFAULT_DATABASE = [$(DB_NAME)], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [$(ETL_USER)] WITH PASSWORD = N'$(ETL_PASSWORD)';
GO

USE [$(DB_NAME)];
GO

-- El usuario es de la base y se mapea al login.
IF USER_ID(N'$(ETL_USER)') IS NULL
    CREATE USER [$(ETL_USER)] FOR LOGIN [$(ETL_USER)] WITH DEFAULT_SCHEMA = stg;
GO

-- Los permisos se dan al ROL, no al usuario: si mañana hay otro proceso de carga,
-- se lo agrega al rol y hereda exactamente lo mismo.
IF DATABASE_PRINCIPAL_ID(N'rol_etl') IS NULL
    CREATE ROLE rol_etl AUTHORIZATION dbo;
GO
IF IS_ROLEMEMBER(N'rol_etl', N'$(ETL_USER)') = 0
    ALTER ROLE rol_etl ADD MEMBER [$(ETL_USER)];
GO

-- A nivel de schema: aplica a las tablas que existen hoy y a las que se creen después.
-- Sin ALTER/CONTROL: el ETL no puede crear, borrar ni truncar tablas.
GRANT SELECT, INSERT, DELETE ON SCHEMA::stg   TO rol_etl;
GRANT SELECT, INSERT         ON SCHEMA::audit TO rol_etl;
GO
-- (El UPDATE puntual sobre audit.carga_staging se otorga en sql/01_staging, cuando la tabla ya existe.)

