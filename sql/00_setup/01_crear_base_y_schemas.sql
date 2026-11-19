/* =============================================================================
   01_crear_base_y_schemas.sql
   Crea la base TesoreriaDW y los schemas del proyecto. Idempotente: se puede
   correr N veces y siempre deja el mismo resultado.

   Analogía de tesorería: los schemas son "carpetas" del archivo de tesorería.
     stg   = extractos y planillas tal cual llegan del banco/ERP (crudo)
     dw    = libro conciliado: dimensiones y hechos ya validados
     audit = bitácora de cargas y resultados de control de calidad
     sec   = objetos de seguridad (funciones de RLS, etc.)
   Separar por schema permite dar permisos por "carpeta" (GRANT ON SCHEMA::dw)
   en vez de tabla por tabla.

   Ejecutar:  docker exec tesoreria-sql /opt/mssql-tools18/bin/sqlcmd -C -S localhost \
                -U sa -P "$MSSQL_SA_PASSWORD" -b -i /sql/00_setup/01_crear_base_y_schemas.sql
   ============================================================================= */
SET NOCOUNT ON;

IF DB_ID(N'TesoreriaDW') IS NULL
BEGIN
    -- Collation explícita (CI = no distingue mayúsculas, AS = sí distingue
    -- acentos). Fijarla evita que el comportamiento de los JOIN/WHERE sobre
    -- texto dependa de cómo se instaló el servidor.
    CREATE DATABASE TesoreriaDW COLLATE Latin1_General_100_CI_AS;
    PRINT 'Base TesoreriaDW creada.';
END
ELSE
    PRINT 'Base TesoreriaDW ya existía.';
GO

-- SIMPLE: no necesitamos backups de log en un entorno de portfolio; evita que
-- el .ldf crezca sin límite durante cargas masivas.
ALTER DATABASE TesoreriaDW SET RECOVERY SIMPLE;
GO

USE TesoreriaDW;
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
