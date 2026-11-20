/* =============================================================================
   06_usp_conciliar.sql — Conciliación bancaria automática (matching libro vs. banco).

   Es lo que un tesorero hace con la planilla: para cada pago/cobranza del ERP busca
   en el extracto el movimiento que le corresponde, lo "tilda", y lo que queda sin
   tildar de cada lado son las partidas pendientes.

   Reglas de matching (todas exigen MISMA CUENTA y SIGNO, y que el banco lo registre entre
   el día del ERP y @dias_ventana días después):
     prioridad 1 - REFERENCIA completa: la descripción del banco contiene la referencia del ERP
     prioridad 2 - REFERENCIA parcial: contiene los últimos 5 caracteres de la referencia
     prioridad 3 - MONTO_FECHA: sin referencia, solo por importe y fecha
   Importe: el banco puede mostrar MENOS que el ERP (en valor con signo) por comisiones
   descontadas: un pago de -1.000 puede verse como -1.025; una cobranza de 1.000 como 975.
   Tolerancia: @tolerancia_usd en cuentas en USD (comisiones SWIFT), 1 centavo en el resto.

   Emparejamiento 1 a 1 por "mejor mutuo" (iterativo): en cada vuelta se aceptan los pares
   que son, a la vez, el mejor candidato del pago y el mejor candidato de la línea del banco.
   Orden de preferencia: prioridad (referencia) -> importe EXACTO -> menor desfase de fecha ->
   menor diferencia de importe. La fecha va antes que la diferencia porque, cuando el banco
   descontó una comisión, la diferencia es la comisión (aleatoria) y no dice nada; la cercanía
   de fecha sí. (Lo mostró la medición a escala 20: un solo par mal asignado de 107.700, de un
   mismo proveedor con dos transferencias SWIFT sin referencia y montos parecidos.)
   Se sacan los pares aceptados y se repite con lo que queda.
   Así un movimiento nunca concilia dos pagos, y dos pagos iguales (el posible doble pago)
   se reparten las dos líneas del banco por cercanía de fecha.

   Snapshot acumulativo: la partida del ERP se completa (línea, monto y fecha del banco,
   fecha de conciliación, estado, método) y la partida "solo banco" de esa línea se elimina,
   porque ahora el movimiento vive en la fila del ERP. Idempotente: solo trabaja con pendientes.
   Fecha de conciliación = fecha del movimiento bancario (no "hoy"): así el resultado no
   depende del día en que se corre el proceso y se puede reproducir.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE dw.usp_conciliar
    @ejecucion_id   UNIQUEIDENTIFIER = NULL,
    @dias_ventana   INT = 7,
    @tolerancia_usd DECIMAL(19,2) = 50.00
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @proc SYSNAME = N'dw.usp_conciliar';
    DECLARE @log_id INT, @vuelta INT = 0, @nuevos INT = 1, @leidas INT, @msg_ok NVARCHAR(4000);
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        -- Lado libros pendiente (con la referencia que mandó el ERP al banco).
        SELECT k.conciliacion_key, k.banco_cuenta_key, k.monto_libro, f.fecha AS fecha_libro, m.codigo_iso AS moneda,
               COALESCE(p.referencia_pago, c.referencia_cobranza) AS referencia
        INTO #libro
        FROM dw.fact_conciliacion k
        JOIN dw.dim_fecha f ON f.fecha_key = k.fecha_libro_key
        JOIN dw.dim_moneda m ON m.moneda_key = k.moneda_key
        LEFT JOIN dw.fact_pagos p ON p.pago_id = k.pago_id
        LEFT JOIN dw.fact_cobranzas c ON c.cobranza_id = k.cobranza_id
        WHERE k.estado = 'PENDIENTE_EN_BANCO';

        -- Lado banco pendiente (con la descripción, que es donde viene la referencia).
        SELECT k.conciliacion_key, k.linea_extracto_id, k.banco_cuenta_key, k.monto_banco, k.fecha_banco_key,
               f.fecha AS fecha_banco, mv.descripcion
        INTO #banco
        FROM dw.fact_conciliacion k
        JOIN dw.dim_fecha f ON f.fecha_key = k.fecha_banco_key
        JOIN dw.fact_movimientos_bancarios mv ON mv.linea_extracto_id = k.linea_extracto_id
        WHERE k.estado = 'PENDIENTE_EN_LIBROS';
        SET @leidas = (SELECT COUNT(*) FROM #libro) + (SELECT COUNT(*) FROM #banco);
        CREATE INDEX ix_banco ON #banco (banco_cuenta_key, fecha_banco) INCLUDE (monto_banco);

        -- Todos los pares candidatos, con su prioridad y su "distancia".
        SELECT l.conciliacion_key AS k_libro, b.conciliacion_key AS k_banco, b.linea_extracto_id, b.monto_banco,
               b.fecha_banco_key, l.fecha_libro, b.fecha_banco,
               CASE WHEN b.descripcion LIKE N'%' + l.referencia + N'%' THEN 1
                    WHEN b.descripcion LIKE N'% ' + RIGHT(l.referencia, 5) + N' %' THEN 2
                    ELSE 3 END AS prioridad,
               ABS(b.monto_banco - l.monto_libro) AS diferencia_abs,
               DATEDIFF(DAY, l.fecha_libro, b.fecha_banco) AS dias
        INTO #pares
        FROM #libro l
        JOIN #banco b
          ON b.banco_cuenta_key = l.banco_cuenta_key
         AND b.fecha_banco BETWEEN l.fecha_libro AND DATEADD(DAY, @dias_ventana, l.fecha_libro)
         AND SIGN(b.monto_banco) = SIGN(l.monto_libro)
         AND b.monto_banco BETWEEN l.monto_libro - IIF(l.moneda = 'USD', @tolerancia_usd, 0.01) AND l.monto_libro + 0.01;

        CREATE TABLE #match (k_libro BIGINT PRIMARY KEY, k_banco BIGINT NOT NULL UNIQUE, prioridad TINYINT NOT NULL);

        -- Mejor mutuo, por vueltas, hasta que no aparezcan pares nuevos.
        WHILE @nuevos > 0
        BEGIN
            SET @vuelta += 1;
            WITH ranking AS (
                SELECT p.*,
                       ROW_NUMBER() OVER (PARTITION BY p.k_libro ORDER BY p.prioridad, IIF(p.diferencia_abs = 0, 0, 1), p.dias,
                                          p.diferencia_abs, p.k_banco) AS rn_libro,
                       ROW_NUMBER() OVER (PARTITION BY p.k_banco ORDER BY p.prioridad, IIF(p.diferencia_abs = 0, 0, 1), p.dias,
                                          p.diferencia_abs, p.k_libro) AS rn_banco
                FROM #pares p
                WHERE NOT EXISTS (SELECT 1 FROM #match m WHERE m.k_libro = p.k_libro OR m.k_banco = p.k_banco)
            )
            INSERT INTO #match (k_libro, k_banco, prioridad)
            SELECT k_libro, k_banco, prioridad FROM ranking WHERE rn_libro = 1 AND rn_banco = 1;
            SET @nuevos = @@ROWCOUNT;
        END

        BEGIN TRANSACTION;
        -- Primero se elimina la partida "solo banco" (la línea no puede estar en dos partidas: índice único).
        DELETE k FROM dw.fact_conciliacion k JOIN #match m ON m.k_banco = k.conciliacion_key;

        UPDATE k
        SET linea_extracto_id = p.linea_extracto_id, monto_banco = p.monto_banco, fecha_banco_key = p.fecha_banco_key,
            fecha_conciliacion_key = p.fecha_banco_key,
            dias_habiles_desfase = hab.n,
            estado = IIF(p.monto_banco = k.monto_libro, 'CONCILIADA', 'CONCILIADA_CON_DIFERENCIA'),
            metodo_match = IIF(m.prioridad IN (1, 2), 'REFERENCIA', 'MONTO_FECHA'),
            fecha_actualizacion_dw = SYSUTCDATETIME()
        FROM dw.fact_conciliacion k
        JOIN #match m ON m.k_libro = k.conciliacion_key
        JOIN #pares p ON p.k_libro = m.k_libro AND p.k_banco = m.k_banco
        -- días hábiles entre el registro en libros y el movimiento del banco
        CROSS APPLY (SELECT COUNT(*) AS n FROM dw.dim_fecha d
                     WHERE d.fecha > p.fecha_libro AND d.fecha <= p.fecha_banco AND d.es_habil = 1) hab;
        COMMIT;

        SELECT @msg_ok = CONCAT(N'vueltas=', @vuelta, N', conciliadas=', COUNT(*),
                                N' (referencia=', SUM(IIF(prioridad IN (1, 2), 1, 0)),
                                N', monto_fecha=', SUM(IIF(prioridad = 3, 1, 0)), N')')
        FROM #match;
        DECLARE @n INT = (SELECT COUNT(*) FROM #match);
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @leidas, 0, @n, 0, 0, @msg_ok, @eliminadas = @n;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE(), @num INT = ERROR_NUMBER(), @lin INT = ERROR_LINE(),
                @prc NVARCHAR(128) = ERROR_PROCEDURE();
        EXEC audit.usp_etl_log_fin @log_id, 'ERROR', @mensaje = @msg, @error_numero = @num,
             @error_linea = @lin, @error_proc = @prc;
        THROW;
    END CATCH
END;
GO
