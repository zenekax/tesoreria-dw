"""Conexión a SQL Server compartida por todos los scripts Python del proyecto.

Las credenciales salen de `.env` (nunca del código). Así el mismo script corre
en otra máquina cambiando solo el `.env`, igual que en tesorería se cambia el
usuario de Interbanking sin tocar el procedimiento.
"""
from __future__ import annotations

import os
from pathlib import Path

import pyodbc
from dotenv import load_dotenv

RAIZ = Path(__file__).resolve().parent.parent
load_dotenv(RAIZ / ".env")


def cadena_conexion(database: str | None = None, usuario: str = "sa", clave: str | None = None) -> str:
    """Arma la connection string. `database=None` usa la base del .env."""
    driver = os.getenv("MSSQL_ODBC_DRIVER", "ODBC Driver 18 for SQL Server")
    host = os.getenv("MSSQL_HOST", "localhost")
    port = os.getenv("MSSQL_PORT", "1433")
    database = database or os.getenv("MSSQL_DATABASE", "TesoreriaDW")
    clave = clave if clave is not None else os.environ["MSSQL_SA_PASSWORD"]
    # TrustServerCertificate=yes: el contenedor usa un certificado autofirmado.
    # Aceptable en local; en producción se usaría un certificado válido.
    return (
        f"DRIVER={{{driver}}};SERVER={host},{port};DATABASE={database};"
        f"UID={usuario};PWD={clave};Encrypt=yes;TrustServerCertificate=yes;"
    )


def conectar(database: str | None = None, **kwargs) -> pyodbc.Connection:
    return pyodbc.connect(cadena_conexion(database, **kwargs), timeout=10)
