"""Tests de la Fase 6: conciliación automática y consultas de análisis.

La conciliación se mide contra la "conciliación perfecta" que dejó el generador
(data/_verdad/conciliacion_esperada.csv): precisión y recall de los pares libro-banco.
Las consultas se validan contra cálculos independientes o contra lo plantado en la Fase 1
(anomalías), no solo "que corran".
"""
from __future__ import annotations

import csv
import sys
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

import pyodbc
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import db  # noqa: E402
import ejecutar_etl as etl  # noqa: E402
import generar_datos as gd  # noqa: E402
from conftest import BASE_TEST, codigo_error  # noqa: E402
from ejecutar_sql import ejecutar_script  # noqa: E402

CONSULTAS = sorted(p.name for p in (db.RAIZ / "sql" / "06_queries").glob("*.sql"))


def sa():
    return db.conectar(database=BASE_TEST, autocommit=True)


def correr(nombre: str) -> list[list[dict]]:
    with sa() as cn:
        return ejecutar_script(cn, f"sql/06_queries/{nombre}", BASE_TEST)


@pytest.fixture(scope="module")
def entorno(base_limpia, tmp_path_factory):
    datos = tmp_path_factory.mktemp("datos_analisis")
    manifiesto = gd.generar(datos, escala=0.3)
    assert "ERROR" not in cs.cargar(datos, database=BASE_TEST)
    etl.ejecutar(BASE_TEST)
    verdad = list(csv.DictReader(open(datos / "_verdad" / "conciliacion_esperada.csv", encoding="utf-8")))
    return datos, manifiesto, verdad


# --------------------------------------------------------------------------- conciliación
def test_conciliacion_precision_y_recall_100(entorno):
    _, _, verdad = entorno
    with sa() as cn:
        conciliado = {r[0]: r[1] for r in cn.execute(
            "SELECT COALESCE(pago_id, cobranza_id), linea_extracto_id FROM dw.fact_conciliacion "
            "WHERE estado LIKE 'CONCILIADA%'")}
        erp = {r[0] for r in cn.execute("SELECT pago_id FROM dw.fact_pagos UNION ALL SELECT cobranza_id FROM dw.fact_cobranzas")}
        lineas = {r[0] for r in cn.execute("SELECT linea_extracto_id FROM dw.fact_movimientos_bancarios")}
    esperado = {v["erp_id"]: v["statement_line_id"] for v in verdad
                if v["erp_id"] in erp and v["statement_line_id"] in lineas}
    correctos = sum(1 for k, v in conciliado.items() if esperado.get(k) == v)
    print(f"\nconciliación: {correctos} correctos / {len(conciliado)} conciliados / {len(esperado)} esperados")
    assert correctos == len(conciliado) == len(esperado)


def test_pendientes_explicados(entorno):
    """Lo que queda pendiente es exactamente lo que no tiene pareja en el DW: el pago cuya
    línea del banco no existe (rechazado, en tránsito o en cuarentena) y la línea del banco
    cuyo pago/cobranza no existe (nadie lo registró o está en cuarentena)."""
    _, _, verdad = entorno
    linea_de = {v["erp_id"]: v["statement_line_id"] for v in verdad}
    erp_de = {v["statement_line_id"]: v["erp_id"] for v in verdad}
    with sa() as cn:
        erp = {r[0] for r in cn.execute("SELECT pago_id FROM dw.fact_pagos UNION ALL SELECT cobranza_id FROM dw.fact_cobranzas")}
        lineas = {r[0] for r in cn.execute(
            "SELECT m.linea_extracto_id FROM dw.fact_movimientos_bancarios m JOIN dw.dim_tipo_movimiento t "
            "ON t.tipo_movimiento_key = m.tipo_movimiento_key WHERE t.es_conciliable = 1")}
        pend_banco = {r[0] for r in cn.execute("SELECT COALESCE(pago_id, cobranza_id) FROM dw.fact_conciliacion "
                                               "WHERE estado = 'PENDIENTE_EN_BANCO'")}
        pend_libros = {r[0] for r in cn.execute("SELECT linea_extracto_id FROM dw.fact_conciliacion "
                                                "WHERE estado = 'PENDIENTE_EN_LIBROS'")}
    assert pend_banco == {e for e in erp if linea_de.get(e) not in lineas}
    assert pend_libros == {l for l in lineas if erp_de.get(l) not in erp}


def test_estados_y_diferencias(entorno):
    _, m, _ = entorno
    con_comision = set(m["ruido_conciliacion"]["comision_descontada_del_monto"])
    with sa() as cn:
        filas = cn.execute("SELECT COALESCE(pago_id, cobranza_id), estado, diferencia, metodo_match, "
                           "dias_habiles_desfase FROM dw.fact_conciliacion WHERE estado LIKE 'CONCILIADA%'").fetchall()
    for erp_id, estado, dif, metodo, desfase in filas:
        assert (estado == "CONCILIADA_CON_DIFERENCIA") == (erp_id in con_comision), erp_id
        assert metodo in ("REFERENCIA", "MONTO_FECHA") and 0 <= desfase <= 3
        assert (dif != 0) == (estado == "CONCILIADA_CON_DIFERENCIA")


def test_conciliar_es_idempotente(entorno):
    with sa() as cn:
        antes = sorted(tuple(r) for r in cn.execute(
            "SELECT origen, pago_id, cobranza_id, linea_extracto_id, estado, monto_libro, monto_banco, "
            "fecha_conciliacion_key FROM dw.fact_conciliacion"))
    resumen = etl.ejecutar(BASE_TEST)
    conc = next(r for r in resumen if r["proceso"] == "dw.usp_conciliar")
    assert conc["filas_actualizadas"] == 0
    with sa() as cn:
        despues = sorted(tuple(r) for r in cn.execute(
            "SELECT origen, pago_id, cobranza_id, linea_extracto_id, estado, monto_libro, monto_banco, "
            "fecha_conciliacion_key FROM dw.fact_conciliacion"))
    assert despues == antes


# --------------------------------------------------------------------------- consultas
@pytest.mark.parametrize("nombre", CONSULTAS)
def test_cada_consulta_corre_y_devuelve_datos(entorno, nombre):
    resultados = correr(nombre)
    # Al menos un resultado con filas. (Que una regla de anomalías no encuentre nada es un
    # resultado válido: "clientes que empeoran" no se planta en los datos.)
    assert resultados and any(len(r) > 0 for r in resultados), nombre
    if nombre != "05_anomalias.sql":
        assert all(len(r) > 0 for r in resultados), nombre


def test_aging_cuadra_con_calculo_independiente(entorno):
    tramos, _, por_moneda = correr("02_aging_cobranzas.sql")
    assert [t["tramo"] for t in tramos] == ["0 no vencido", "1 de 1 a 30", "2 de 31 a 60", "3 de 61 a 90", "4 mas de 90"]
    assert sum(t["saldo_usd"] for t in tramos) == sum(m["saldo_usd"] for m in por_moneda)
    assert tramos[-1]["saldo_acumulado_usd"] == sum(t["saldo_usd"] for t in tramos)
    with sa() as cn:   # saldo por factura calculado en Python, sin la lógica de la consulta
        facturas = {r[0]: (r[1], r[2]) for r in cn.execute(
            "SELECT f.factura_id, m.codigo_iso, f.monto FROM dw.fact_facturas f JOIN dw.dim_moneda m "
            "ON m.moneda_key = f.moneda_key WHERE f.tipo_factura = 'AR' AND f.fecha_emision_key <= 20261031")}
        cobrado = defaultdict(Decimal)
        for fid, monto in cn.execute("SELECT factura_id, monto FROM dw.fact_cobranzas WHERE fecha_cobranza_key <= 20261031"):
            cobrado[fid] += monto
    esperado = defaultdict(Decimal)
    for fid, (moneda, monto) in facturas.items():
        if monto - cobrado[fid] > 0:
            esperado[moneda] += monto - cobrado[fid]
    assert {m["moneda"]: m["saldo_moneda_origen"] for m in por_moneda} == dict(esperado)


def test_flujo_de_caja_cuadra_con_el_banco_salvo_cuarentena(entorno):
    """El saldo de cierre del flujo diario difiere del saldo que informa el banco EXACTAMENTE en
    la plata de las líneas que quedaron en cuarentena (importe en blanco o fecha rota)."""
    datos, m, _ = entorno
    diario, _ = correr("03_flujo_caja_diario.sql")
    cierre = {d["moneda"]: d["saldo_cierre"] for d in diario if str(d["fecha"]) == "2026-10-31"}
    with sa() as cn:
        banco = dict(cn.execute("SELECT mo.codigo_iso, SUM(s.saldo_final) FROM dw.fact_saldo_bancario_mensual s "
                                "JOIN dw.dim_moneda mo ON mo.moneda_key = s.moneda_key "
                                "WHERE s.fecha_cierre_key = 20261031 GROUP BY mo.codigo_iso").fetchall())
    faltante = defaultdict(Decimal)
    for e in m["errores"]:
        if e["tabla"] == "bank_statements" and e["tipo"] in ("NULO", "FECHA_INVALIDA"):
            u = e["ubicaciones"][0]
            fila = list(csv.DictReader(open(datos / u["archivo"], encoding="utf-8")))[u["linea"] - 2]
            faltante[fila["currency"]] += Decimal(e["valor_original"] if e["campo"] == "amount" else fila["amount"])
    for moneda, saldo_banco in banco.items():
        assert saldo_banco - cierre[moneda] == faltante[moneda], moneda


def test_top_contrapartes_concentracion(entorno):
    top, cuartiles, ultimos = correr("04_top_contrapartes.sql")
    for flujo in ("PAGOS", "COBRANZAS"):
        filas = [c for c in cuartiles if c["flujo"] == flujo]
        assert [c["cuartil"] for c in filas] == [1, 2, 3, 4]
        assert abs(sum(c["pct"] for c in filas) - 100) <= Decimal("0.05")
        puestos = [t for t in top if t["flujo"] == flujo]
        assert [t["pct_acumulado"] for t in puestos] == sorted(t["pct_acumulado"] for t in puestos)
    assert len(ultimos) <= 15 and all(u["puesto"] <= 5 for u in ultimos)


def test_anomalias_plantadas_detectadas(entorno):
    _, m, _ = entorno
    atipicos, dobles, pagadas_de_mas, _ = correr("05_anomalias.sql")
    plantados_atipicos = {p for a in m["anomalias_negocio"] if a["tipo"] == "PAGO_ATIPICO" for p in a["payment_ids"]}
    plantados_dobles = {tuple(a["payment_ids"]) for a in m["anomalias_negocio"] if a["tipo"] == "POSIBLE_DOBLE_PAGO"}
    detectados_atipicos = {a["pago_id"] for a in atipicos}
    detectados_dobles = {(d["primer_pago"], d["segundo_pago"]) for d in dobles}
    print(f"\natípicos: {len(detectados_atipicos)} detectados ({len(detectados_atipicos - plantados_atipicos)} no plantados);"
          f" dobles: {len(detectados_dobles)} ({len(detectados_dobles - plantados_dobles)} no plantados)")
    assert plantados_atipicos <= detectados_atipicos
    assert plantados_dobles <= detectados_dobles
    facturas_dobles = {a["invoice_id"] for a in m["anomalias_negocio"] if a["tipo"] == "POSIBLE_DOBLE_PAGO"}
    assert facturas_dobles <= {p["factura_id"] for p in pagadas_de_mas}


def test_pivot_dinamico_totales_y_columnas(entorno):
    resultados = correr("06_pivot_dinamico_seguro.sql")
    pagos = resultados[0]
    meses = [c for c in pagos[0] if c[:2] == "20"]
    assert meses == [f"2025-{m}" for m in ("11", "12")] + [f"2026-{m:02d}" for m in range(1, 11)]
    for fila in pagos:
        assert sum(fila[c] for c in meses) == fila["total_usd"]
    with sa() as cn:
        total = cn.execute("SELECT SUM(monto_usd) FROM dw.fact_pagos WHERE contraparte_key > 0 "
                           "AND fecha_pago_key BETWEEN 20251101 AND 20261031").fetchone()[0]
    assert sum(f["total_usd"] for f in pagos) == total


@pytest.mark.parametrize("parametros,codigo", [
    ("@flujo = 'PAGOS; DROP TABLE dw.fact_pagos --'", 50020),       # el flujo no se concatena: lista blanca
    ("@flujo = 'PAGOS', @moneda = N'ARS'' OR 1=1 --'", 50022),       # la moneda viaja como parámetro
    ("@flujo = 'PAGOS', @desde = '2026-10-01', @hasta = '2026-01-01'", 50021),
])
def test_pivot_dinamico_rechaza_entradas_maliciosas_o_invalidas(entorno, parametros, codigo):
    with sa() as cn:
        with pytest.raises(pyodbc.Error) as exc:
            cn.execute(f"EXEC dw.usp_reporte_mensual {parametros}").fetchall()
        assert cn.execute("SELECT OBJECT_ID('dw.fact_pagos')").fetchone()[0] is not None
    assert codigo_error(exc.value) == codigo


def test_evolucion_recursiva_coherente_con_aging(entorno):
    (serie,) = correr("07_evolucion_cartera_recursiva.sql")
    tramos, _, _ = correr("02_aging_cobranzas.sql")
    assert [str(s["cierre"]) for s in serie][0] == "2025-11-30" and str(serie[-1]["cierre"]) == "2026-10-31"
    assert len(serie) == 12
    assert serie[-1]["facturas_abiertas"] == sum(t["facturas"] for t in tramos)
