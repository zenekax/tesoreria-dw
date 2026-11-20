"""Ejecuta un script .sql del repo desde Python y devuelve todos sus result sets.

Imita lo que hace sqlcmd con los scripts del proyecto: reemplaza la variable $(DB_NAME) y
separa los lotes por las líneas "GO". Lo usan los tests (Fase 6) y las mediciones de
performance (Fase 7), que necesitan leer los resultados, no solo imprimirlos.
"""
from __future__ import annotations

import re
from pathlib import Path

import pyodbc

from db import RAIZ


def lotes(ruta: Path, database: str) -> list[str]:
    texto = Path(ruta).read_text(encoding="utf-8").replace("$(DB_NAME)", database)
    return [b for b in re.split(r"^\s*GO\s*$", texto, flags=re.MULTILINE | re.IGNORECASE) if b.strip()]


def ejecutar_script(cn: pyodbc.Connection, ruta: str | Path, database: str) -> list[list[dict]]:
    """Corre el script en la conexión dada y devuelve [result_set][fila] como diccionarios."""
    ruta = Path(ruta) if Path(ruta).is_absolute() else RAIZ / ruta
    resultados: list[list[dict]] = []
    cur = cn.cursor()
    for lote in lotes(ruta, database):
        cur.execute(lote)
        while True:
            if cur.description:
                cols = [c[0] for c in cur.description]
                resultados.append([dict(zip(cols, f)) for f in cur.fetchall()])
            if not cur.nextset():
                break
    return resultados
