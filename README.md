# tesoreria-dw

Data warehouse de tesorería en **SQL Server 2022** para una fintech (ficticia) de pagos
transfronterizos: pagos a proveedores, cobranzas, movimientos bancarios y conciliación
en ARS, USD, BRL, MXN y COP. ETL en Python + T-SQL, control de calidad, seguridad y análisis.

> Todos los datos son **sintéticos**. Proyecto de portfolio.

## Estado

| Fase | Contenido | Estado |
|---|---|---|
| 0 | Entorno: Docker, Python, Git | 🟡 falta probar `pyodbc` (driver ODBC en el Mac) |
| 1 | Datos sintéticos con errores inyectados | ⏳ |
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
HOMEBREW_ACCEPT_EULA=Y brew install msodbcsql18 mssql-tools18
```

  (`msodbcsql18` trae `unixodbc` como dependencia; `mssql-tools18` agrega `sqlcmd` al Mac.
  La variable `HOMEBREW_ACCEPT_EULA=Y` implica aceptar la licencia de Microsoft.)

## Cómo levantarlo

```bash
cp .env.example .env   # y cambiar MSSQL_SA_PASSWORD
```

```bash
docker compose up -d --wait
```

```bash
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements.txt
```

Crear la base y los schemas (idempotente, se puede correr varias veces):

```bash
docker exec tesoreria-sql sh -c '/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b -i /sql/00_setup/01_crear_base_y_schemas.sql'
```

Verificar que Python llega a la base:

```bash
.venv/bin/python python/verificar_entorno.py
```

## Estructura

```
docker-compose.yml     SQL Server 2022 CU28 (tag fijo), volumen persistente, ./sql montado en /sql
.env.example           plantilla de variables; .env real nunca se commitea
requirements.txt       dependencias Python con versión fija
python/db.py           conexión compartida (lee credenciales de .env)
python/verificar_entorno.py
sql/00_setup/          base TesoreriaDW + schemas stg, dw, audit, sec
docs/REQUISITOS.md     requisito del puesto -> dónde se demuestra
```

## Decisiones de la Fase 0

- **Imagen con tag fijo** (`2022-CU28-ubuntu-22.04`) en vez de `2022-latest`: si se borra el
  contenedor y se vuelve a levantar, la versión es la misma.
- **Límite de memoria** (`MSSQL_MEMORY_LIMIT_MB=2048`) para convivir con otros contenedores.
- **Scripts montados en `/sql` (solo lectura)**: se ejecutan con el `sqlcmd` que trae el
  contenedor, sin depender de herramientas instaladas en el Mac.
- **Schemas por capa** (`stg`, `dw`, `audit`, `sec`): permiten dar permisos por schema en la Fase 8.
- **Recovery model SIMPLE**: no hace falta backup de log en un entorno de portfolio.
- Por ahora los scripts se conectan como `sa`; en la Fase 8 se crean usuarios con mínimo privilegio.
