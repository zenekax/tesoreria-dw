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
| 3 | Modelo dimensional (`dw`) | ⏳ |
| 4 | ETL en T-SQL | ⏳ |
| 5 | Calidad de datos | ⏳ |
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

Desplegar la base (base, schemas, usuario ETL y tablas de staging; idempotente):

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
python/tests/          tests del generador y de la carga (integración contra TesoreriaDW_test)
scripts/run_sql.sh     ejecuta los .sql en orden con el sqlcmd del contenedor (variables SQLCMD)
scripts/setup_python.sh venv + dependencias + workaround OpenSSL en Mac (idempotente)
scripts/_tdw_openssl.py  relanzador que instala setup_python.sh en el venv (solo macOS)
sql/00_setup/          base + schemas stg, dw, audit, sec + login tdw_etl / rol_etl
sql/01_staging/        tablas stg.* y bitácora audit.carga_staging
docs/REQUISITOS.md     requisito del puesto -> dónde se demuestra
docs/datos-sinteticos.md  archivos, realismo de tesorería, errores inyectados y decisiones
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
