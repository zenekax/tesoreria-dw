/* =============================================================================
   06_pivot_dinamico_seguro.sql — Reporte mensual con columnas dinámicas (SQL dinámico SEGURO).

   PREGUNTA DE NEGOCIO: ¿cuánto le pagamos (o cobramos, o nos facturó) a cada contraparte,
   mes por mes? Es la "tabla dinámica" de Excel: contrapartes en filas, meses en columnas.

   Por qué SQL dinámico: PIVOT necesita los nombres de las columnas escritos en la consulta
   ([2025-11], [2025-12], ...). Si el período cambia, cambian las columnas: hay que armar
   la consulta en tiempo de ejecución.

   Por qué es SEGURO (no hay inyección de SQL posible):
     1. Lo único que se concatena son valores que NO vienen del usuario: el nombre de la
        tabla sale de una LISTA BLANCA (CASE con 3 opciones fijas) y los meses salen de
        dw.dim_fecha. Todo nombre pasa por QUOTENAME (lo envuelve en [ ] y escapa el ]).
     2. Lo que SÍ viene del usuario (fechas y moneda) viaja como PARÁMETRO de
        sp_executesql, nunca pegado al texto: SQL Server lo trata como dato, no como código.
     3. Se valida todo antes: flujo en la lista, moneda existente, período de 1 a 24 meses.
   (Lo que NO hay que hacer: SET @sql = '... WHERE moneda = ''' + @moneda + '''': con
    @moneda = 'ARS'' OR 1=1 --' se ejecuta lo que el usuario quiera.)

   Ejecutar este archivo crea el procedimiento y corre dos ejemplos.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE dw.usp_reporte_mensual
    @flujo        VARCHAR(20)  = 'PAGOS',          -- PAGOS | COBRANZAS | FACTURAS
    @desde        DATE         = '2025-11-01',
    @hasta        DATE         = '2026-10-31',
    @moneda       NVARCHAR(10) = NULL,             -- NULL = todas (en USD)
    @mostrar_sql  BIT          = 0                 -- 1 = devuelve el SQL generado (para revisarlo)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tabla NVARCHAR(100), @col_fecha SYSNAME, @cols NVARCHAR(MAX), @cols_select NVARCHAR(MAX),
            @sql NVARCHAR(MAX);

    -- 1. Lista blanca: el usuario elige una opción, nunca escribe un nombre de tabla.
    SELECT @tabla = CASE @flujo WHEN 'PAGOS' THEN N'dw.fact_pagos' WHEN 'COBRANZAS' THEN N'dw.fact_cobranzas'
                                WHEN 'FACTURAS' THEN N'dw.fact_facturas' END,
           @col_fecha = CASE @flujo WHEN 'PAGOS' THEN N'fecha_pago_key' WHEN 'COBRANZAS' THEN N'fecha_cobranza_key'
                                    WHEN 'FACTURAS' THEN N'fecha_emision_key' END;
    IF @tabla IS NULL
        THROW 50020, N'@flujo tiene que ser PAGOS, COBRANZAS o FACTURAS.', 1;
    IF @moneda IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dw.dim_moneda WHERE codigo_iso = @moneda AND moneda_key > 0)
        THROW 50022, N'@moneda no es una moneda operada.', 1;
    IF @desde > @hasta OR DATEDIFF(MONTH, @desde, @hasta) > 23
        THROW 50021, N'El período tiene que ir de 1 a 24 meses.', 1;

    -- 2. Columnas = meses del período, tomadas del calendario (no del usuario).
    SELECT @cols = STRING_AGG(QUOTENAME(anio_mes), N', ') WITHIN GROUP (ORDER BY anio_mes),
           @cols_select = STRING_AGG(N'ISNULL(' + QUOTENAME(anio_mes) + N', 0) AS ' + QUOTENAME(anio_mes), N', ')
                          WITHIN GROUP (ORDER BY anio_mes)
    FROM (SELECT DISTINCT anio_mes FROM dw.dim_fecha WHERE fecha BETWEEN @desde AND @hasta) m;

    -- 3. Consulta con parámetros (@p_*): las fechas y la moneda no se pegan al texto.
    SET @sql = N'
SELECT tipo_contraparte, contraparte_id, razon_social, ' + @cols_select + N', total_usd
FROM (
    SELECT cp.contraparte_id, actual.razon_social, actual.tipo_contraparte, f.anio_mes, h.monto_usd,
           SUM(h.monto_usd) OVER (PARTITION BY cp.contraparte_id) AS total_usd
    FROM ' + @tabla + N' h
    JOIN dw.dim_fecha f ON f.fecha_key = h.' + QUOTENAME(@col_fecha) + N'
    JOIN dw.dim_contraparte cp ON cp.contraparte_key = h.contraparte_key
    JOIN dw.dim_contraparte actual ON actual.contraparte_id = cp.contraparte_id AND actual.es_vigente = 1
    JOIN dw.dim_moneda m ON m.moneda_key = h.moneda_key
    WHERE f.fecha BETWEEN @p_desde AND @p_hasta
      AND (@p_moneda IS NULL OR m.codigo_iso = @p_moneda)
      AND cp.contraparte_key > 0
) AS fuente
PIVOT (SUM(monto_usd) FOR anio_mes IN (' + @cols + N')) AS p
ORDER BY total_usd DESC;';

    IF @mostrar_sql = 1
        SELECT @sql AS sql_generado;

    EXEC sys.sp_executesql @sql,
         N'@p_desde DATE, @p_hasta DATE, @p_moneda NVARCHAR(10)',
         @p_desde = @desde, @p_hasta = @hasta, @p_moneda = @moneda;
END;
GO

-- Ejemplos: pagos de todo el año (USD) y cobranzas del último trimestre solo en BRL.
EXEC dw.usp_reporte_mensual @flujo = 'PAGOS';
EXEC dw.usp_reporte_mensual @flujo = 'COBRANZAS', @desde = '2026-08-01', @hasta = '2026-10-31', @moneda = 'BRL';
GO
