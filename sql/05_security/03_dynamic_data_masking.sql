/* =============================================================================
   03_dynamic_data_masking.sql — Enmascaramiento dinámico de datos sensibles.

   Qué se enmascara (lo que no hace falta para analizar y sí sirve para un fraude):
     dim_banco_cuenta.numero_cuenta  CBU/CLABE: se ven solo los últimos 4 ('XXXX...7809')
     dim_contraparte.email           email():   'tXXX@XXXX.com'
     dim_contraparte.tax_id          CUIT/CNPJ: se ven solo los últimos 3

   Quién ve el dato real (permiso UNMASK): auditoría y el ETL. El ETL lo NECESITA: el
   enmascarado se aplica a todo lo que lee un usuario sin UNMASK, también dentro de los
   procedimientos; si la carga copiara a una tabla temporal un número de cuenta enmascarado,
   los cruces contra staging fallarían. dbo/sa ven todo siempre.

   Límite honesto: el masking NO es cifrado. El dato está en claro en disco y un usuario con
   permiso de consulta libre podría inferirlo con filtros (WHERE numero_cuenta LIKE '99%'). Es
   una capa para pantallas y reportes; la protección fuerte es no darle SELECT a quien no
   corresponde (permisos) y, para datos críticos, Always Encrypted.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

/* En una base nueva las columnas ya nacen enmascaradas (sql/02_dw/01_dimensiones.sql). Esto es la
   MIGRACIÓN para bases creadas antes de la Fase 8. Detalle: email y tax_id alimentan la columna
   calculada hash_tipo1 (y el índice de la versión vigente la incluye), y SQL Server no deja
   cambiar una columna de la que depende otra: hay que sacar índice y hash, enmascarar y volver
   a crearlos, todo en una transacción. */
IF NOT EXISTS (SELECT 1 FROM sys.masked_columns WHERE object_id = OBJECT_ID(N'dw.dim_banco_cuenta') AND name = N'numero_cuenta')
    ALTER TABLE dw.dim_banco_cuenta ALTER COLUMN numero_cuenta ADD MASKED WITH (FUNCTION = 'partial(0, "XXXX...", 4)');
GO
IF NOT EXISTS (SELECT 1 FROM sys.masked_columns WHERE object_id = OBJECT_ID(N'dw.dim_contraparte') AND name = N'email')
BEGIN
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    DROP INDEX ux_dim_contraparte_vigente ON dw.dim_contraparte;
    ALTER TABLE dw.dim_contraparte DROP COLUMN hash_tipo1;
    ALTER TABLE dw.dim_contraparte ALTER COLUMN email ADD MASKED WITH (FUNCTION = 'email()');
    ALTER TABLE dw.dim_contraparte ALTER COLUMN tax_id ADD MASKED WITH (FUNCTION = 'partial(0, "XX-XXXXXX", 3)');
    -- misma definición que en 01_dimensiones.sql
    ALTER TABLE dw.dim_contraparte ADD hash_tipo1 AS CAST(HASHBYTES('SHA2_256',
        CONCAT_WS(N'|', tipo_contraparte, razon_social, tax_id, email, pais, moneda_default,
                  CONVERT(CHAR(8), fecha_alta, 112))) AS BINARY(32)) PERSISTED;
    CREATE UNIQUE INDEX ux_dim_contraparte_vigente ON dw.dim_contraparte (contraparte_id)
        INCLUDE (hash_tipo1, hash_tipo2) WHERE es_vigente = 1;
    COMMIT;
END
GO

/* Los hashes del SCD (huellas de email + CUIT) no se enmascaran (una columna calculada no
   admite máscara) y se podrían atacar por diccionario: los analistas no los pueden leer.
   Efecto: un analista no puede hacer SELECT * sobre dw.dim_contraparte (tiene que nombrar
   columnas); Power BI usa las vistas rpt, que no las incluyen. */
DENY SELECT ON OBJECT::dw.dim_contraparte (hash_tipo1, hash_tipo2) TO rol_lectura_analistas;
GO

GRANT UNMASK TO rol_auditoria;
GRANT UNMASK TO rol_etl;
GO

SELECT OBJECT_SCHEMA_NAME(object_id) + '.' + OBJECT_NAME(object_id) AS tabla, name AS columna, masking_function
FROM sys.masked_columns ORDER BY tabla, columna;
GO
