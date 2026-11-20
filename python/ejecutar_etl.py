#!/usr/bin/env python3
"""
ejecutar_etl.py — Ejecuta el ETL de T-SQL (dw.usp_run_etl) con el usuario de mínimo privilegio.

Toda la lógica de transformación vive en SQL Server (stored procedures); este script solo
la dispara y muestra el resumen que devuelve. Es el equivalente a programar un job del
SQL Server Agent, pero ejecutable desde la terminal o desde un orquestador externo.

Uso:
    python python/ejecutar_etl.py                       # incremental (desde la marca de agua - 7 días)
    python python/ejecutar_etl.py --completa            # reprocesa todo
    python python/ejecutar_etl.py --desde 2026-03-01 --hasta 2026-03-31
Sale con código 1 si el ETL falló (el detalle queda en audit.etl_log).
"""
from __future__ import annotations

import argparse
import sys
from datetime import date

import pyodbc

from db import conectar_etl


def ejecutar(database: str | None = None, completa: bool = False, desde: date | None = None,
             hasta: date | None = None, dias_reproceso: int = 7) -> list[dict]:
    """Corre dw.usp_run_etl y devuelve el resumen por paso. Importable desde los tests."""
    # autocommit=True: el procedimiento maneja sus propias transacciones (una por paso).
    with conectar_etl(database, autocommit=True) as cn:
        cur = cn.cursor()
        cur.execute("EXEC dw.usp_run_etl @carga_completa = ?, @fecha_desde = ?, @fecha_hasta = ?, "
                    "@dias_reproceso = ?", int(completa), desde, hasta, dias_reproceso)
        # El resumen es el último result set que devuelve el procedimiento.
        filas = []
        while True:
            if cur.description:
                cols = [c[0] for c in cur.description]
                filas = [dict(zip(cols, f)) for f in cur.fetchall()]
            if not cur.nextset():
                break
        return filas


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--completa", action="store_true", help="reprocesar todo, ignorando las marcas de agua")
    ap.add_argument("--desde", type=date.fromisoformat)
    ap.add_argument("--hasta", type=date.fromisoformat)
    ap.add_argument("--dias-reproceso", type=int, default=7)
    ap.add_argument("--base", help="base destino (default: MSSQL_DATABASE del .env)")
    a = ap.parse_args()
    try:
        filas = ejecutar(a.base, a.completa, a.desde, a.hasta, a.dias_reproceso)
    except pyodbc.Error as e:
        print(f"ETL con ERROR (detalle en audit.etl_log): {e}", file=sys.stderr)
        return 1
    print(f"{'paso':<40} {'estado':<6} {'leídas':>7} {'insert.':>7} {'actual.':>7} {'descart.':>8} {'dup.':>5} {'ms':>6}")
    for f in filas:
        n = lambda k: "" if f[k] is None else f"{f[k]:,}"  # noqa: E731
        print(f"{f['proceso']:<40} {f['estado']:<6} {n('filas_leidas'):>7} {n('filas_insertadas'):>7} "
              f"{n('filas_actualizadas'):>7} {n('filas_descartadas'):>8} {n('filas_duplicadas'):>5} "
              f"{n('duracion_ms'):>6}")
        if f["mensaje"]:
            print(f"    {f['mensaje']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
