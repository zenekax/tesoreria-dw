"""Tests de integración de la carga a staging (Fase 2).

Corren contra una base APARTE (TesoreriaDW_test) que se crea desde cero con los mismos
scripts de despliegue y se borra al final: nunca tocan la base de trabajo.
Requieren el contenedor levantado; si no hay conexión, se saltean (no fallan).

Los tests van en orden y comparten estado (la base de test), como una auditoría que
sigue paso a paso: carga inicial por mes, carga completa, re-ejecución, cambios, errores.
"""
from __future__ import annotations

import csv
import os
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import db  # noqa: E402
import generar_datos as gd  # noqa: E402

from conftest import BASE_TEST, codigo_error  # noqa: E402

TABLAS = ["banks", "bank_accounts", "counterparties", "fx_rates", "invoices", "payments",
          "collections", "bank_statements", "bank_balances"]


@pytest.fixture(scope="module")
def entorno(base_limpia, tmp_path_factory):
    datos = tmp_path_factory.mktemp("datos")
    manifiesto = gd.generar(datos, escala=0.3)
    yield datos, manifiesto


def etl():
    return db.conectar_etl(BASE_TEST)


def filas_csv(datos: Path) -> dict[str, list[list]]:
    """archivo -> filas de datos ('' convertido a None, como lo carga el cargador)."""
    out = {}
    for ruta in cs.descubrir_archivos(datos, None):
        with open(ruta, encoding="utf-8", newline="") as fh:
            out[ruta.relative_to(datos).as_posix()] = [[v or None for v in f] for f in list(csv.reader(fh))[1:]]
    return out


def conteo_stg() -> Counter:
    c = Counter()
    with etl() as cn:
        for t in TABLAS:
            for archivo, n in cn.execute(f"SELECT _source_file, COUNT(*) FROM stg.{t} GROUP BY _source_file"):
                c[archivo] = n
    return c


# --------------------------------------------------------------------------- carga inicial
def test_carga_incremental_por_mes_y_luego_completa(entorno):
    datos, _ = entorno
    r1 = cs.cargar(datos, meses=["2025-11"], database=BASE_TEST)
    assert set(r1) == {"CARGADO"}
    assert all(a.startswith(("maestros/", "2025-11/")) for a in r1["CARGADO"])

    r2 = cs.cargar(datos, database=BASE_TEST)
    assert set(r2) == {"CARGADO", "OMITIDO"}
    assert set(r2["OMITIDO"]) == set(r1["CARGADO"]), "lo ya cargado no se vuelve a cargar"


def test_staging_tiene_exactamente_lo_que_dicen_los_csv(entorno):
    datos, _ = entorno
    esperado = {a: len(f) for a, f in filas_csv(datos).items()}
    assert dict(conteo_stg()) == esperado


def test_valores_identicos_al_csv_fila_por_fila(entorno):
    """Staging es una copia fiel: mismo valor, mismo archivo, misma línea."""
    datos, _ = entorno
    csvs = filas_csv(datos)
    with etl() as cn:
        cur = cn.cursor()
        for t in TABLAS:
            cols = [c for c, _ in cs.Cargador(cn, datos, False).columnas(t)]
            filas = cur.execute(f"SELECT _source_file, _source_line, {', '.join(cols)} FROM stg.{t}").fetchall()
            for f in filas:
                assert list(f[2:]) == csvs[f[0]][f[1] - 2], (t, f[0], f[1])


def test_staging_conserva_cada_error_inyectado(entorno):
    """El puente con la Fase 5: cada error del manifiesto se encuentra en staging por
    (_source_file, _source_line), con el valor roto intacto."""
    _, m = entorno
    with etl() as cn:
        for e in m["errores"]:
            for u in e["ubicaciones"]:
                pk, valor_pk = next(iter(e["clave"].items()))
                campo = e["campo"] or pk
                fila = cn.execute(f"SELECT {pk}, {campo} FROM stg.{e['tabla']} "
                                  "WHERE _source_file = ? AND _source_line = ?", u["archivo"], u["linea"]).fetchone()
                assert fila is not None, e["id"]
                assert fila[0] == (valor_pk or None), e["id"]
                if e["campo"]:
                    assert fila[1] == (e["valor_inyectado"] or None), e["id"]


def test_bitacora_registra_cada_archivo(entorno):
    datos, _ = entorno
    n = len(cs.descubrir_archivos(datos, None))
    with etl() as cn:
        cargados = cn.execute("SELECT COUNT(DISTINCT archivo) FROM audit.carga_staging "
                              "WHERE resultado = 'CARGADO'").fetchone()[0]
        en_curso = cn.execute("SELECT COUNT(*) FROM audit.carga_staging WHERE resultado = 'EN_CURSO'").fetchone()[0]
    assert cargados == n
    assert en_curso == 0, "ninguna carga puede quedar abierta"


# --------------------------------------------------------------------------- idempotencia
def test_re_ejecutar_no_duplica(entorno):
    datos, _ = entorno
    antes = conteo_stg()
    r = cs.cargar(datos, database=BASE_TEST)
    assert set(r) == {"OMITIDO"}
    assert conteo_stg() == antes


def test_archivo_corregido_se_reemplaza_entero(entorno):
    """El banco manda de nuevo el extracto de marzo, corregido (una línea menos)."""
    datos, _ = entorno
    ruta = datos / "2026-03" / "bank_statements.csv"
    lineas = ruta.read_text(encoding="utf-8").splitlines(keepends=True)
    ruta.write_text("".join(lineas[:-1]), encoding="utf-8")
    r = cs.cargar(datos, database=BASE_TEST)
    assert r["REEMPLAZADO"] == ["2026-03/bank_statements.csv"]
    assert len(r["OMITIDO"]) == len(cs.descubrir_archivos(datos, None)) - 1
    assert conteo_stg()["2026-03/bank_statements.csv"] == len(lineas) - 2


def test_si_alguien_borra_filas_de_staging_se_recargan(entorno):
    datos, _ = entorno
    rel = "2026-05/payments.csv"
    esperado = conteo_stg()[rel]
    with db.conectar(database=BASE_TEST, autocommit=True) as cn:
        cn.execute("DELETE TOP (10) FROM stg.payments WHERE _source_file = ?", rel)
    r = cs.cargar(datos, database=BASE_TEST)
    assert r["REEMPLAZADO"] == [rel]
    assert conteo_stg()[rel] == esperado


# --------------------------------------------------------------------------- archivos con problemas
def test_encabezado_distinto_queda_en_error_sin_tocar_staging(entorno, tmp_path):
    datos, _ = entorno
    copia = tmp_path / "datos"
    shutil.copytree(datos, copia)
    ruta = copia / "2026-04" / "payments.csv"
    texto = ruta.read_text(encoding="utf-8").replace("payment_method", "metodo_pago", 1)
    ruta.write_text(texto + "PAY-X,OP-X,INV-X,CP-X,ACC01,2026-04-30,ARS,1.00,TRANSFERENCIA\n", encoding="utf-8")
    antes = conteo_stg()["2026-04/payments.csv"]
    r = cs.cargar(copia, database=BASE_TEST)
    assert r["ERROR"] == ["2026-04/payments.csv"]
    assert conteo_stg()["2026-04/payments.csv"] == antes, "la versión anterior queda intacta"
    with etl() as cn:
        msg = cn.execute("SELECT TOP 1 mensaje FROM audit.carga_staging WHERE resultado = 'ERROR' "
                         "ORDER BY carga_id DESC").fetchone()[0]
    assert "encabezado" in msg and "metodo_pago" in msg


def test_valor_mas_largo_que_la_columna_avisa_columna_y_linea(entorno, tmp_path):
    datos, _ = entorno
    copia = tmp_path / "datos"
    shutil.copytree(datos, copia)
    ruta = copia / "2026-06" / "invoices.csv"
    filas = list(csv.reader(open(ruta, encoding="utf-8")))
    filas[5][-1] = "x" * 401  # description es NVARCHAR(400)
    with open(ruta, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh, lineterminator="\n").writerows(filas)
    r = cs.cargar(copia, database=BASE_TEST)
    assert r["ERROR"] == ["2026-06/invoices.csv"]
    with etl() as cn:
        msg = cn.execute("SELECT TOP 1 mensaje FROM audit.carga_staging WHERE resultado = 'ERROR' "
                         "ORDER BY carga_id DESC").fetchone()[0]
    assert "línea 6" in msg and "description" in msg


# --------------------------------------------------------------------------- seguridad
@pytest.mark.parametrize("sentencia", [
    "CREATE TABLE stg.prueba (x INT)",
    "DROP TABLE stg.banks",
    "TRUNCATE TABLE stg.banks",
    "DELETE FROM audit.carga_staging",            # la bitácora no se puede borrar desde el ETL
    "UPDATE stg.banks SET bank_name = 'x'",       # staging no se edita: se recarga
    "CREATE SCHEMA hackeo",
])
def test_usuario_etl_tiene_minimo_privilegio(entorno, sentencia):
    """Tiene que fallar POR PERMISOS (no por un error de sintaxis que haría pasar el test igual).
    229/262/15247 = permiso denegado; 3701/1088 = "no existe o no tenés permiso" (SQL Server
    no le confirma la existencia de un objeto a quien no tiene acceso)."""
    import pyodbc
    with etl() as cn:
        with pytest.raises(pyodbc.Error) as exc:
            cn.execute(sentencia)
        cn.rollback()
    assert codigo_error(exc.value) in {229, 262, 1088, 3701, 15247}, str(exc.value)


def test_la_carga_no_usa_sa(entorno):
    with etl() as cn:
        usuarios = {r[0] for r in cn.execute("SELECT DISTINCT usuario FROM audit.carga_staging")}
    assert usuarios == {os.environ["MSSQL_ETL_USER"]}
