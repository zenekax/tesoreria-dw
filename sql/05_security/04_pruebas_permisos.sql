/* =============================================================================
   04_pruebas_permisos.sql — Demostración de permisos, RLS y masking con EXECUTE AS.

   EXECUTE AS USER = 'x' hace que la sesión "se ponga el traje" de otro usuario hasta el
   REVERT: es la forma de probar la seguridad sin tener su clave. (Solo lo puede hacer quien
   tiene permiso IMPERSONATE, como dbo.) Cada intento prohibido se envuelve en TRY/CATCH y se
   informa el error que devolvió SQL Server.

   Resultado esperado:
     analista_ar  -> ve ARS y USD; CBU/email enmascarados; staging y auditoría: DENEGADO; no escribe
     analista_br  -> ve solo BRL; idem
     auditor_demo -> ve todas las monedas y los datos reales; no puede escribir
   Los tests (python/tests/test_seguridad.py) verifican lo mismo automáticamente.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

DECLARE @resultado TABLE (usuario SYSNAME, prueba NVARCHAR(100), resultado NVARCHAR(400));
DECLARE @usuarios TABLE (orden INT, usuario SYSNAME);
INSERT INTO @usuarios VALUES (1, N'analista_ar'), (2, N'analista_br'), (3, N'auditor_demo');
DECLARE @u SYSNAME, @i INT = 1, @txt NVARCHAR(400);

WHILE @i <= 3
BEGIN
    SELECT @u = usuario FROM @usuarios WHERE orden = @i;
    EXECUTE AS USER = @u;

    -- 1. RLS: qué monedas ve en los pagos
    SELECT @txt = ISNULL(STRING_AGG(CAST(codigo_iso AS NVARCHAR(3)), N', ') WITHIN GROUP (ORDER BY codigo_iso), N'(ninguna)')
    FROM (SELECT DISTINCT m.codigo_iso FROM dw.fact_pagos p JOIN dw.dim_moneda m ON m.moneda_key = p.moneda_key) x;
    INSERT INTO @resultado VALUES (@u, N'RLS: monedas visibles en fact_pagos', @txt);

    -- 2. Masking: cómo ve un número de cuenta y un email
    SELECT TOP (1) @txt = numero_cuenta FROM dw.dim_banco_cuenta WHERE banco_cuenta_key > 0 ORDER BY banco_cuenta_key;
    INSERT INTO @resultado VALUES (@u, N'Masking: numero_cuenta', ISNULL(@txt, N'(no ve ninguna cuenta)'));
    SELECT TOP (1) @txt = email FROM dw.dim_contraparte WHERE email IS NOT NULL ORDER BY contraparte_key;
    INSERT INTO @resultado VALUES (@u, N'Masking: email de contraparte', ISNULL(@txt, N'(sin datos)'));

    -- 3. Leer staging (crudo, con datos sensibles sin enmascarar)
    BEGIN TRY
        SELECT @txt = CONCAT(COUNT(*), N' filas') FROM stg.payments;
        INSERT INTO @resultado VALUES (@u, N'Leer stg.payments', N'PERMITIDO: ' + @txt);
    END TRY
    BEGIN CATCH
        INSERT INTO @resultado VALUES (@u, N'Leer stg.payments', CONCAT(N'DENEGADO (', ERROR_NUMBER(), N')'));
    END CATCH

    -- 4. Escribir en el DW
    BEGIN TRY
        BEGIN TRANSACTION;
        DELETE TOP (1) FROM dw.fact_pagos;
        ROLLBACK;   -- si llegara a poder, no se borra nada igual
        INSERT INTO @resultado VALUES (@u, N'Borrar en dw.fact_pagos', N'PERMITIDO (se revirtió)');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO @resultado VALUES (@u, N'Borrar en dw.fact_pagos', CONCAT(N'DENEGADO (', ERROR_NUMBER(), N')'));
    END CATCH

    REVERT;
    SET @i += 1;
END

SELECT usuario, prueba, resultado FROM @resultado ORDER BY usuario, prueba;
GO
