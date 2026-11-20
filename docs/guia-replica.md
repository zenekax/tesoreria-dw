# Guía para replicar el proyecto paso a paso

Esta guía es para reconstruir `tesoreria-dw` **escribiendo vos el código**, fase por fase, hasta poder explicar cada
línea en una entrevista. El repo original funciona como **solucionario**: abrilo solo después de intentar cada paso.

## Cómo usar esta guía

1. **Carpeta nueva**, al lado del original:

   ```bash
   mkdir ~/Desktop/tesoreria-dw-replica && cd ~/Desktop/tesoreria-dw-replica && git init
   ```

2. **Copiá del original solo el "contrato" y el corrector:**
   - `CLAUDE.md`, `docs/REQUISITOS.md` y `.gitignore`: las reglas del juego.
   - `python/tests/`: **los tests son tu corrector**. Si un test pasa, ese paso está bien.
   - `docker-compose.yml`, `.env.example`, `scripts/run_sql.sh` y `scripts/setup_python.sh`: infraestructura, no es lo que se evalúa.

3. **Elegí el nivel:**
   - **Nivel A (recomendado)**: copiá también `python/generar_datos.py`, `python/cargar_staging.py`, `python/db.py` y
     `python/ejecutar_sql.py`, y escribí **vos todo el SQL** (Fases 2 a 9). Es lo que más te van a preguntar.
   - **Nivel B**: escribí también el Python (Fases 1 y 2).

4. **Usá los mismos nombres** de tablas, columnas y procedimientos que el original: los tests los usan. La lista está
   al principio de cada fase.

5. Antes de cada fase: leé su sección de [`bitacora-fases.md`](bitacora-fases.md) y el doc de la fase. Después de cada fase:
   **explicalo en voz alta** con las preguntas del final. Si no te sale, ahí está lo que falta repasar.

6. Para la corrida de los tests, un solo módulo por vez:

   ```bash
   .venv/bin/python -m pytest python/tests/test_modelo_dw.py -q
   ```

> El SQL lo podés escribir en VS Code con la extensión **mssql** (conexión a `localhost,1433`, usuario `sa` y la clave
> de tu `.env`) y desplegarlo con `scripts/run_sql.sh <archivo>`.

---

## Fase 0: entorno (1 a 2 horas)

**Objetivo:** SQL Server 2022 en Docker, Python con `pyodbc` y Git.

**Conceptos:**
- Un contenedor es una "máquina" descartable; el **volumen** es el disco que sobrevive cuando lo borrás.
- `platform: linux/amd64`: no hay SQL Server para chips Apple, así que corre emulado.
- Las credenciales van **solo** en `.env` (ignorado por Git).

**Pasos:**
1. Levantá el contenedor con `docker compose up -d --wait` y entrá con el `sqlcmd` del contenedor.
2. Escribí `sql/00_setup/01_crear_base_y_schemas.sql`: la base con collation explícita, recovery SIMPLE y los schemas
   `stg`, `dw`, `audit` y `sec`. Tiene que poder correr **dos veces seguidas** (pista: `IF DB_ID(...) IS NULL` y
   `EXEC('CREATE SCHEMA ...')`, porque `CREATE SCHEMA` tiene que ir solo en su lote).
3. Escribí `sql/00_setup/02_usuario_etl.sql`: login + usuario + `rol_etl` con `GRANT ... ON SCHEMA::stg`.

**Listo cuando:** `python python/verificar_entorno.py` dice OK y el script de setup corre dos veces sin error.

**Trampas conocidas:** el driver ODBC necesita OpenSSL 3 (ver README); el pooling de ODBC hereda transacciones (en `db.py`, `pyodbc.pooling = False`).

**Explicalo:** ¿por qué schemas separados? ¿Qué es mínimo privilegio y cómo se ve en el login del ETL?

---

## Fase 1: datos sintéticos (Nivel B: 1 a 2 días; Nivel A: leer el código en 1 hora)

**Objetivo:** entender qué datos hay y qué errores tienen. Leé [`datos-sinteticos.md`](datos-sinteticos.md).

**Conceptos:** seed fija (reproducibilidad); **manifiesto exacto** de errores, que es la planilla de control contra la que se audita.

**Pasos (Nivel B):** generar maestros → tipos de cambio → facturas → pagos y cobranzas → líneas del banco → errores
"de lo que pasó en el banco" → saldos → errores "de cómo viene escrito el dato" → escribir CSV mensuales.

**Listo cuando:** pasa `test_generar_datos.py`.

**Explicalo:** ¿por qué hay dos momentos para inyectar errores? ¿Qué demuestra el test "toda fila fuera del manifiesto está limpia"?

---

## Fase 2: staging (medio día)

**Archivos:** `sql/01_staging/01_tablas_staging.sql`. Tablas `stg.banks`, `bank_accounts`, `counterparties`, `fx_rates`,
`invoices`, `payments`, `collections`, `bank_statements` y `bank_balances`, más `audit.carga_staging`.

**Conceptos:** staging = **extracto crudo abrochado en la carpeta**. Todo en `NVARCHAR` y sin claves de negocio: si
`amount` fuera `DECIMAL`, el `1.234,56` rompería la carga y el error nunca llegaría a la Fase 5.

**Pasos:**
1. Cada tabla con las 5 columnas técnicas (`_row_id` IDENTITY, `_carga_id`, `_source_file`, `_source_line`,
   `_loaded_at`) y las de negocio en el **mismo orden** que el CSV.
2. `audit.carga_staging` con un CHECK sobre los valores posibles de `resultado`.
3. Un índice por `(_source_file, _source_line)` en cada tabla (el cargador borra y cuenta "las filas del archivo X").

**Listo cuando:** pasa `test_cargar_staging.py`. Si escribiste el cargador (Nivel B): idempotente por sha256, una
transacción por archivo y `fast_executemany`.

**Explicalo:** ¿qué pasa si el banco manda de nuevo el extracto de marzo corregido? ¿Por qué no hay UNIQUE en `payment_id`?

---

## Fase 3: modelo dimensional (1 día)

**Archivos:** `sql/02_dw/01_dimensiones.sql`, `02_datos_estaticos.sql` y `03_hechos.sql`. Nombres en [`modelo.md`](modelo.md).

**Conceptos** (leelos en `modelo.md` antes de escribir):
- **Grano** de cada hecho; los tres tipos de hecho (transacción, snapshot periódico, snapshot acumulativo).
- Clave surrogate vs. clave natural; miembros `-1` y `-2`.
- **SCD2**: `vigente_desde`, `vigente_hasta`, `es_vigente`, hashes persistidos e índice único filtrado.

**Pasos:**
1. Dimensiones. Empezá por `dim_fecha` con `GENERATE_SERIES`: día de la semana sin depender de `SET DATEFIRST`
   (`DATEDIFF(DAY, '19000101', fecha) % 7 + 1`) y último hábil del mes con `MAX(...) OVER (PARTITION BY anio, mes)`.
2. Datos estáticos con el patrón "insertar lo que falta + actualizar lo que cambió" y `SET IDENTITY_INSERT` para las filas -1.
3. Hechos con sus FK y CHECK. El más difícil: los CHECK de `fact_conciliacion` (el estado tiene que ser coherente con
   lo que hay en la fila). Recordá que **T-SQL no compara booleanos**: `(A IS NULL) = (B IN (...))` no existe; se escribe con OR.

**Listo cuando:** pasa `test_modelo_dw.py` (56 tests con control positivo).

**Explicalo:** ¿por qué `dim_fecha` usa clave AAAAMMDD y no IDENTITY? ¿Por qué un índice único **filtrado** para la versión vigente?

---

## Fase 4: ETL en T-SQL (2 a 3 días: la más importante)

**Archivos:** `sql/03_etl/01_auditoria_etl.sql` a `05_usp_run_etl.sql` (más `06_usp_conciliar.sql` en la Fase 6).

**Conceptos:**
- Patrón de cada `usp_load_*`: log de inicio **fuera** de la transacción → candidatos tipados con `TRY_CONVERT` y
  motivo de descarte → `BEGIN TRAN` → UPDATE de lo que cambió → INSERT de lo nuevo → marca de agua → `COMMIT` → log de fin.
- `SET XACT_ABORT ON` + `TRY/CATCH` + `THROW` para relanzar el error.
- `WHERE EXISTS (SELECT origen EXCEPT SELECT destino)` para detectar cambios con NULL = NULL.
- Lookup SCD2 "punto en el tiempo" y último tipo de cambio con `OUTER APPLY (SELECT TOP 1 ... ORDER BY fecha DESC)`.
- Dedup con `ROW_NUMBER() OVER (PARTITION BY clave ORDER BY _row_id)` calculado **antes** de filtrar por la ventana.

**Pasos:**
1. Empezá por `dw.usp_load_fact_tipo_cambio`: es el más corto y tiene todo el patrón.
2. Después `dim_banco_cuenta` con **MERGE**, y `dim_contraparte` (SCD2) con un cursor sobre los snapshots **en orden**.
3. Copiá el patrón a facturas, pagos, cobranzas, movimientos y saldos.
4. El orquestador `dw.usp_run_etl`: una transacción por paso, fail fast y ventana incremental.

**Listo cuando:** pasa `test_etl.py`. El test clave es "incremental por partes = carga completa".

**Trampas conocidas:**
- Con el usuario de mínimo privilegio, `OBJECT_NAME(@@PROCID)` da NULL: el nombre del procedimiento va como texto fijo.
- Una fecha futura no puede mover la marca de agua.
- Las `#temporales` creadas con `CREATE TABLE` necesitan `COLLATE DATABASE_DEFAULT`.

**Explicalo:** ¿por qué una transacción por paso y no una sola? ¿Por qué MERGE en un lugar y UPDATE + INSERT en otro?

---

## Fase 5: calidad de datos (2 días)

**Archivos:** `sql/04_quality/01` a `04`. Leé [`calidad-de-datos.md`](calidad-de-datos.md).

**Conceptos:** regla set-based = `INSERT INTO #err SELECT ... WHERE <la viola>`; ERROR va a cuarentena y ADVERTENCIA se
informa; cuarentena con estados (nunca se borra); totales de control.

**Pasos:**
1. Estructura: `dq_reglas`, `dq_resultados`, `dq_errores` y las cuarentenas (generadas con SQL dinámico seguro desde `sys.columns`).
2. `audit.usp_dq_validar_staging`: tipar staging una vez y escribir las reglas tabla por tabla. Arrancá por las fáciles
   (nulos, montos ≤ 0), después los duplicados y por último la integridad.
3. Modificar los `usp_load_*` para excluir lo que está en cuarentena y retirar del DW lo que ya había entrado.
4. `audit.usp_dq_controles_post_carga`: totales de control y las 3 reglas ERP vs. banco **sobre la conciliación 1 a 1**.

**Listo cuando:** pasa `test_calidad.py` (recall 100% y falsos positivos explicados).

**Trampas conocidas:**
- No culpar a un comprobante por el error de otro.
- Las reglas de "existe algo parecido" fallan con volumen: usá emparejamiento 1 a 1.
- `stg_row_id` es único **dentro** de cada tabla, no entre tablas.

**Explicalo:** ¿cómo sabés que detectás todo? ¿Qué diferencia hay entre precisión y recall, con un ejemplo del proyecto?

---

## Fase 6: conciliación y análisis (2 días)

**Archivos:** `sql/03_etl/06_usp_conciliar.sql` y `sql/06_queries/01` a `07`.

**Conceptos:** emparejamiento 1 a 1 por "mejor mutuo" con `ROW_NUMBER` desde los dos lados, en vueltas; `PIVOT`;
`NTILE`; `LAG`; `SUM() OVER (ROWS UNBOUNDED PRECEDING)`; `PERCENTILE_CONT` como window; CTE recursiva con
`MAXRECURSION`; SQL dinámico seguro (lista blanca + `QUOTENAME` + parámetros de `sp_executesql`).

**Pasos:** primero la conciliación (es el corazón de la tesorería); después una consulta por archivo, cada una con su
comentario de **qué pregunta de negocio responde**.

**Listo cuando:** pasa `test_consultas.py` (conciliación 100% contra la verdad).

**Explicalo:** ¿por qué la fecha va antes que la diferencia de importe en el orden de preferencia? ¿Cómo hace el
PIVOT dinámico para no permitir inyección de SQL?

---

## Fase 7: performance (1 día)

**Archivos:** `sql/02_dw/04_indices.sql` y `sql/07_performance/`.

**Pasos:**
1. Generá escala 20 en una base aparte y corré el ETL.
2. Para cada consulta: `SET STATISTICS IO, TIME ON`, plan real (en VS Code: *Explain*), anotar las lecturas.
3. Crear el índice, medir de nuevo y **leer el plan**: ¿pasó de Scan a Seek? ¿Hay *batch mode*?
4. Q2: comprobá que el índice solo no alcanza y reescribí la consulta.

**Listo cuando:** `python python/medir_performance.py --base <tu_base_perf>` y tu tabla se parece a la del original.

**Explicalo:** ¿qué son las lecturas lógicas y por qué son mejor métrica que el tiempo? ¿Cuándo no conviene un índice?

---

## Fase 8: seguridad (medio día)

**Archivos:** `sql/05_security/01` a `04`. Leé [`seguridad.md`](seguridad.md).

**Pasos:** roles y GRANT/DENY por schema → RLS (tabla de asignaciones, función inline SCHEMABINDING, política) →
masking (y `UNMASK` para el ETL) → probar con `EXECUTE AS USER = 'analista_ar'` ... `REVERT`.

**Listo cuando:** pasa `test_seguridad.py`.

**Explicalo:** ¿por qué RLS y no una vista por equipo? ¿Por qué el masking no es suficiente solo?

---

## Fase 9: capa de consumo (medio día + Power BI)

**Archivos:** `sql/08_reporting/01_vistas_rpt.sql`. Guía del tablero en [`powerbi.md`](powerbi.md).

**Listo cuando:** pasa `test_reportes.py` y el tablero muestra los mismos números que las consultas de la Fase 6.

**Explicalo:** ¿por qué vistas y no tablas? ¿Cómo llega la RLS hasta Power BI?

---

## Checklist final para la entrevista

- [ ] Puedo dibujar la arquitectura en un pizarrón (fuentes → stg → calidad → dw → rpt → Power BI).
- [ ] Puedo explicar el grano de cada hecho y por qué la conciliación es un snapshot acumulativo.
- [ ] Puedo escribir de memoria un `usp_load_*` con TRY/CATCH, transacción y log.
- [ ] Puedo explicar SCD2 con el ejemplo del cliente que pasó a riesgo alto en mayo.
- [ ] Puedo contar una optimización con números (Q2) y una que **no** funcionó.
- [ ] Puedo explicar recall vs. precisión con mis reglas de calidad.
- [ ] Puedo mostrar RLS y masking con `EXECUTE AS` en vivo.
- [ ] Respondo las 10 preguntas de [`entrevista.md`](entrevista.md) sin leer.
