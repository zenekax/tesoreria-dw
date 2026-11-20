#!/usr/bin/env bash
# Levanta TODO el proyecto desde un clon limpio, en un solo comando (idempotente):
#   1. .env con claves aleatorias (si no existe)      4. despliegue de la base (scripts/run_sql.sh)
#   2. SQL Server 2022 en Docker                       5. datos sintéticos -> staging
#   3. entorno de Python                               6. ETL con calidad de datos y conciliación
#
# Requisitos previos: Docker, Python 3.12 (o uv) y, en Mac, el driver ODBC (ver README).
# Se puede correr N veces: no duplica nada y no borra datos.
set -euo pipefail
cd "$(dirname "$0")/.."
paso() { printf '\n==> %s\n' "$1"; }

paso "1/6 Archivo .env"
if [ -f .env ]; then
    echo ".env ya existe: se usa tal cual"
else
    # Claves aleatorias que cumplen la política de SQL Server (mayúscula, minúscula, número y símbolo).
    python3 - <<'EOF'
import secrets, string
a = string.ascii_letters + string.digits
clave = lambda p: p + ''.join(secrets.choice(a) for _ in range(20)) + '7_!'
texto = open('.env.example').read()
for viejo, prefijo in (("CambiarEstaClave_123!", "Sa"), ("CambiarEstaClaveEtl_123!", "Et"), ("CambiarEstaClaveBi_123!", "Bi")):
    texto = texto.replace(viejo, clave(prefijo))
open('.env', 'w').write(texto)
EOF
    chmod 600 .env
    echo ".env creado con claves aleatorias (no se muestran)"
fi

paso "2/6 SQL Server en Docker"
docker compose up -d --wait

paso "3/6 Entorno de Python"
./scripts/setup_python.sh

paso "4/6 Despliegue de la base (schemas, staging, DW, ETL, calidad, seguridad, vistas)"
./scripts/run_sql.sh > /dev/null
echo "OK"

paso "5/6 Datos sintéticos y carga a staging"
.venv/bin/python python/generar_datos.py | tail -1
.venv/bin/python python/cargar_staging.py | tail -1

paso "6/6 ETL (calidad de datos, carga del DW y conciliación)"
.venv/bin/python python/ejecutar_etl.py | sed -n '2,3p'

printf '\nListo. Base %s en localhost:%s.\n' "$(grep ^MSSQL_DATABASE= .env | cut -d= -f2)" "$(grep ^MSSQL_PORT= .env | cut -d= -f2)"
echo "Tests:     .venv/bin/python -m pytest python/tests -q"
echo "Consultas: sql/06_queries/*.sql (ejecutar con scripts/run_sql.sh <archivo>)"
