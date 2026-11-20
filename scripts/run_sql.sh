#!/usr/bin/env bash
# Ejecuta scripts .sql con el sqlcmd que trae el contenedor (no hace falta sqlcmd en el Mac).
#
# Uso:
#   scripts/run_sql.sh                         # todos los scripts de despliegue, en orden
#   scripts/run_sql.sh sql/01_staging/*.sql    # solo los indicados
#   DB_NAME=TesoreriaDW_test scripts/run_sql.sh  # contra otra base (los tests usan esto)
#
# Pasa a los scripts las variables SQLCMD $(DB_NAME), $(ETL_USER), $(ETL_PASSWORD), $(BI_USER) y $(BI_PASSWORD), leídas
# de .env. La clave de sa viaja por la variable de entorno SQLCMDPASSWORD (no queda en la
# línea de comandos). La del ETL sí va como -v: aceptable en un contenedor local.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Falta .env (cp .env.example .env)" >&2; exit 1; }
set -a; . ./.env; set +a
DB_NAME="${DB_NAME:-$MSSQL_DATABASE}"
CONTENEDOR="${CONTENEDOR:-tesoreria-sql}"

if [ "$#" -eq 0 ]; then
    # Orden de despliegue: las carpetas y archivos están numerados a propósito.
    set -- $(ls sql/0[0-9]_*/*.sql | grep -v -E '^sql/0[67]_' | sort)
fi

for f in "$@"; do
    case "$f" in sql/*) ;; *) echo "Solo se pueden ejecutar scripts dentro de sql/: $f" >&2; exit 1;; esac
    echo "== [$DB_NAME] $f"
    docker exec -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$CONTENEDOR" \
        /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b -I -W \
        -v DB_NAME="$DB_NAME" ETL_USER="$MSSQL_ETL_USER" ETL_PASSWORD="$MSSQL_ETL_PASSWORD" \
           BI_USER="$MSSQL_BI_USER" BI_PASSWORD="$MSSQL_BI_PASSWORD" \
        -i "/$f"
done
