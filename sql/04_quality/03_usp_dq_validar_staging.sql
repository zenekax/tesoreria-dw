/* =============================================================================
   03_usp_dq_validar_staging.sql — Evalúa las reglas PRE_CARGA sobre staging.

   Flujo:
     1. Tipar staging una sola vez (#inv, #pag, #cob, #ext, #tc) con TRY_CONVERT.
     2. Cada regla es un INSERT INTO #err ... WHERE <condición que la viola>: una fila
        por cada fila de staging que falla (con archivo, línea, clave y valor observado).
        Las reglas son conjuntos (set-based): nada de cursores fila por fila.
     3. En UNA transacción: resultados por regla (audit.dq_resultados), detalle
        (audit.dq_errores) y sincronización de las cuarentenas:
          - fila con alguna regla ERROR y todavía no en cuarentena -> entra
          - fila ya en cuarentena que sigue fallando              -> se actualiza
          - fila en cuarentena que ya no falla (se corrigió y se recargó) -> LIBERADA
        Nada se borra: la cuarentena es el historial de lo observado.

   Las reglas de consistencia entre fuentes (pago/cobranza vs. extracto) no están acá: se
   evalúan después de la conciliación (04_usp_dq_controles_post_carga.sql).
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

CREATE OR ALTER PROCEDURE audit.usp_dq_validar_staging
    @ejecucion_id  UNIQUEIDENTIFIER = NULL,
    @fecha_corte   DATE = NULL       -- default: último día del último extracto informado
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @proc SYSNAME = N'audit.usp_dq_validar_staging';
    DECLARE @log_id INT, @nuevas INT = 0, @liberadas INT = 0, @vigentes INT, @evaluadas INT, @msg_ok NVARCHAR(4000);
    SET @ejecucion_id = ISNULL(@ejecucion_id, NEWID());
    EXEC audit.usp_etl_log_inicio @ejecucion_id, @proc, NULL, @fecha_corte, @log_id OUTPUT;
    BEGIN TRY
        IF @fecha_corte IS NULL
            SELECT @fecha_corte = EOMONTH(MAX(TRY_CONVERT(DATE, period + '-01', 23))) FROM stg.bank_balances;
        SET @fecha_corte = ISNULL(@fecha_corte, CAST(SYSUTCDATETIME() AS DATE));

        -- COLLATE DATABASE_DEFAULT: una tabla #temporal creada con CREATE TABLE toma la collation de
        -- tempdb (la del servidor), no la de esta base; sin esto, los JOIN de texto contra tablas de la
        -- base fallan con "Cannot resolve the collation conflict". (SELECT INTO hereda la de la columna origen.)
        CREATE TABLE #err (regla_id VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL,
                           tabla NVARCHAR(128) COLLATE DATABASE_DEFAULT NOT NULL, stg_row_id BIGINT NULL,
                           source_file NVARCHAR(260) COLLATE DATABASE_DEFAULT NULL, source_line INT NULL,
                           clave NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
                           valor NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL);
        CREATE TABLE #evaluadas (regla_id VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, filas INT NOT NULL);

        /* ------------------------------------------------ referencias */
        SELECT codigo_iso INTO #monedas FROM dw.dim_moneda WHERE moneda_key > 0;
        WITH c AS (SELECT account_id, account_number, currency,
                          ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY _row_id DESC) AS nro
                   FROM stg.bank_accounts)
        SELECT account_id, account_number, currency INTO #cuentas FROM c WHERE nro = 1;
        SELECT DISTINCT counterparty_id INTO #cps FROM stg.counterparties WHERE counterparty_id IS NOT NULL;

        /* ------------------------------------------------ facturas */
        SELECT s._row_id, s._source_file, s._source_line, s.invoice_id, s.invoice_number, s.counterparty_id,
               s.currency, s.amount, s.issue_date, s.due_date,
               TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto,
               TRY_CONVERT(DATE, s.issue_date, 23) AS f_emision, TRY_CONVERT(DATE, s.due_date, 23) AS f_venc,
               ROW_NUMBER() OVER (PARTITION BY s.invoice_id ORDER BY s._row_id) AS nro_id,
               ROW_NUMBER() OVER (PARTITION BY s.counterparty_id, s.invoice_number ORDER BY s._row_id) AS nro_numero
        INTO #inv FROM stg.invoices s;

        INSERT INTO #err SELECT 'INV_ID_NULO', 'invoices', _row_id, _source_file, _source_line, invoice_number, NULL
        FROM #inv WHERE invoice_id IS NULL;
        INSERT INTO #err SELECT 'INV_MONTO_NULO', 'invoices', _row_id, _source_file, _source_line, invoice_id, NULL
        FROM #inv WHERE amount IS NULL;
        INSERT INTO #err SELECT 'INV_VENC_NULO', 'invoices', _row_id, _source_file, _source_line, invoice_id, NULL
        FROM #inv WHERE due_date IS NULL;
        INSERT INTO #err SELECT 'INV_DUPLICADO_ID', 'invoices', _row_id, _source_file, _source_line, invoice_id,
               CONCAT(N'aparición ', nro_id)
        FROM #inv WHERE invoice_id IS NOT NULL AND nro_id > 1;
        -- Duplicado lógico: misma factura del proveedor con OTRO id interno (se queda la primera).
        INSERT INTO #err SELECT 'INV_DUPLICADO_NUMERO', 'invoices', _row_id, _source_file, _source_line, invoice_id,
               CONCAT(counterparty_id, N' ', invoice_number)
        FROM #inv WHERE invoice_number IS NOT NULL AND nro_numero > 1 AND nro_id = 1;
        INSERT INTO #err SELECT 'INV_MONTO_FORMATO', 'invoices', _row_id, _source_file, _source_line, invoice_id, amount
        FROM #inv WHERE amount IS NOT NULL AND monto IS NULL;
        INSERT INTO #err SELECT 'INV_FECHA_INVALIDA', 'invoices', _row_id, _source_file, _source_line, invoice_id,
               CONCAT(issue_date, N' / ', due_date)
        FROM #inv WHERE f_emision IS NULL OR (due_date IS NOT NULL AND f_venc IS NULL);
        INSERT INTO #err SELECT 'INV_MONEDA_INVALIDA', 'invoices', _row_id, _source_file, _source_line, invoice_id, currency
        FROM #inv WHERE currency IS NULL OR currency NOT IN (SELECT codigo_iso FROM #monedas);
        INSERT INTO #err SELECT 'INV_MONTO_NO_POSITIVO', 'invoices', _row_id, _source_file, _source_line, invoice_id, amount
        FROM #inv WHERE monto <= 0;
        INSERT INTO #err SELECT 'INV_VENC_ANTES_EMISION', 'invoices', _row_id, _source_file, _source_line, invoice_id,
               CONCAT(issue_date, N' > ', due_date)
        FROM #inv WHERE f_venc < f_emision;
        INSERT INTO #err SELECT 'INV_CONTRAPARTE_INEXISTENTE', 'invoices', _row_id, _source_file, _source_line,
               invoice_id, counterparty_id
        FROM #inv WHERE counterparty_id IS NULL OR counterparty_id NOT IN (SELECT counterparty_id FROM #cps);

        /* ------------------------------------------------ pagos */
        SELECT s._row_id, s._source_file, s._source_line, s.payment_id, s.payment_reference, s.invoice_id,
               s.counterparty_id, s.account_id, s.currency, s.amount, s.payment_date,
               TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto, TRY_CONVERT(DATE, s.payment_date, 23) AS fecha,
               ROW_NUMBER() OVER (PARTITION BY s.payment_id ORDER BY s._row_id) AS nro,
               fi.currency AS moneda_factura, fi.invoice_id AS factura_encontrada, cu.currency AS moneda_cuenta
        INTO #pag
        FROM stg.payments s
        LEFT JOIN #inv fi ON fi.invoice_id = s.invoice_id AND fi.nro_id = 1
        LEFT JOIN #cuentas cu ON cu.account_id = s.account_id;

        INSERT INTO #err SELECT 'PAG_DUPLICADO', 'payments', _row_id, _source_file, _source_line, payment_id,
               CONCAT(N'aparición ', nro)
        FROM #pag WHERE payment_id IS NOT NULL AND nro > 1;
        INSERT INTO #err SELECT 'PAG_CONTRAPARTE_NULA', 'payments', _row_id, _source_file, _source_line, payment_id, NULL
        FROM #pag WHERE counterparty_id IS NULL;
        INSERT INTO #err SELECT 'PAG_FECHA_INVALIDA', 'payments', _row_id, _source_file, _source_line, payment_id, payment_date
        FROM #pag WHERE fecha IS NULL;
        INSERT INTO #err SELECT 'PAG_MONEDA_INVALIDA', 'payments', _row_id, _source_file, _source_line, payment_id, currency
        FROM #pag WHERE currency IS NULL OR currency NOT IN (SELECT codigo_iso FROM #monedas);
        INSERT INTO #err SELECT 'PAG_FECHA_FUTURA', 'payments', _row_id, _source_file, _source_line, payment_id,
               CONCAT(payment_date, N' > corte ', CONVERT(CHAR(10), @fecha_corte, 23))
        FROM #pag WHERE fecha > @fecha_corte;
        INSERT INTO #err SELECT 'PAG_MONTO_NO_POSITIVO', 'payments', _row_id, _source_file, _source_line, payment_id, amount
        FROM #pag WHERE monto IS NULL OR monto <= 0;
        INSERT INTO #err SELECT 'PAG_FACTURA_INEXISTENTE', 'payments', _row_id, _source_file, _source_line, payment_id, invoice_id
        FROM #pag WHERE factura_encontrada IS NULL;
        INSERT INTO #err SELECT 'PAG_CONTRAPARTE_INEXISTENTE', 'payments', _row_id, _source_file, _source_line,
               payment_id, counterparty_id
        FROM #pag WHERE counterparty_id IS NOT NULL AND counterparty_id NOT IN (SELECT counterparty_id FROM #cps);
        INSERT INTO #err SELECT 'PAG_CUENTA_INEXISTENTE', 'payments', _row_id, _source_file, _source_line, payment_id, account_id
        FROM #pag WHERE moneda_cuenta IS NULL;
        -- Solo con moneda válida (si el código es basura ya lo marcó PAG_MONEDA_INVALIDA).
        INSERT INTO #err SELECT 'PAG_MONEDA_INCONSISTENTE', 'payments', _row_id, _source_file, _source_line, payment_id,
               CONCAT(N'pago ', currency, N' / factura ', moneda_factura, N' / cuenta ', moneda_cuenta)
        FROM #pag WHERE currency IN (SELECT codigo_iso FROM #monedas)
                    AND (currency <> moneda_factura OR currency <> moneda_cuenta);

        /* ------------------------------------------------ cobranzas */
        SELECT s._row_id, s._source_file, s._source_line, s.collection_id, s.collection_reference, s.invoice_id,
               s.counterparty_id, s.account_id, s.currency, s.amount, s.collection_date,
               TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto, TRY_CONVERT(DATE, s.collection_date, 23) AS fecha,
               ROW_NUMBER() OVER (PARTITION BY s.collection_id ORDER BY s._row_id) AS nro,
               fi.currency AS moneda_factura, fi.invoice_id AS factura_encontrada, cu.currency AS moneda_cuenta
        INTO #cob
        FROM stg.collections s
        LEFT JOIN #inv fi ON fi.invoice_id = s.invoice_id AND fi.nro_id = 1
        LEFT JOIN #cuentas cu ON cu.account_id = s.account_id;

        INSERT INTO #err SELECT 'COB_DUPLICADO', 'collections', _row_id, _source_file, _source_line, collection_id,
               CONCAT(N'aparición ', nro)
        FROM #cob WHERE collection_id IS NOT NULL AND nro > 1;
        INSERT INTO #err SELECT 'COB_MONEDA_NULA', 'collections', _row_id, _source_file, _source_line, collection_id, NULL
        FROM #cob WHERE currency IS NULL;
        INSERT INTO #err SELECT 'COB_FECHA_INVALIDA', 'collections', _row_id, _source_file, _source_line, collection_id,
               collection_date
        FROM #cob WHERE fecha IS NULL;
        INSERT INTO #err SELECT 'COB_MONEDA_INVALIDA', 'collections', _row_id, _source_file, _source_line, collection_id, currency
        FROM #cob WHERE currency IS NOT NULL AND currency NOT IN (SELECT codigo_iso FROM #monedas);
        INSERT INTO #err SELECT 'COB_MONTO_NO_POSITIVO', 'collections', _row_id, _source_file, _source_line, collection_id, amount
        FROM #cob WHERE monto IS NULL OR monto <= 0;
        INSERT INTO #err SELECT 'COB_FACTURA_INEXISTENTE', 'collections', _row_id, _source_file, _source_line,
               collection_id, invoice_id
        FROM #cob WHERE factura_encontrada IS NULL;
        INSERT INTO #err SELECT 'COB_CONTRAPARTE_INEXISTENTE', 'collections', _row_id, _source_file, _source_line,
               collection_id, counterparty_id
        FROM #cob WHERE counterparty_id IS NULL OR counterparty_id NOT IN (SELECT counterparty_id FROM #cps);
        INSERT INTO #err SELECT 'COB_MONEDA_INCONSISTENTE', 'collections', _row_id, _source_file, _source_line, collection_id,
               CONCAT(N'cobranza ', currency, N' / factura ', moneda_factura, N' / cuenta ', moneda_cuenta)
        FROM #cob WHERE currency IN (SELECT codigo_iso FROM #monedas)
                    AND (currency <> moneda_factura OR currency <> moneda_cuenta);

        /* ------------------------------------------------ extracto bancario */
        SELECT s._row_id, s._source_file, s._source_line, s.statement_line_id, s.account_number, s.currency, s.amount,
               s.booking_date, s.value_date, s.bank_tx_code, s.description,
               TRY_CONVERT(DECIMAL(19,2), s.amount) AS monto, TRY_CONVERT(DATE, s.booking_date, 23) AS f_imp,
               TRY_CONVERT(DATE, s.value_date, 23) AS f_valor,
               ROW_NUMBER() OVER (PARTITION BY s.statement_line_id ORDER BY s._row_id) AS nro,
               cu.account_id AS cuenta_id, cu.currency AS moneda_cuenta
        INTO #ext
        FROM stg.bank_statements s
        LEFT JOIN #cuentas cu ON cu.account_number = s.account_number;

        INSERT INTO #err SELECT 'EXT_DUPLICADO', 'bank_statements', _row_id, _source_file, _source_line, statement_line_id,
               CONCAT(N'aparición ', nro)
        FROM #ext WHERE statement_line_id IS NOT NULL AND nro > 1;
        INSERT INTO #err SELECT 'EXT_MONTO_NULO', 'bank_statements', _row_id, _source_file, _source_line, statement_line_id, amount
        FROM #ext WHERE monto IS NULL OR monto = 0;
        INSERT INTO #err SELECT 'EXT_FECHA_INVALIDA', 'bank_statements', _row_id, _source_file, _source_line,
               statement_line_id, CONCAT(booking_date, N' / ', value_date)
        FROM #ext WHERE f_imp IS NULL OR f_valor IS NULL;
        INSERT INTO #err SELECT 'EXT_CUENTA_DESCONOCIDA', 'bank_statements', _row_id, _source_file, _source_line,
               statement_line_id, account_number
        FROM #ext WHERE cuenta_id IS NULL;
        INSERT INTO #err SELECT 'EXT_MONEDA_INCONSISTENTE', 'bank_statements', _row_id, _source_file, _source_line,
               statement_line_id, CONCAT(N'línea ', currency, N' / cuenta ', moneda_cuenta)
        FROM #ext WHERE cuenta_id IS NOT NULL AND (currency IS NULL OR currency <> moneda_cuenta);

        /* ------------------------------------------------ consistencia ERP vs. banco
           (PAG_SIN_EXTRACTO, COB_SIN_EXTRACTO, EXT_SIN_MATCH) se evalúan DESPUÉS de la
           conciliación, en 04_usp_dq_controles_post_carga.sql: usan su emparejamiento 1 a 1.
           Una búsqueda de "¿existe algún movimiento parecido?" acá perdía detecciones con
           volumen alto (a escala 20, otro movimiento de la misma cuenta coincidía de casualidad). */

        /* ------------------------------------------------ tipos de cambio */
        SELECT s._row_id, s._source_file, s._source_line, s.rate_date, s.currency, s.rate_per_usd,
               TRY_CONVERT(DATE, s.rate_date, 23) AS fecha, TRY_CONVERT(DECIMAL(19,6), s.rate_per_usd) AS tc,
               ROW_NUMBER() OVER (PARTITION BY s.rate_date, s.currency ORDER BY s._row_id) AS nro
        INTO #tc FROM stg.fx_rates s;

        INSERT INTO #err SELECT 'TC_NULO', 'fx_rates', _row_id, _source_file, _source_line,
               CONCAT(rate_date, N'|', currency), rate_per_usd
        FROM #tc WHERE tc IS NULL OR tc <= 0;
        -- Salto aislado: más de 50% contra el día hábil anterior Y contra el siguiente (LAG/LEAD).
        -- Un cambio real de nivel (devaluación) se mueve contra uno solo de los dos vecinos.
        WITH v AS (
            SELECT *, LAG(tc) OVER (PARTITION BY currency ORDER BY fecha) AS ant,
                      LEAD(tc) OVER (PARTITION BY currency ORDER BY fecha) AS sig
            FROM #tc WHERE tc > 0 AND fecha IS NOT NULL AND nro = 1
        )
        INSERT INTO #err SELECT 'TC_FUERA_DE_RANGO', 'fx_rates', _row_id, _source_file, _source_line,
               CONCAT(rate_date, N'|', currency), CONCAT(tc, N' (anterior ', ant, N', siguiente ', sig, N')')
        FROM v
        WHERE (ant IS NOT NULL OR sig IS NOT NULL)
          AND (ant IS NULL OR tc / ant > 1.5 OR tc / ant < 1 / 1.5)
          AND (sig IS NULL OR tc / sig > 1.5 OR tc / sig < 1 / 1.5);
        -- Faltantes: días hábiles del calendario sin ninguna fila para la moneda (no hay fila de
        -- staging a la que apuntar: se informa por clave fecha|moneda).
        SELECT d.fecha, m.currency INTO #tc_esperadas
        FROM dw.dim_fecha d
        CROSS JOIN (SELECT DISTINCT currency FROM #tc WHERE currency IN (SELECT codigo_iso FROM #monedas)) m
        WHERE d.es_habil = 1 AND d.fecha BETWEEN (SELECT MIN(fecha) FROM #tc) AND (SELECT MAX(fecha) FROM #tc);
        INSERT INTO #evaluadas SELECT 'TC_FALTANTE', COUNT(*) FROM #tc_esperadas;
        INSERT INTO #err SELECT 'TC_FALTANTE', 'fx_rates', NULL, NULL, NULL,
               CONCAT(CONVERT(CHAR(10), x.fecha, 23), N'|', x.currency), NULL
        FROM #tc_esperadas x
        WHERE NOT EXISTS (SELECT 1 FROM #tc t WHERE t.fecha = x.fecha AND t.currency = x.currency);

        /* ------------------------------------------------ maestro de contrapartes */
        INSERT INTO #err SELECT 'CP_TAX_ID_NULO', 'counterparties', _row_id, _source_file, _source_line, counterparty_id, NULL
        FROM stg.counterparties WHERE tax_id IS NULL;
        INSERT INTO #err SELECT 'CP_EMAIL_INVALIDO', 'counterparties', _row_id, _source_file, _source_line, counterparty_id, email
        FROM stg.counterparties
        WHERE email IS NOT NULL AND (email NOT LIKE N'%_@_%._%' OR email LIKE N'% %' OR email LIKE N'%@%@%');
        -- Se marcan TODAS las contrapartes que comparten el CUIT/CNPJ: no se puede saber cuál
        -- es la correcta sin revisar los papeles (decide una persona).
        INSERT INTO #err SELECT 'CP_TAX_ID_DUPLICADO', 'counterparties', c._row_id, c._source_file, c._source_line,
               c.counterparty_id, c.tax_id
        FROM stg.counterparties c
        JOIN (SELECT snapshot_date, tax_id FROM stg.counterparties WHERE tax_id IS NOT NULL
              GROUP BY snapshot_date, tax_id HAVING COUNT(DISTINCT counterparty_id) > 1) d
          ON d.snapshot_date = c.snapshot_date AND d.tax_id = c.tax_id;

        /* ------------------------------------------------ resultados y cuarentena */
        CREATE TABLE #conteo (tabla NVARCHAR(128) COLLATE DATABASE_DEFAULT PRIMARY KEY, filas INT NOT NULL);
        INSERT INTO #conteo VALUES (N'invoices', (SELECT COUNT(*) FROM #inv)), (N'payments', (SELECT COUNT(*) FROM #pag)),
               (N'collections', (SELECT COUNT(*) FROM #cob)), (N'bank_statements', (SELECT COUNT(*) FROM #ext)),
               (N'fx_rates', (SELECT COUNT(*) FROM #tc)), (N'counterparties', (SELECT COUNT(*) FROM stg.counterparties));
        SELECT @evaluadas = SUM(filas) FROM #conteo;

        -- Filas que van a cuarentena: las que violan al menos una regla ERROR activa.
        SELECT e.tabla, e.stg_row_id, STRING_AGG(e.regla_id, ',') WITHIN GROUP (ORDER BY e.regla_id) AS reglas
        INTO #marcadas
        FROM (SELECT DISTINCT tabla, stg_row_id, regla_id FROM #err) e
        JOIN audit.dq_reglas r ON r.regla_id = e.regla_id AND r.severidad = 'ERROR' AND r.activa = 1
        WHERE e.stg_row_id IS NOT NULL
        GROUP BY e.tabla, e.stg_row_id;

        BEGIN TRANSACTION;

        INSERT INTO audit.dq_resultados (ejecucion_id, regla_id, tabla, categoria, severidad, filas_evaluadas, filas_con_error)
        SELECT @ejecucion_id, r.regla_id, r.tabla, r.categoria, r.severidad, COALESCE(ev.filas, c.filas, 0), ISNULL(n.n, 0)
        FROM audit.dq_reglas r
        LEFT JOIN #evaluadas ev ON ev.regla_id = r.regla_id
        LEFT JOIN #conteo c ON c.tabla = r.tabla
        LEFT JOIN (SELECT regla_id, COUNT(*) AS n FROM #err GROUP BY regla_id) n ON n.regla_id = r.regla_id
        WHERE r.momento = 'PRE_CARGA' AND r.activa = 1;

        INSERT INTO audit.dq_errores (ejecucion_id, regla_id, tabla, stg_row_id, source_file, source_line, clave, valor)
        SELECT @ejecucion_id, e.regla_id, e.tabla, e.stg_row_id, e.source_file, e.source_line, e.clave, e.valor
        FROM #err e JOIN audit.dq_reglas r ON r.regla_id = e.regla_id AND r.activa = 1;

        /* Sincronización de cada cuarentena (SQL estático a propósito, ver 01_dq_estructura.sql):
           actualizar las que siguen marcadas, insertar las nuevas, liberar las que ya no fallan. */
        -- invoices
        UPDATE q SET reglas = m.reglas, estado = 'EN_CUARENTENA', ultima_ejecucion_id = @ejecucion_id, fecha_liberacion_utc = NULL
        FROM audit.cuarentena_invoices q JOIN #marcadas m ON m.tabla = N'invoices' AND m.stg_row_id = q.stg_row_id;
        INSERT INTO audit.cuarentena_invoices (stg_row_id, _source_file, _source_line, invoice_id, invoice_number,
                    counterparty_id, invoice_type, issue_date, due_date, currency, amount, description, reglas, estado,
                    primera_ejecucion_id, ultima_ejecucion_id)
        SELECT s._row_id, s._source_file, s._source_line, s.invoice_id, s.invoice_number, s.counterparty_id,
               s.invoice_type, s.issue_date, s.due_date, s.currency, s.amount, s.description, m.reglas, 'EN_CUARENTENA',
               @ejecucion_id, @ejecucion_id
        FROM stg.invoices s JOIN #marcadas m ON m.tabla = N'invoices' AND m.stg_row_id = s._row_id
        WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_invoices q WHERE q.stg_row_id = s._row_id);
        SET @nuevas += @@ROWCOUNT;
        UPDATE q SET estado = 'LIBERADA', fecha_liberacion_utc = SYSUTCDATETIME(), ultima_ejecucion_id = @ejecucion_id
        FROM audit.cuarentena_invoices q
        WHERE q.estado = 'EN_CUARENTENA'
          AND NOT EXISTS (SELECT 1 FROM #marcadas m WHERE m.tabla = N'invoices' AND m.stg_row_id = q.stg_row_id);
        SET @liberadas += @@ROWCOUNT;

        -- payments
        UPDATE q SET reglas = m.reglas, estado = 'EN_CUARENTENA', ultima_ejecucion_id = @ejecucion_id, fecha_liberacion_utc = NULL
        FROM audit.cuarentena_payments q JOIN #marcadas m ON m.tabla = N'payments' AND m.stg_row_id = q.stg_row_id;
        INSERT INTO audit.cuarentena_payments (stg_row_id, _source_file, _source_line, payment_id, payment_reference,
                    invoice_id, counterparty_id, account_id, payment_date, currency, amount, payment_method, reglas, estado,
                    primera_ejecucion_id, ultima_ejecucion_id)
        SELECT s._row_id, s._source_file, s._source_line, s.payment_id, s.payment_reference, s.invoice_id,
               s.counterparty_id, s.account_id, s.payment_date, s.currency, s.amount, s.payment_method, m.reglas,
               'EN_CUARENTENA', @ejecucion_id, @ejecucion_id
        FROM stg.payments s JOIN #marcadas m ON m.tabla = N'payments' AND m.stg_row_id = s._row_id
        WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_payments q WHERE q.stg_row_id = s._row_id);
        SET @nuevas += @@ROWCOUNT;
        UPDATE q SET estado = 'LIBERADA', fecha_liberacion_utc = SYSUTCDATETIME(), ultima_ejecucion_id = @ejecucion_id
        FROM audit.cuarentena_payments q
        WHERE q.estado = 'EN_CUARENTENA'
          AND NOT EXISTS (SELECT 1 FROM #marcadas m WHERE m.tabla = N'payments' AND m.stg_row_id = q.stg_row_id);
        SET @liberadas += @@ROWCOUNT;

        -- collections
        UPDATE q SET reglas = m.reglas, estado = 'EN_CUARENTENA', ultima_ejecucion_id = @ejecucion_id, fecha_liberacion_utc = NULL
        FROM audit.cuarentena_collections q JOIN #marcadas m ON m.tabla = N'collections' AND m.stg_row_id = q.stg_row_id;
        INSERT INTO audit.cuarentena_collections (stg_row_id, _source_file, _source_line, collection_id,
                    collection_reference, invoice_id, counterparty_id, account_id, collection_date, currency, amount,
                    collection_method, reglas, estado, primera_ejecucion_id, ultima_ejecucion_id)
        SELECT s._row_id, s._source_file, s._source_line, s.collection_id, s.collection_reference, s.invoice_id,
               s.counterparty_id, s.account_id, s.collection_date, s.currency, s.amount, s.collection_method, m.reglas,
               'EN_CUARENTENA', @ejecucion_id, @ejecucion_id
        FROM stg.collections s JOIN #marcadas m ON m.tabla = N'collections' AND m.stg_row_id = s._row_id
        WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_collections q WHERE q.stg_row_id = s._row_id);
        SET @nuevas += @@ROWCOUNT;
        UPDATE q SET estado = 'LIBERADA', fecha_liberacion_utc = SYSUTCDATETIME(), ultima_ejecucion_id = @ejecucion_id
        FROM audit.cuarentena_collections q
        WHERE q.estado = 'EN_CUARENTENA'
          AND NOT EXISTS (SELECT 1 FROM #marcadas m WHERE m.tabla = N'collections' AND m.stg_row_id = q.stg_row_id);
        SET @liberadas += @@ROWCOUNT;

        -- bank_statements
        UPDATE q SET reglas = m.reglas, estado = 'EN_CUARENTENA', ultima_ejecucion_id = @ejecucion_id, fecha_liberacion_utc = NULL
        FROM audit.cuarentena_bank_statements q JOIN #marcadas m ON m.tabla = N'bank_statements' AND m.stg_row_id = q.stg_row_id;
        INSERT INTO audit.cuarentena_bank_statements (stg_row_id, _source_file, _source_line, statement_line_id,
                    account_number, booking_date, value_date, currency, amount, bank_tx_code, description, bank_reference,
                    reglas, estado, primera_ejecucion_id, ultima_ejecucion_id)
        SELECT s._row_id, s._source_file, s._source_line, s.statement_line_id, s.account_number, s.booking_date,
               s.value_date, s.currency, s.amount, s.bank_tx_code, s.description, s.bank_reference, m.reglas,
               'EN_CUARENTENA', @ejecucion_id, @ejecucion_id
        FROM stg.bank_statements s JOIN #marcadas m ON m.tabla = N'bank_statements' AND m.stg_row_id = s._row_id
        WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_bank_statements q WHERE q.stg_row_id = s._row_id);
        SET @nuevas += @@ROWCOUNT;
        UPDATE q SET estado = 'LIBERADA', fecha_liberacion_utc = SYSUTCDATETIME(), ultima_ejecucion_id = @ejecucion_id
        FROM audit.cuarentena_bank_statements q
        WHERE q.estado = 'EN_CUARENTENA'
          AND NOT EXISTS (SELECT 1 FROM #marcadas m WHERE m.tabla = N'bank_statements' AND m.stg_row_id = q.stg_row_id);
        SET @liberadas += @@ROWCOUNT;

        -- fx_rates
        UPDATE q SET reglas = m.reglas, estado = 'EN_CUARENTENA', ultima_ejecucion_id = @ejecucion_id, fecha_liberacion_utc = NULL
        FROM audit.cuarentena_fx_rates q JOIN #marcadas m ON m.tabla = N'fx_rates' AND m.stg_row_id = q.stg_row_id;
        INSERT INTO audit.cuarentena_fx_rates (stg_row_id, _source_file, _source_line, rate_date, currency, rate_per_usd,
                    source, reglas, estado, primera_ejecucion_id, ultima_ejecucion_id)
        SELECT s._row_id, s._source_file, s._source_line, s.rate_date, s.currency, s.rate_per_usd, s.source, m.reglas,
               'EN_CUARENTENA', @ejecucion_id, @ejecucion_id
        FROM stg.fx_rates s JOIN #marcadas m ON m.tabla = N'fx_rates' AND m.stg_row_id = s._row_id
        WHERE NOT EXISTS (SELECT 1 FROM audit.cuarentena_fx_rates q WHERE q.stg_row_id = s._row_id);
        SET @nuevas += @@ROWCOUNT;
        UPDATE q SET estado = 'LIBERADA', fecha_liberacion_utc = SYSUTCDATETIME(), ultima_ejecucion_id = @ejecucion_id
        FROM audit.cuarentena_fx_rates q
        WHERE q.estado = 'EN_CUARENTENA'
          AND NOT EXISTS (SELECT 1 FROM #marcadas m WHERE m.tabla = N'fx_rates' AND m.stg_row_id = q.stg_row_id);
        SET @liberadas += @@ROWCOUNT;

        COMMIT;

        SET @vigentes = (SELECT COUNT(*) FROM #marcadas);
        SELECT @msg_ok = CONCAT(N'corte=', CONVERT(CHAR(10), @fecha_corte, 23), N', errores=', COUNT(*),
                                N' (ERROR=', SUM(IIF(r.severidad = 'ERROR', 1, 0)),
                                N', ADVERTENCIA=', SUM(IIF(r.severidad = 'ADVERTENCIA', 1, 0)),
                                N'), cuarentena: vigentes=', @vigentes, N', nuevas=', @nuevas, N', liberadas=', @liberadas)
        FROM #err e JOIN audit.dq_reglas r ON r.regla_id = e.regla_id AND r.activa = 1;
        -- En el log: leídas = filas de staging evaluadas; descartadas = filas que quedan en cuarentena.
        EXEC audit.usp_etl_log_fin @log_id, 'OK', @evaluadas, @nuevas, @liberadas, @vigentes, 0, @msg_ok;
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
