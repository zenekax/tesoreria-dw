"""Tests de calidad de datos (Fase 5): ¿los controles detectan TODOS los errores inyectados?

Se mide como una auditoría contra la "planilla de control" de la Fase 1
(data/_verdad/errores_inyectados.json):
- RECALL = de los errores inyectados, cuántos detectó alguna regla. Tiene que ser 100%.
- PRECISIÓN = de lo que detectaron las reglas a nivel fila, cuánto era realmente un error
  inyectado. Lo que sobra (falsos positivos) tiene que estar EXPLICADO, uno por uno.

Corre con dos datasets distintos (seed y escala) para no depender del azar de uno solo.
Además: resultados por regla, cuarentena (qué entra y qué no), ETL sin descartes sin
explicar, totales de control, idempotencia y el circuito "corregir y recargar".
"""
from __future__ import annotations

import csv
import sys
from collections import defaultdict
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import conftest  # noqa: E402
import db  # noqa: E402
import ejecutar_etl as etl  # noqa: E402
import generar_datos as gd  # noqa: E402
from conftest import BASE_TEST  # noqa: E402

# (tabla, tipo de error inyectado, campo) -> regla que tiene que detectarlo
MAPA = {
    ("invoices", "DUP_LOGICO", None): "INV_DUPLICADO_NUMERO",
    ("invoices", "NULO", "amount"): "INV_MONTO_NULO",
    ("invoices", "NULO", "due_date"): "INV_VENC_NULO",
    ("invoices", "VENCIMIENTO_ANTERIOR_A_EMISION", "due_date"): "INV_VENC_ANTES_EMISION",
    ("invoices", "MONTO_NEGATIVO", "amount"): "INV_MONTO_NO_POSITIVO",
    ("invoices", "FORMATO_MONTO", "amount"): "INV_MONTO_FORMATO",
    ("payments", "DUP_EXACTO", None): "PAG_DUPLICADO",
    ("payments", "NULO", "counterparty_id"): "PAG_CONTRAPARTE_NULA",
    ("payments", "FECHA_INVALIDA", "payment_date"): "PAG_FECHA_INVALIDA",
    ("payments", "FECHA_FUTURA", "payment_date"): "PAG_FECHA_FUTURA",
    ("payments", "MONTO_NEGATIVO", "amount"): "PAG_MONTO_NO_POSITIVO",
    ("payments", "MONEDA_INCONSISTENTE", "currency"): "PAG_MONEDA_INCONSISTENTE",
    ("payments", "MONEDA_INVALIDA", "currency"): "PAG_MONEDA_INVALIDA",
    ("payments", "PAGO_SIN_FACTURA", "invoice_id"): "PAG_FACTURA_INEXISTENTE",
    ("payments", "CONTRAPARTE_INEXISTENTE", "counterparty_id"): "PAG_CONTRAPARTE_INEXISTENTE",
    ("payments", "PAGO_SIN_EXTRACTO", None): "PAG_SIN_EXTRACTO",
    ("collections", "DUP_EXACTO", None): "COB_DUPLICADO",
    ("collections", "NULO", "currency"): "COB_MONEDA_NULA",
    ("collections", "MONTO_NEGATIVO", "amount"): "COB_MONTO_NO_POSITIVO",
    ("collections", "MONEDA_INCONSISTENTE", "currency"): "COB_MONEDA_INCONSISTENTE",
    ("collections", "COBRANZA_SIN_FACTURA", "invoice_id"): "COB_FACTURA_INEXISTENTE",
    ("bank_statements", "DUP_REENVIO", None): "EXT_DUPLICADO",
    ("bank_statements", "NULO", "amount"): "EXT_MONTO_NULO",
    ("bank_statements", "FECHA_INVALIDA", "booking_date"): "EXT_FECHA_INVALIDA",
    ("bank_statements", "EXTRACTO_SIN_MATCH", None): "EXT_SIN_MATCH",
    ("counterparties", "EMAIL_INVALIDO", "email"): "CP_EMAIL_INVALIDO",
    ("counterparties", "NULO", "tax_id"): "CP_TAX_ID_NULO",
    ("counterparties", "TAX_ID_DUPLICADO", "tax_id"): "CP_TAX_ID_DUPLICADO",
    ("fx_rates", "NULO", "rate_per_usd"): "TC_NULO",
    ("fx_rates", "FUERA_DE_RANGO", "rate_per_usd"): "TC_FUERA_DE_RANGO",
    ("fx_rates", "COTIZACION_FALTANTE", None): "TC_FALTANTE",
}


def sa():
    return db.conectar(database=BASE_TEST, autocommit=True)


def ultima_dq() -> str:
    with sa() as cn:
        return cn.execute("SELECT TOP 1 ejecucion_id FROM audit.dq_resultados ORDER BY dq_resultado_id DESC").fetchone()[0]


@pytest.fixture(scope="module", params=[(42, 0.3), (7, 0.5)], ids=lambda p: f"seed{p[0]}-escala{p[1]}")
def calidad(request, base_test, tmp_path_factory):
    conftest._borrar_base()   # base limpia por dataset
    conftest.desplegar()
    seed, escala = request.param
    datos = tmp_path_factory.mktemp(f"datos_dq_{seed}")
    manifiesto = gd.generar(datos, escala=escala, seed=seed)
    assert "ERROR" not in cs.cargar(datos, database=BASE_TEST)
    resumen = etl.ejecutar(BASE_TEST)
    ej = ultima_dq()
    with sa() as cn:
        detecciones = [tuple(r) for r in cn.execute(
            "SELECT regla_id, tabla, source_file, source_line, clave, stg_row_id FROM audit.dq_errores "
            "WHERE ejecucion_id = ?", ej)]
    return datos, manifiesto, resumen, ej, detecciones


# --------------------------------------------------------------------------- recall y precisión
def test_recall_100_por_ciento(calidad):
    """Cada error inyectado lo detecta la regla que corresponde, en su archivo y línea."""
    _, m, _, _, detecciones = calidad
    por_ubicacion = defaultdict(set)
    por_clave = defaultdict(set)
    for regla, _, archivo, linea, clave, _ in detecciones:
        if archivo:
            por_ubicacion[(archivo, linea)].add(regla)
        por_clave[clave].add(regla)
    no_detectados, por_categoria = [], defaultdict(lambda: [0, 0])
    for e in m["errores"]:
        regla = MAPA[(e["tabla"], e["tipo"], e["campo"])]
        if e["tipo"] == "COTIZACION_FALTANTE":
            ok = regla in por_clave[f"{e['clave']['rate_date']}|{e['clave']['currency']}"]
        else:
            ok = all(regla in por_ubicacion[(u["archivo"], u["linea"])] for u in e["ubicaciones"])
        por_categoria[e["categoria"]][0] += 1
        por_categoria[e["categoria"]][1] += ok
        if not ok:
            no_detectados.append((e["id"], e["tabla"], e["tipo"], regla, e["ubicaciones"]))
    print("\nrecall por categoría:", {c: f"{d}/{n}" for c, (n, d) in sorted(por_categoria.items())})
    assert not no_detectados, no_detectados


def test_falsos_positivos_explicados(calidad):
    """Toda detección a nivel fila que no es un error inyectado tiene que tener explicación.
    Única explicación aceptada: CP_TAX_ID_DUPLICADO marca a las DOS contrapartes que comparten
    el CUIT/CNPJ (la inyectada y la "pareja"), porque sin papeles no se sabe cuál es la correcta."""
    _, m, _, _, detecciones = calidad
    ubicaciones = {(u["archivo"], u["linea"]) for e in m["errores"] for u in e["ubicaciones"]}
    parejas = {e["descripcion"].split()[-1] for e in m["errores"] if e["tipo"] == "TAX_ID_DUPLICADO"}
    sobrantes = [(r, a, l, c) for r, _, a, l, c, _ in detecciones if a and (a, l) not in ubicaciones]
    no_explicados = [x for x in sobrantes if not (x[0] == "CP_TAX_ID_DUPLICADO" and x[3] in parejas)]
    filas = [d for d in detecciones if d[2]]
    precision = 1 - len(sobrantes) / len(filas)
    print(f"\nprecisión a nivel fila: {precision:.1%} ({len(sobrantes)} falsos positivos explicados de {len(filas)})")
    assert not no_explicados, no_explicados
    assert {x[3] for x in sobrantes} == parejas


# --------------------------------------------------------------------------- resultados y cuarentena
def test_un_resultado_por_regla_activa(calidad):
    *_, ej, detecciones = calidad
    with sa() as cn:
        resultados = {r[0]: (r[1], r[2]) for r in cn.execute(
            "SELECT regla_id, filas_evaluadas, filas_con_error FROM audit.dq_resultados WHERE ejecucion_id = ?", ej)}
        activas = {r[0] for r in cn.execute("SELECT regla_id FROM audit.dq_reglas WHERE activa = 1")}
    assert set(resultados) == activas
    errores_por_regla = defaultdict(int)
    for d in detecciones:
        errores_por_regla[d[0]] += 1
    for regla, (evaluadas, con_error) in resultados.items():
        assert evaluadas >= con_error >= 0, regla
        if not regla.startswith("CTL_"):   # en los controles, "con error" = monedas/cuentas con diferencia
            assert con_error == errores_por_regla[regla], regla


def test_cuarentena_tiene_errores_y_no_advertencias(calidad):
    *_, detecciones = calidad
    with sa() as cn:
        severidad = dict(cn.execute("SELECT regla_id, severidad FROM audit.dq_reglas").fetchall())
        en_cuarentena = set()
        for t in ("invoices", "payments", "collections", "bank_statements", "fx_rates"):
            en_cuarentena |= {(t, r[0]) for r in cn.execute(
                f"SELECT stg_row_id FROM audit.cuarentena_{t} WHERE estado = 'EN_CUARENTENA'")}
            # la fila en cuarentena es copia fiel de staging (con el error adentro)
            distintas = cn.execute(f"""
                SELECT COUNT(*) FROM audit.cuarentena_{t} q JOIN stg.{t} s ON s._row_id = q.stg_row_id
                WHERE s._source_file <> q._source_file OR s._source_line <> q._source_line""").fetchone()[0]
            assert distintas == 0, t
    con_error = {(d[1], d[5]) for d in detecciones if d[5] is not None and severidad[d[0]] == "ERROR"}
    assert en_cuarentena == con_error


def test_etl_sin_descartes_ni_duplicados_sin_explicar(calidad):
    """Con la calidad de datos adelante, el ETL no tiene nada que descartar: todo rechazo
    quedó explicado por una regla y está en cuarentena."""
    _, _, resumen, _, _ = calidad
    cargas = [r for r in resumen if r["proceso"].startswith("dw.usp_load_")]
    assert all(r["estado"] == "OK" and r["filas_descartadas"] == 0 and r["filas_duplicadas"] == 0 for r in cargas), cargas


def test_nada_en_cuarentena_llega_al_dw(calidad):
    with sa() as cn:
        for t, tdw, cstg, cdw in [("invoices", "fact_facturas", "invoice_id", "factura_id"),
                                  ("payments", "fact_pagos", "payment_id", "pago_id"),
                                  ("collections", "fact_cobranzas", "collection_id", "cobranza_id"),
                                  ("bank_statements", "fact_movimientos_bancarios", "statement_line_id",
                                   "linea_extracto_id")]:
            # (las copias duplicadas sí comparten clave con la fila buena que entró: se excluyen)
            n = cn.execute(f"""SELECT COUNT(*) FROM audit.cuarentena_{t} q JOIN dw.{tdw} f ON f.{cdw} = q.{cstg}
                               WHERE q.estado = 'EN_CUARENTENA' AND q.reglas NOT LIKE '%DUPLICADO%'""").fetchone()[0]
            assert n == 0, t


def test_totales_de_control(calidad):
    datos, m, _, ej, _ = calidad
    with sa() as cn:
        ctl = dict(cn.execute("SELECT regla_id, filas_con_error FROM audit.dq_resultados "
                              "WHERE ejecucion_id = ? AND regla_id LIKE 'CTL[_]%'", ej).fetchall())
        saldo = {r[0] for r in cn.execute("SELECT clave FROM audit.dq_errores WHERE ejecucion_id = ? "
                                          "AND regla_id = 'CTL_SALDO_EXTRACTO'", ej)}
    assert all(v == 0 for k, v in ctl.items() if k != "CTL_SALDO_EXTRACTO"), ctl
    # El saldo del banco no se explica exactamente en las cuentas-mes que tienen una línea en cuarentena
    # por importe en blanco o fecha rota (la plata se movió, pero el DW no la tiene).
    esperado = set()
    for e in m["errores"]:
        if e["tabla"] == "bank_statements" and e["tipo"] in ("NULO", "FECHA_INVALIDA"):
            u = e["ubicaciones"][0]
            fila = list(csv.DictReader(open(datos / u["archivo"], encoding="utf-8")))[u["linea"] - 2]
            esperado.add(f"{fila['account_number']}|{u['archivo'][:7]}")
    assert saldo == esperado


# --------------------------------------------------------------------------- operación
def test_reejecutar_no_cambia_nada(calidad):
    *_, ej, detecciones = calidad
    resumen = etl.ejecutar(BASE_TEST)
    dq = next(r for r in resumen if r["proceso"] == "audit.usp_dq_validar_staging")
    assert "nuevas=0, liberadas=0" in dq["mensaje"]
    cargas = [r for r in resumen if r["proceso"].startswith("dw.usp_load_")]
    assert all(r["filas_insertadas"] == 0 and r["filas_actualizadas"] == 0 and not r["filas_eliminadas"]
               for r in cargas)
    with sa() as cn:
        ej2 = ultima_dq()
        n2 = cn.execute("SELECT COUNT(*) FROM audit.dq_errores WHERE ejecucion_id = ?", ej2).fetchone()[0]
    assert n2 == len(detecciones)


def test_corregir_y_recargar_libera_de_cuarentena(calidad):
    """El circuito real: el área corrige el archivo, se recarga, la fila sale de cuarentena
    (queda LIBERADA, no se borra) y el pago entra al DW."""
    datos, m, *_ = calidad
    err = next(e for e in m["errores"] if e["tabla"] == "payments" and e["tipo"] == "MONTO_NEGATIVO")
    u, pago = err["ubicaciones"][0], err["clave"]["payment_id"]
    ruta = datos / u["archivo"]
    filas = list(csv.reader(open(ruta, encoding="utf-8")))
    filas[u["linea"] - 1][filas[0].index("amount")] = err["valor_original"]   # corrección del área de pagos
    with open(ruta, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh, lineterminator="\n").writerows(filas)
    with sa() as cn:
        vigentes_antes = cn.execute("SELECT COUNT(*) FROM audit.cuarentena_payments WHERE estado = 'EN_CUARENTENA'").fetchone()[0]
        assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos WHERE pago_id = ?", pago).fetchone()[0] == 0

    assert cs.cargar(datos, database=BASE_TEST).get("REEMPLAZADO") == [u["archivo"]]
    etl.ejecutar(BASE_TEST, completa=True)

    with sa() as cn:
        estados = {r[0] for r in cn.execute("SELECT estado FROM audit.cuarentena_payments WHERE payment_id = ?", pago)}
        vigentes = cn.execute("SELECT COUNT(*) FROM audit.cuarentena_payments WHERE estado = 'EN_CUARENTENA'").fetchone()[0]
        en_dw = cn.execute("SELECT monto FROM dw.fact_pagos WHERE pago_id = ?", pago).fetchone()
    assert estados == {"LIBERADA"}, "la fila corregida sale de cuarentena pero queda en el historial"
    assert vigentes == vigentes_antes - 1, "los demás errores del mismo archivo siguen en cuarentena"
    assert en_dw is not None and str(en_dw[0]) == err["valor_original"]
