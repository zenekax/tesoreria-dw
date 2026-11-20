"""Fixtures compartidas por los tests de integración.

`base_test` despliega una base APARTE (TesoreriaDW_test) con los mismos scripts que la
base de trabajo, dos veces seguidas (probando que son idempotentes), y la borra al
terminar la sesión de tests. Si SQL Server no está disponible, los tests que la usan
se saltean; cualquier otro error (un bug) hace FALLAR el test, no lo saltea.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import db  # noqa: E402

BASE_TEST = "TesoreriaDW_test"


def _borrar_base():
    with db.conectar(database="master", autocommit=True) as cn:
        cn.execute(f"IF DB_ID('{BASE_TEST}') IS NOT NULL BEGIN "
                   f"ALTER DATABASE [{BASE_TEST}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
                   f"DROP DATABASE [{BASE_TEST}]; END")


def desplegar():
    r = subprocess.run([str(db.RAIZ / "scripts" / "run_sql.sh")], env={**os.environ, "DB_NAME": BASE_TEST},
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.fixture(scope="session")
def base_test():
    import pyodbc
    try:
        db.conectar(database="master", autocommit=True).close()
    except pyodbc.Error as e:
        pytest.skip(f"SQL Server no disponible: {e}")
    _borrar_base()
    desplegar()
    desplegar()  # los scripts de despliegue tienen que poder correr dos veces seguidas
    yield BASE_TEST
    _borrar_base()


def codigo_error(exc: Exception) -> int:
    """Número de error de SQL Server dentro de un pyodbc.Error (ej. 547 = viola CHECK/FK)."""
    m = re.search(r"\((\d+)\)\s*\(SQL(?:ExecDirect|Execute)W\)", str(exc))
    assert m, f"no se encontró código de error en: {exc}"
    return int(m.group(1))
