/* =============================================================================
   01_crear_base_y_schemas.sql
   Crea la base y los schemas del proyecto. Idempotente: se puede correr N veces
   y siempre deja el mismo resultado.

   Analogía de tesorería: los schemas son "carpetas" del archivo de tesorería.
     stg   = extractos y planillas tal cual llegan del banco/ERP (crudo)
     dw    = libro conciliado: dimensiones y hechos ya validados
     audit = bitácora de cargas y resultados de control de calidad
     sec   = objetos de seguridad (funciones de RLS, etc.)
   Separar por schema permite dar permisos por "carpeta" (GRANT ON SCHEMA::dw)
   en vez de tabla por tabla.

   $(DB_NAME) es una variable de SQLCMD: la reemplaza scripts/run_sql.sh
   (por defecto TesoreriaDW; los tests usan TesoreriaDW_test). Para correrlo a mano
   en Azure Data Studio/SSMS, activar "SQLCMD mode" y poner arriba:
       :setvar DB_NAME TesoreriaDW
   ============================================================================= */
SET NOCOUNT ON;

IF DB_ID(N'$(DB_NAME)') IS NULL
BEGIN
    -- Collation explícita (CI = no distingue mayúsculas, AS = sí distingue
    -- acentos). Fijarla evita que el comportamiento de los JOIN/WHERE sobre
    -- texto dependa de cómo se instaló el servidor.
    CREATE DATABASE [$(DB_NAME)] COLLATE Latin1_General_100_CI_AS;
    PRINT 'Base $(DB_NAME) creada.';
END
ELSE
    PRINT 'Base $(DB_NAME) ya existía.';
GO

-- SIMPLE: no necesitamos backups de log en un entorno de portfolio; evita que
-- el .ldf crezca sin límite durante cargas masivas.
ALTER DATABASE [$(DB_NAME)] SET RECOVERY SIMPLE;
GO

USE [$(DB_NAME)];
GO

-- CREATE SCHEMA tiene que ser la única sentencia del batch, por eso va dentro
-- de EXEC(): así podemos envolverlo en un IF y mantener la idempotencia.
IF SCHEMA_ID(N'stg')   IS NULL EXEC(N'CREATE SCHEMA stg   AUTHORIZATION dbo;');
IF SCHEMA_ID(N'dw')    IS NULL EXEC(N'CREATE SCHEMA dw    AUTHORIZATION dbo;');
IF SCHEMA_ID(N'audit') IS NULL EXEC(N'CREATE SCHEMA audit AUTHORIZATION dbo;');
IF SCHEMA_ID(N'sec')   IS NULL EXEC(N'CREATE SCHEMA sec   AUTHORIZATION dbo;');
GO

SELECT name AS schema_creado
FROM sys.schemas
WHERE name IN (N'stg', N'dw', N'audit', N'sec')
ORDER BY name;
GO
