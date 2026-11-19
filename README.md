# tesoreria-dw

Data warehouse de tesorería en **SQL Server 2022** para una fintech (ficticia) de pagos
transfronterizos: pagos a proveedores, cobranzas, movimientos bancarios y conciliación
en ARS, USD, BRL, MXN y COP. ETL en Python + T-SQL, control de calidad, seguridad y análisis.

> Todos los datos son **sintéticos**. Proyecto de portfolio.

## Estado

| Fase | Contenido | Estado |
|---|---|---|
| 0 | Entorno: Docker, Python, Git | ✅ |
| 1 | Datos sintéticos con errores inyectados | ✅ |
| 2 | Staging (`stg`) | ✅ |
| 3 | Modelo dimensional (`dw`) | ✅ |
| 4 | ETL en T-SQL | ✅ |
| 5 | Calidad de datos | ✅ |
| 6 | Conciliación y análisis | ⏳ |
| 7 | Performance | ⏳ |
| 8 | Seguridad | ⏳ |
| 9 | Capa de consumo (Power BI) | ⏳ |
| 10 | Cierre | ⏳ |

## Requisitos

- Docker Desktop (en Mac Apple Silicon, SQL Server corre emulado `linux/amd64` vía Rosetta).
- Python 3.12 (probado con 3.12.14; se usa [uv](https://github.com/astral-sh/uv) para el venv, `python -m venv` también sirve).
- Driver ODBC de Microsoft para que Python (`pyodbc`) hable con SQL Server. En Mac:

```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
```

```bash
brew trust --formula microsoft/mssql-release/msodbcsql18 microsoft/mssql-release/mssql-tools18
```

```bash
HOMEBREW_ACCEPT_EULA=Y brew install msodbcsql18 mssql-tools18 openssl@3
```

  - `brew trust`: las versiones nuevas de Homebrew no cargan fórmulas de taps de terceros
    sin confianza explícita. Se confía solo en las dos fórmulas necesarias, no en todo el tap.
  - `HOMEBREW_ACCEPT_EULA=Y` implica aceptar la licencia de Microsoft.
  - **`openssl@3` es necesario**: el ODBC Driver 18.7 busca OpenSSL en `$(brew --prefix)/opt/openssl`,
    que Homebrew ahora apunta a OpenSSL 4.x, y el driver solo soporta hasta 3.0. Sin este arreglo
    falla con *"OpenSSL library could not be loaded"*. `scripts/setup_python.sh` lo resuelve
    solo para el venv del proyecto: `.venv/bin/python` (activado o no, también desde VS Code) se
    relanza con `DYLD_LIBRARY_PATH` hacia `openssl@3` (`scripts/_tdw_openssl.py`), y `source .venv/bin/activate`
    exporta la misma variable para que `sqlcmd` ande en la terminal.

## Cómo levantarlo

```bash
cp .env.example .env   # y cambiar MSSQL_SA_PASSWORD
```

```bash
docker compose up -d --wait
```

```bash
./scripts/setup_python.sh && source .venv/bin/activate
```

Desplegar la base (base, schemas, usuario ETL, staging, modelo dimensional y procedimientos del ETL; idempotente):

```bash
scripts/run_sql.sh
```

Generar los datos sintéticos (12 meses, seed fija, 174 errores inyectados) y cargarlos a staging:

```bash
python python/generar_datos.py
```

```bash
python python/cargar_staging.py
```

Validar la calidad, transformar y cargar el DW (stored procedures; incremental por defecto, `--completa` para reprocesar todo):

```bash
python python/ejecutar_etl.py
```

Correr los tests (los de staging usan una base aparte, `TesoreriaDW_test`, que se crea y se borra):

```bash
python -m pytest python/tests -q
```

Verificar que Python llega a la base:

```bash
python python/verificar_entorno.py
```

## Estructura

```
docker-compose.yml     SQL Server 2022 CU28 (tag fijo), volumen persistente, ./sql montado en /sql
.env.example           plantilla de variables; .env real nunca se commitea
requirements.txt       dependencias Python con versión fija
python/db.py           conexión compartida (lee credenciales de .env)
python/verificar_entorno.py
python/generar_datos.py ERP + bancos sintéticos -> data/ (ver docs/datos-sinteticos.md)
python/cargar_staging.py  CSV -> stg.* con pyodbc (fast_executemany), idempotente por archivo
python/ejecutar_etl.py    dispara dw.usp_run_etl con el usuario de mínimo privilegio
python/tests/          tests del generador y de la carga (integración contra TesoreriaDW_test)
scripts/run_sql.sh     ejecuta los .sql en orden con el sqlcmd del contenedor (variables SQLCMD)
scripts/setup_python.sh venv + dependencias + workaround OpenSSL en Mac (idempotente)
scripts/_tdw_openssl.py  relanzador que instala setup_python.sh en el venv (solo macOS)
sql/00_setup/          base + schemas stg, dw, audit, sec + login tdw_etl / rol_etl
sql/01_staging/        tablas stg.* y bitácora audit.carga_staging
sql/02_dw/              esquema estrella: 5 dimensiones, 7 hechos, calendario y datos de referencia
sql/03_etl/             audit.etl_log, marcas de agua, dw.usp_load_* y el orquestador dw.usp_run_etl
sql/04_quality/         reglas de calidad, resultados, cuarentenas y totales de control
docs/REQUISITOS.md     requisito del puesto -> dónde se demuestra
docs/datos-sinteticos.md  archivos, realismo de tesorería, errores inyectados y decisiones
docs/modelo.md         diagrama, matriz de bus, grano de cada hecho y decisiones de modelado
docs/calidad-de-datos.md  reglas, cuarentena, resultados, recall/precisión y decisiones
```

## Decisiones de la Fase 0

- **Imagen con tag fijo** (`2022-CU28-ubuntu-22.04`) en vez de `2022-latest`: si se borra el
  contenedor y se vuelve a levantar, la versión es la misma.
- **Límite de memoria** (`MSSQL_MEMORY_LIMIT_MB=2048`) para convivir con otros contenedores.
- **Scripts montados en `/sql` (solo lectura)**: se ejecutan con el `sqlcmd` que trae el
  contenedor, sin depender de herramientas instaladas en el Mac.
- **Schemas por capa** (`stg`, `dw`, `audit`, `sec`): permiten dar permisos por schema en la Fase 8.
- **Recovery model SIMPLE**: no hace falta backup de log en un entorno de portfolio.
- **Workaround de OpenSSL acotado al venv** en vez de cambiar el OpenSSL del sistema: no rompe
  otros programas que ya usan OpenSSL 4.
- Desde la Fase 2 la carga usa el login `tdw_etl` (rol `rol_etl`, mínimo privilegio); `sa` queda solo
  para el despliegue y los tests. En la Fase 8 se agregan los roles de analistas y auditoría.

## Fase 1: datos sintéticos

`python/generar_datos.py` simula el ERP y los bancos de la fintech: facturas AP/AR, pagos, cobranzas,
extractos bancarios, saldos y tipos de cambio, en **archivos mensuales** (como llegan los extractos).
Detalle completo en [docs/datos-sinteticos.md](docs/datos-sinteticos.md).

| | Escala 1 |
|---|---|
| Facturas / pagos / cobranzas | 6.008 / 2.795 / 2.577 |
| Líneas de extracto | 6.440 (transferencias, comisiones, impuesto Ley 25.413, FX) |
| Errores inyectados | **174** en 12 categorías, uno por fila, con archivo y línea en `data/_verdad/errores_inyectados.json` |
| Anomalías de negocio | 5 pagos atípicos, 3 posibles dobles pagos |
| Tiempo de generación | < 1 s (escala 20: ~11 s, 120 mil facturas) |

Decisiones principales:
- **Seed fija y salida determinística**: dos corridas dan archivos idénticos byte a byte (test).
- **Manifiesto exacto**: los tests verifican que cada error está donde dice *y* que toda fila fuera del
  manifiesto está limpia. Así la Fase 5 puede medir falsos positivos y falsos negativos, no solo "detectó algo".
- **Realismo de conciliación**: desfase de fechas, referencias parciales, comisiones descontadas del monto y
  partidas en tránsito. La respuesta correcta está en `data/_verdad/conciliacion_esperada.csv`.
- **Dos snapshots del maestro de contrapartes** (nov-25 y may-26) con cambios de riesgo, plazo y segmento para el SCD2.

## Fase 2: staging

```
data/AAAA-MM/*.csv ──► python/cargar_staging.py ──► stg.<tabla>        (copia fiel, todo NVARCHAR)
   (extractos crudos)    usuario tdw_etl          └► audit.carga_staging (1 fila por archivo y corrida)
```

- **9 tablas `stg.*`**, una por tipo de archivo (los dos snapshots de contrapartes van a la misma tabla).
  Cada fila lleva su linaje: `_row_id`, `_carga_id`, `_source_file`, `_source_line`, `_loaded_at`.
- **Todo NVARCHAR, sin claves de negocio**: staging es el extracto crudo. Si `amount` fuera `DECIMAL`,
  la fila `1.234.567,89` o la fecha `2026-02-30` haría fallar la carga y el error nunca llegaría a los
  controles de la Fase 5; si hubiera una clave única, los duplicados tampoco. La conversión se hace
  después con `TRY_CONVERT`.
- **Idempotente por archivo**: si el sha256 y las filas coinciden con la última carga, se omite; si el
  archivo cambió (o alguien borró filas de staging), se borra y se recarga ese archivo en una transacción.
  Por eso se puede cargar mes a mes (`--mes 2026-03`) o todo junto, N veces, sin duplicar.
- **Controles antes de insertar**: el encabezado del CSV tiene que coincidir con la tabla y ningún valor
  puede exceder el largo de su columna. Si falla, el archivo queda en `ERROR` en la bitácora (con columna
  y línea) y la versión anterior en staging queda intacta.
- **`fast_executemany`** con `setinputsizes` explícito: escala 1 (76 archivos, ~19.500 filas) carga en ~1 s.
- **Mínimo privilegio**: `rol_etl` tiene `SELECT/INSERT/DELETE` en `stg` y `SELECT/INSERT` en `audit`
  (más `UPDATE` solo en la bitácora). No puede crear ni borrar tablas, truncar, editar staging ni borrar
  la bitácora: los tests lo verifican por código de error.
- **Base de test aparte**: el nombre de la base es una variable SQLCMD (`$(DB_NAME)`), así los tests
  despliegan `TesoreriaDW_test` con los mismos scripts y nunca tocan la base de trabajo.

Verificado: 17 tests de integración (copia fiel fila por fila contra los CSV, cada uno de los 174 errores
inyectados presente en staging por archivo y línea, re-ejecución sin duplicados, archivo corregido,
filas borradas, encabezado inválido, valor demasiado largo, permisos), y reconstrucción completa desde
cero (contenedor y volumen borrados): staging queda idéntico.

## Fase 3: modelo dimensional

Esquema estrella en `dw` (detalle, diagrama Mermaid y matriz de bus en [docs/modelo.md](docs/modelo.md)):

| Dimensiones | Hechos | Tipo | Grano (una fila por...) |
|---|---|---|---|
| `dim_fecha` (AAAAMMDD, 2019–2027) | `fact_facturas` | transacción | factura AP/AR |
| `dim_moneda` | `fact_pagos` | transacción | pago ejecutado |
| `dim_contraparte` (**SCD2**) | `fact_cobranzas` | transacción | cobranza recibida |
| `dim_banco_cuenta` | `fact_movimientos_bancarios` | transacción | línea del extracto (monto con signo) |
| `dim_tipo_movimiento` | `fact_saldo_bancario_mensual` | snapshot periódico | cuenta × mes |
| | `fact_tipo_cambio` | snapshot periódico | moneda × día hábil |
| | `fact_conciliacion` | **snapshot acumulativo** | partida de conciliación (libro, banco o ambos) |

Decisiones principales:
- **SCD2 en contrapartes** (riesgo, plazo, segmento, estado) con `vigente_desde/hasta`, hashes persistidos para
  detectar cambios e **índice único filtrado** que garantiza una sola versión vigente.
- **`fact_conciliacion` con grano "partida"**, como la planilla de conciliación bancaria: conciliadas, con
  diferencia, pendientes en banco y pendientes en libros. Los CHECK impiden estados incoherentes (por ejemplo,
  "conciliada" sin línea del banco) y los únicos filtrados impiden que una línea concilie dos pagos.
- **Integridad en la base, no solo en el ETL**: 30 FK verificadas, 25 CHECK de negocio (montos, fechas,
  saldo que cuadra) y miembros `-1`/`-2` en lugar de NULL.
- `DECIMAL(19,2)` + TC + monto en USD en cada hecho; `dim_fecha` generada con `GENERATE_SERIES` (SQL Server 2022),
  sin depender del idioma ni de `SET DATEFIRST`.

Verificado: 56 tests (estructura, calendario, datos estáticos y 27 reglas probadas con **control positivo**:
la fila válida entra y la misma fila con un campo roto falla con el código esperado). Contraprueba: al sacar dos
reglas del DDL fallaron exactamente sus dos tests. Despliegue completo dos veces seguidas sin errores.

## Fase 4: ETL en T-SQL

```
stg.* ──► dw.usp_run_etl ──► usp_load_dim_banco_cuenta     (MERGE, SCD1)
           (orquestador)  ├► usp_load_dim_contraparte      (SCD2, snapshots en orden)
                          ├► usp_load_fact_tipo_cambio
                          ├► usp_load_fact_facturas
                          ├► usp_load_fact_pagos / _cobranzas
                          ├► usp_load_fact_movimientos_bancarios
                          ├► usp_load_fact_saldo_bancario_mensual
                          └► usp_load_fact_conciliacion    (alta de partidas; el matching es la Fase 6)
                 cada paso ──► audit.etl_log (leídas / insertadas / actualizadas / descartadas + motivo / error)
```

| Paso | Leídas | Insertadas | Descartadas (motivo) | Duplicadas |
|---|---:|---:|---|---:|
| dim_contraparte | 245 | 142 (125 + 17 versiones SCD2) | — | — |
| fact_facturas | 6.008 | 5.980 | 28 (monto con formato `1.234,56`, negativo, sin vencimiento, vence antes de emitirse) | — |
| fact_pagos | 2.795 | 2.769 | 16 (fecha `2026-02-30`, monto negativo, moneda `US$`) | 10 |
| fact_cobranzas | 2.577 | 2.561 | 10 (sin moneda, monto negativo) | 6 |
| fact_movimientos_bancarios | 6.440 | 6.424 | 6 (sin importe, fecha inválida) | 10 (reenvíos del banco) |
| fact_conciliacion | — | 10.679 partidas | — | — |

Escala 1, carga completa: ~1,8 s. Lo descartado coincide **exactamente** con los errores inyectados que violan
reglas del DW (lo verifica un test). El resto de los errores entra al DW: los ataja la Fase 5.

**Decisiones:**
- **MERGE vs. INSERT/UPDATE explícito: los dos, cada uno donde conviene.** `MERGE ... WITH (HOLDLOCK)` en
  `dim_banco_cuenta` (upsert simple, `OUTPUT $action` da los conteos). UPDATE + INSERT explícitos en el SCD2 y en
  los hechos: el SCD2 tiene tres operaciones (corregir tipo 1, cerrar versión, abrir versión) que en un MERGE quedan
  enredadas, y separadas cada paso se cuenta y se depura solo; además MERGE tuvo bugs conocidos y sin `HOLDLOCK`
  tiene problemas de concurrencia.
- **Detección de cambios con `WHERE EXISTS (SELECT origen EXCEPT SELECT destino)`**: trata NULL = NULL (con `<>`
  columna por columna un NULL esconde el cambio). Sin cambios no se escribe nada: re-ejecutar es un no-op.
- **Transacción por paso + `TRY/CATCH` + `XACT_ABORT ON`**: un error revierte el paso entero, queda en
  `audit.etl_log` con número y línea (el log se escribe fuera de la transacción, así no se revierte con ella) y el
  orquestador frena (fail fast). Como todo es idempotente, volver a correr retoma sin duplicar.
- **Incremental por fecha de negocio**: cada hecho procesa desde su marca de agua menos 7 días (líneas que el banco
  informa tarde). Las fechas inválidas usan el mes del archivo para caer en alguna ventana y quedar contadas.
  **Las fechas futuras no mueven la marca de agua**: un pago fechado 2027 por error la empujaba y la corrida
  siguiente se salteaba fines de octubre (lo encontró la primera prueba del incremental).
- **Lookup punto en el tiempo** de la contraparte SCD2 y **último tipo de cambio disponible** (`OUTER APPLY ... TOP 1`).
- **Mínimo privilegio**: `rol_etl` solo tiene `EXECUTE` sobre `dw.usp_run_etl`; los demás procedimientos y tablas los usa
  por *ownership chaining*. Hallazgo: con ese permiso, `OBJECT_NAME(@@PROCID)` devuelve NULL (el usuario no "ve" la
  metadata del procedimiento), así que cada procedimiento declara su nombre como texto fijo.

**Verificado** (23 tests nuevos, 146 en total, en cualquier orden de módulos): conteos que cuadran por paso, lo
descartado = lo esperado según el manifiesto, re-ejecución sin cambios (incremental y completa), **carga por partes
(hasta marzo + incremental) idéntica a la carga completa**, cada hecho apunta a la versión SCD2 vigente en su fecha,
conversión a USD con el último TC, error a mitad de paso (rollback + log + fail fast) y permisos. Además: dos
reconstrucciones completas desde cero (contenedor, datos, staging y DW) dan exactamente el mismo DW.

## Fase 5: calidad de datos

Detalle en [docs/calidad-de-datos.md](docs/calidad-de-datos.md).

- **51 reglas** en `audit.dq_reglas`: 43 sobre staging antes de cargar (completitud, unicidad, formato, rango,
  integridad referencial lógica, consistencia entre fuentes) y 8 totales de control staging vs. DW después de cargar.
- Resultados por regla y ejecución en **`audit.dq_resultados`** (regla, tabla, filas evaluadas, filas con error,
  %, severidad, fecha) y detalle por fila en `audit.dq_errores` (archivo, línea, clave, valor observado).
- **ERROR → cuarentena** (`audit.cuarentena_*`, copia fiel de la fila, nada se borra; al corregir y recargar queda
  `LIBERADA`). **ADVERTENCIA → entra y se informa** (maestro de contrapartes, partidas sin contrapartida).
- El ETL excluye lo que está en cuarentena y **retira del DW** lo que ya había entrado; descartes sin explicar: **0**.

| Resultado (escala 1) | |
|---|---|
| Errores inyectados detectados (recall) | **174 / 174 = 100%** |
| Precisión a nivel fila | 97,8% (los 4 sobrantes son las parejas de CUIT duplicado, explicados) |
| En cuarentena | 141 filas (36 facturas, 59 pagos, 26 cobranzas, 16 líneas de extracto, 4 cotizaciones) |
| Totales de control | filas y montos cuadran; **6 cuentas-mes** donde el saldo del banco no se explica (= las líneas en cuarentena) |
| Tiempo de validación | ~1,7 s sobre 19.362 filas |

Hallazgos del camino: los primeros 5 falsos positivos venían de **culpar a un comprobante por el error de otro**
(un pago con fecha futura dejaba "sin match" a su línea del banco; una línea con importe en blanco dejaba "sin
extracto" a su cobranza) y se corrigieron con la regla de no marcar sin evidencia. Y las `#tablas` temporales
necesitan `COLLATE DATABASE_DEFAULT` porque toman la collation de `tempdb`, no la de la base.

**Verificado**: 18 tests nuevos (9 × 2 datasets), 164 en total, en cualquier orden de módulos.
