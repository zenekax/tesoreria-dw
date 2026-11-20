"""Tests de seguridad (Fase 8): roles y permisos, Row-Level Security y Dynamic Data Masking.

Se prueban con EXECUTE AS USER (la sesión de sa "se pone el traje" de cada usuario) y con
el login real de Power BI. Cada prohibición se verifica por su código de error (229 =
permiso denegado sobre el objeto, 230 = sobre la columna), no por "algún error".
"""
from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from pathlib import Path

import pyodbc
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import db  # noqa: E402
import ejecutar_etl as etl  # noqa: E402
import generar_datos as gd  # noqa: E402
from conftest import BASE_TEST, codigo_error  # noqa: E402

HECHOS_CON_MONEDA = ["fact_facturas", "fact_pagos", "fact_cobranzas", "fact_movimientos_bancarios",
                     "fact_saldo_bancario_mensual", "fact_conciliacion"]
MONEDAS = {"analista_ar": {"ARS", "USD"}, "analista_br": {"BRL"}}


@pytest.fixture(scope="module")
def cargado(base_limpia, tmp_path_factory):
    datos = tmp_path_factory.mktemp("datos_seguridad")
    gd.generar(datos, escala=0.3)
    assert "ERROR" not in cs.cargar(datos, database=BASE_TEST)
    resumen = etl.ejecutar(BASE_TEST)          # el ETL corre con RLS y masking activos
    return resumen


@contextmanager
def como(usuario: str):
    cn = db.conectar(database=BASE_TEST, autocommit=True)
    cn.execute(f"EXECUTE AS USER = '{usuario}'")
    try:
        yield cn
    finally:
        cn.execute("REVERT")
        cn.close()


def sa():
    return db.conectar(database=BASE_TEST, autocommit=True)


def test_el_etl_funciona_con_la_seguridad_activa(cargado):
    assert all(r["estado"] == "OK" for r in cargado)
    with sa() as cn:
        assert cn.execute("SELECT is_enabled FROM sys.security_policies WHERE name = 'pol_rls_moneda'").fetchone()[0]
        assert cn.execute("SELECT COUNT(*) FROM sys.masked_columns").fetchone()[0] == 3
        assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0] > 0


# --------------------------------------------------------------------------- RLS
@pytest.mark.parametrize("usuario", list(MONEDAS))
@pytest.mark.parametrize("hecho", HECHOS_CON_MONEDA)
def test_rls_cada_analista_ve_solo_sus_monedas(cargado, usuario, hecho):
    monedas = MONEDAS[usuario]
    with sa() as cn:
        esperado = cn.execute(
            f"SELECT COUNT(*) FROM dw.{hecho} h JOIN dw.dim_moneda m ON m.moneda_key = h.moneda_key "
            f"WHERE m.codigo_iso IN ({', '.join('?' * len(monedas))})", *sorted(monedas)).fetchone()[0]
    with como(usuario) as cn:
        visibles = {r[0] for r in cn.execute(
            f"SELECT DISTINCT m.codigo_iso FROM dw.{hecho} h JOIN dw.dim_moneda m ON m.moneda_key = h.moneda_key")}
        total = cn.execute(f"SELECT COUNT(*) FROM dw.{hecho}").fetchone()[0]
    assert visibles <= monedas
    assert total == esperado > 0


def test_rls_no_se_esquiva_filtrando_por_otra_moneda(cargado):
    with sa() as cn:
        brl = cn.execute("SELECT moneda_key FROM dw.dim_moneda WHERE codigo_iso = 'BRL'").fetchone()[0]
    with como("analista_ar") as cn:
        assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos WHERE moneda_key = ?", brl).fetchone()[0] == 0
        assert {r[0] for r in cn.execute("SELECT moneda_iso FROM dw.dim_banco_cuenta")} <= {"ARS", "USD"}


def test_auditor_ve_todo(cargado):
    with sa() as cn:
        total = cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0]
    with como("auditor_demo") as cn:
        assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0] == total
        assert cn.execute("SELECT COUNT(*) FROM stg.payments").fetchone()[0] > 0
        assert cn.execute("SELECT COUNT(*) FROM audit.dq_resultados").fetchone()[0] > 0


# --------------------------------------------------------------------------- masking
def test_masking_analista_ve_enmascarado_y_auditor_ve_el_dato(cargado):
    consulta_cuenta = "SELECT TOP 1 numero_cuenta FROM dw.dim_banco_cuenta WHERE moneda_iso = 'ARS' ORDER BY cuenta_id"
    consulta_cp = "SELECT TOP 1 email, tax_id FROM dw.dim_contraparte WHERE contraparte_key = 1"
    with sa() as cn:
        cuenta_real = cn.execute(consulta_cuenta).fetchone()[0]
        email_real, tax_real = cn.execute(consulta_cp).fetchone()
    with como("analista_ar") as cn:
        cuenta = cn.execute(consulta_cuenta).fetchone()[0]
        email, tax = cn.execute(consulta_cp).fetchone()
    assert cuenta == "XXXX..." + cuenta_real[-4:] != cuenta_real
    assert email != email_real and email.endswith("XXXX.com")
    assert tax != tax_real and tax.endswith(tax_real[-3:])
    with como("auditor_demo") as cn:
        assert cn.execute(consulta_cuenta).fetchone()[0] == cuenta_real
        assert tuple(cn.execute(consulta_cp).fetchone()) == (email_real, tax_real)


def test_el_masking_no_rompe_los_filtros_del_analista(cargado):
    """El enmascarado es de presentación: un filtro por el valor real sigue funcionando (por eso
    el masking no reemplaza a los permisos: con filtros se puede inferir el dato)."""
    with sa() as cn:
        cuenta_real = cn.execute("SELECT TOP 1 numero_cuenta FROM dw.dim_banco_cuenta WHERE moneda_iso = 'ARS'").fetchone()[0]
    with como("analista_ar") as cn:
        assert cn.execute("SELECT COUNT(*) FROM dw.dim_banco_cuenta WHERE numero_cuenta = ?", cuenta_real).fetchone()[0] == 1


# --------------------------------------------------------------------------- permisos
@pytest.mark.parametrize("usuario,sentencia,codigo", [
    ("analista_ar", "SELECT TOP 1 * FROM stg.payments", 229),
    ("analista_ar", "SELECT TOP 1 * FROM audit.etl_log", 229),
    ("analista_ar", "SELECT TOP 1 * FROM audit.cuarentena_payments", 229),
    ("analista_ar", "SELECT TOP 1 * FROM sec.usuario_moneda", 229),
    ("analista_ar", "INSERT INTO sec.usuario_moneda VALUES (USER_NAME(), '*')", 229),   # no se da más monedas
    ("analista_ar", "DELETE FROM dw.fact_pagos", 229),
    ("analista_ar", "UPDATE dw.dim_contraparte SET razon_social = 'x'", 229),
    ("analista_ar", "SELECT TOP 1 hash_tipo1 FROM dw.dim_contraparte", 230),            # huella de email + CUIT
    ("analista_ar", "EXEC dw.usp_run_etl", 229),
    ("auditor_demo", "DELETE FROM audit.dq_errores", 229),
    ("auditor_demo", "UPDATE dw.fact_pagos SET monto = 0", 229),
    ("auditor_demo", "EXEC dw.usp_run_etl", 229),
    ("auditor_demo", "INSERT INTO sec.usuario_moneda VALUES ('analista_ar', '*')", 229),
])
def test_permisos_denegados(cargado, usuario, sentencia, codigo):
    with como(usuario) as cn:
        with pytest.raises(pyodbc.Error) as exc:
            cn.execute(sentencia).fetchall()
    assert codigo_error(exc.value) == codigo, str(exc.value)


def test_login_power_bi_ve_todas_las_monedas_enmascarado(cargado):
    cn = pyodbc.connect(db.cadena_conexion(BASE_TEST, usuario=os.environ["MSSQL_BI_USER"],
                                           clave=os.environ["MSSQL_BI_PASSWORD"]), timeout=10)
    try:
        monedas = {r[0] for r in cn.execute("SELECT DISTINCT m.codigo_iso FROM dw.fact_pagos p "
                                            "JOIN dw.dim_moneda m ON m.moneda_key = p.moneda_key")}
        cuenta = cn.execute("SELECT TOP 1 numero_cuenta FROM dw.dim_banco_cuenta WHERE banco_cuenta_key > 0").fetchone()[0]
        with pytest.raises(pyodbc.Error) as exc:
            cn.execute("SELECT TOP 1 * FROM stg.payments").fetchall()
    finally:
        cn.close()
    assert monedas == {"ARS", "USD", "BRL", "MXN", "COP"}
    assert cuenta.startswith("XXXX...")
    assert codigo_error(exc.value) == 229
