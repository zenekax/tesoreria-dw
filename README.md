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
| 2 | Staging (`stg`) | ⏳ |
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
    solo para el venv del proyecto (exporta `DYLD_LIBRARY_PATH` hacia `openssl@3` al activarlo).

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

Crear la base y los schemas (idempotente, se puede correr varias veces):

```bash
docker exec tesoreria-sql sh -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -i /sql/00_setup/01_crear_base_y_schemas.sql'
```

Generar los datos sintéticos (12 meses, seed fija, 174 errores inyectados) y correr los tests:

```bash
python python/generar_datos.py
```

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
python/tests/          tests de reproducibilidad y exactitud del manifiesto de errores
scripts/setup_python.sh venv + dependencias + workaround OpenSSL en Mac (idempotente)
sql/00_setup/          base TesoreriaDW + schemas stg, dw, audit, sec
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
- Por ahora los scripts se conectan como `sa`; en la Fase 8 se crean usuarios con mínimo privilegio.

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
