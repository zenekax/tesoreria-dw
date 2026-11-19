"""Chequeo de la Fase 0: ¿Python llega a SQL Server por pyodbc?

Uso:  .venv/bin/python python/verificar_entorno.py
Sale con código 0 si todo OK, 1 si algo falla (sirve para scripts/CI).
"""
from __future__ import annotations

import sys


def main() -> int:
    try:
        import pyodbc
    except ImportError as e:  # típicamente falta unixODBC en el Mac
        print(f"[ERROR] pyodbc no carga: {e}\n        Instalá el driver ODBC (ver README).")
        return 1

    drivers = pyodbc.drivers()
    print(f"[OK] pyodbc {pyodbc.version} | drivers ODBC: {drivers}")
    if not any("SQL Server" in d for d in drivers):
        print("[ERROR] No hay driver ODBC de SQL Server instalado (ver README).")
        return 1

    from db import conectar

    try:
        # master: la base TesoreriaDW puede no existir todavía si no corriste 00_setup.
        with conectar(database="master") as cn:
            version, edicion, dbs = cn.execute(
                "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)), "
                "CAST(SERVERPROPERTY('Edition') AS nvarchar(100)), "
                "(SELECT COUNT(*) FROM sys.databases WHERE name = 'TesoreriaDW')"
            ).fetchone()
    except Exception as e:
        print(f"[ERROR] No se pudo conectar: {e}")
        return 1

    print(f"[OK] SQL Server {version} | {edicion}")
    print(f"[{'OK' if dbs else 'PENDIENTE'}] Base TesoreriaDW {'existe' if dbs else 'no existe (correr sql/00_setup)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
