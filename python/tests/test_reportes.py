"""Tests de la capa de consumo (Fase 9): vistas rpt para Power BI.

Las vistas tienen que (1) responder para el login de Power BI, (2) respetar RLS y masking sin
configuración extra, y (3) dar los mismos números que las consultas de análisis de la Fase 6.
"""
from __future__ import annotations

import os
import sys
from decimal import Decimal
from pathlib import Path

import pyodbc
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import db  # noqa: E402
import ejecutar_etl as etl  # noqa: E402
import generar_datos as gd  # noqa: E402
from conftest import BASE_TEST  # noqa: E402
from ejecutar_sql import ejecutar_script  # noqa: E402

VISTAS = ["dim_fecha", "dim_moneda", "dim_cuenta", "dim_contraparte", "fact_movimientos", "fact_pagos",
          "fact_cobranzas", "fact_facturas", "fact_conciliacion", "v_flujo_caja_diario", "v_aging_cobranzas",
          "v_evolucion_cartera"]


@pytest.fixture(scope="module")
def cargado(base_limpia, tmp_path_factory):
    datos = tmp_path_factory.mktemp("datos_rpt")
    gd.generar(datos, escala=0.3)
    assert "ERROR" not in cs.cargar(datos, database=BASE_TEST)
    etl.ejecutar(BASE_TEST)


def bi():
    return pyodbc.connect(db.cadena_conexion(BASE_TEST, usuario=os.environ["MSSQL_BI_USER"],
                                             clave=os.environ["MSSQL_BI_PASSWORD"]), timeout=10)


def sa():
    return db.conectar(database=BASE_TEST, autocommit=True)


@pytest.mark.parametrize("vista", VISTAS)
def test_vista_responde_para_power_bi(cargado, vista):
    with bi() as cn:
        assert cn.execute(f"SELECT COUNT(*) FROM rpt.{vista}").fetchone()[0] > 0


def test_power_bi_no_ve_datos_sensibles(cargado):
    with bi() as cn:
        cuentas = [r[0] for r in cn.execute("SELECT numero_cuenta FROM rpt.dim_cuenta WHERE banco_cuenta_key > 0")]
        columnas_cp = {r[0] for r in cn.execute(
            "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID('rpt.dim_contraparte')")}
    assert cuentas and all(c.startswith("XXXX...") for c in cuentas)
    assert not columnas_cp & {"email", "tax_id", "hash_tipo1", "hash_tipo2"}


def test_rls_tambien_a_traves_de_las_vistas(cargado):
    cn = sa()
    cn.execute("EXECUTE AS USER = 'analista_br'")
    try:
        monedas = {r[0] for r in cn.execute("SELECT DISTINCT moneda FROM rpt.v_flujo_caja_diario")}
        monedas_pagos = {r[0] for r in cn.execute(
            "SELECT DISTINCT m.moneda FROM rpt.fact_pagos p JOIN rpt.dim_moneda m ON m.moneda_key = p.moneda_key")}
        cuentas = {r[0] for r in cn.execute("SELECT moneda FROM rpt.dim_cuenta")}
    finally:
        cn.execute("REVERT")
        cn.close()
    assert monedas == monedas_pagos == cuentas == {"BRL"}


def test_flujo_de_caja_igual_a_la_consulta_de_analisis(cargado):
    with sa() as cn:
        diario, _ = ejecutar_script(cn, "sql/06_queries/03_flujo_caja_diario.sql", BASE_TEST)
        vista = {(str(r[0]), r[1]): r[2] for r in cn.execute("SELECT fecha, moneda, saldo_cierre FROM rpt.v_flujo_caja_diario")}
    assert {(str(d["fecha"]), d["moneda"]): d["saldo_cierre"] for d in diario} == vista


def test_aging_igual_a_la_consulta_de_analisis(cargado):
    with sa() as cn:
        tramos, _, _ = ejecutar_script(cn, "sql/06_queries/02_aging_cobranzas.sql", BASE_TEST)
        vista = cn.execute("SELECT COUNT(*), SUM(saldo_usd_cierre) FROM rpt.v_aging_cobranzas").fetchone()
    assert vista[0] == sum(t["facturas"] for t in tramos)
    assert vista[1] == sum(t["saldo_usd"] for t in tramos)


def test_evolucion_cartera_igual_a_la_consulta_de_analisis(cargado):
    with sa() as cn:
        (serie,) = ejecutar_script(cn, "sql/06_queries/07_evolucion_cartera_recursiva.sql", BASE_TEST)
        vista = [tuple(r) for r in cn.execute("SELECT cierre, facturas_abiertas, cartera_usd, dso_dias "
                                              "FROM rpt.v_evolucion_cartera ORDER BY cierre")]
    assert vista == [(s["cierre"], s["facturas_abiertas"], s["cartera_usd"], s["dso_dias"]) for s in serie]


def test_conciliacion_fecha_de_partida_siempre_real(cargado):
    with sa() as cn:
        assert cn.execute("SELECT COUNT(*) FROM rpt.fact_conciliacion WHERE fecha_key <= 0").fetchone()[0] == 0
        pct = cn.execute("SELECT AVG(CAST(esta_conciliada AS DECIMAL(5,4))) FROM rpt.fact_conciliacion").fetchone()[0]
    assert Decimal("0.9") < pct < 1
