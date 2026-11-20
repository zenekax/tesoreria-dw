"""Tests del generador de datos sintéticos (Fase 1).

La idea central: el manifiesto `_verdad/errores_inyectados.json` tiene que ser EXACTO.
  1) cada error listado está en el archivo y la línea que dice, con el valor que dice;
  2) toda fila que NO está en el manifiesto cumple todas las reglas de negocio.
Si (1) y (2) se cumplen, en la Fase 5 cualquier fila que los controles marquen y no esté
en el manifiesto es un falso positivo, y cualquier error del manifiesto no marcado es un
falso negativo. Es la "planilla de control" contra la que se audita la calidad.
"""
from __future__ import annotations

import csv
import hashlib
import sys
from collections import Counter, defaultdict
from datetime import date
from decimal import Decimal, InvalidOperation
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import generar_datos as gd  # noqa: E402

ESCALA_TEST = 0.3  # chico para que el test tarde poco; los errores tienen cantidades fijas

ERRORES_ESPERADOS = {
    "bank_statements.DUP_REENVIO": 10, "bank_statements.EXTRACTO_SIN_MATCH": 15,
    "bank_statements.FECHA_INVALIDA": 3, "bank_statements.NULO": 3,
    "collections.COBRANZA_SIN_FACTURA": 5, "collections.DUP_EXACTO": 6,
    "collections.MONEDA_INCONSISTENTE": 5, "collections.MONTO_NEGATIVO": 4, "collections.NULO": 6,
    "counterparties.EMAIL_INVALIDO": 3, "counterparties.NULO": 2, "counterparties.TAX_ID_DUPLICADO": 2,
    "fx_rates.COTIZACION_FALTANTE": 3, "fx_rates.FUERA_DE_RANGO": 2, "fx_rates.NULO": 2,
    "invoices.DUP_LOGICO": 8, "invoices.FORMATO_MONTO": 6, "invoices.MONTO_NEGATIVO": 5,
    "invoices.NULO": 9, "invoices.VENCIMIENTO_ANTERIOR_A_EMISION": 8,
    "payments.CONTRAPARTE_INEXISTENTE": 5, "payments.DUP_EXACTO": 10, "payments.FECHA_FUTURA": 4,
    "payments.FECHA_INVALIDA": 4, "payments.MONEDA_INCONSISTENTE": 8, "payments.MONEDA_INVALIDA": 4,
    "payments.MONTO_NEGATIVO": 8, "payments.NULO": 6, "payments.PAGO_SIN_EXTRACTO": 8,
    "payments.PAGO_SIN_FACTURA": 10,
}


# --------------------------------------------------------------------------- fixtures
# Varias combinaciones seed/escala: un bug que depende del azar (ej.: en qué día cae el 28)
# puede no aparecer con una sola seed. La seed 42 / escala 1 es la del proyecto.
@pytest.fixture(scope="module", params=[(42, 1.0), (42, ESCALA_TEST), (7, 0.5), (2024, 2.0)],
                ids=lambda p: f"seed{p[0]}-escala{p[1]}")
def generado(request, tmp_path_factory):
    seed, escala = request.param
    salida = tmp_path_factory.mktemp("datos")
    manifiesto = gd.generar(salida, escala=escala, seed=seed)
    return salida, manifiesto


@pytest.fixture(scope="module")
def tablas(generado):
    """tabla -> lista de (archivo, linea, fila) leídos de todos los CSV."""
    salida, _ = generado
    out = defaultdict(list)
    for ruta in sorted(salida.rglob("*.csv")):
        rel = ruta.relative_to(salida).as_posix()
        if rel.startswith("_verdad/"):
            continue
        tabla = "counterparties" if "counterparties_" in rel else ruta.stem
        with open(ruta, encoding="utf-8", newline="") as fh:
            for linea, fila in enumerate(csv.DictReader(fh), start=2):
                out[tabla].append((rel, linea, fila))
    return out


@pytest.fixture(scope="module")
def marcadas(generado):
    _, m = generado
    return {(u["archivo"], u["linea"]) for e in m["errores"] for u in e["ubicaciones"]}


@pytest.fixture(scope="module")
def conciliacion(generado):
    salida, _ = generado
    with open(salida / "_verdad" / "conciliacion_esperada.csv", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def limpias(tablas, marcadas, tabla):
    return [f for a, l, f in tablas[tabla] if (a, l) not in marcadas]


def es_fecha(s: str) -> bool:
    try:
        date.fromisoformat(s)
        return len(s) == 10
    except ValueError:
        return False


def es_monto(s: str) -> bool:
    try:
        Decimal(s)
        return s.count(".") == 1 and "," not in s
    except InvalidOperation:
        return False


# --------------------------------------------------------------------------- reproducibilidad
def _hashes(carpeta: Path) -> dict[str, str]:
    return {p.relative_to(carpeta).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(carpeta.rglob("*")) if p.is_file()}


def test_reproducible_byte_a_byte(tmp_path):
    gd.generar(tmp_path / "a", escala=ESCALA_TEST)
    gd.generar(tmp_path / "b", escala=ESCALA_TEST)
    ha, hb = _hashes(tmp_path / "a"), _hashes(tmp_path / "b")
    assert ha.keys() == hb.keys()
    distintos = [k for k in ha if ha[k] != hb[k]]
    assert not distintos, f"archivos distintos entre corridas: {distintos}"


def test_re_ejecutar_sobre_la_misma_carpeta_no_deja_basura(tmp_path):
    gd.generar(tmp_path, escala=ESCALA_TEST)
    (tmp_path / "2099-01").mkdir()          # simula un mes "viejo" de otra corrida
    (tmp_path / "notas.txt").write_text("archivo del usuario")
    gd.generar(tmp_path, escala=ESCALA_TEST)
    assert not (tmp_path / "2099-01").exists()
    assert (tmp_path / "notas.txt").exists(), "no debe borrar archivos que no generó"


# --------------------------------------------------------------------------- manifiesto exacto
def test_cantidad_de_errores_por_tipo(generado):
    _, m = generado
    assert m["errores_por_tipo"] == ERRORES_ESPERADOS
    assert m["total_errores"] == sum(ERRORES_ESPERADOS.values())


def test_un_solo_error_por_fila(generado):
    _, m = generado
    ubic = Counter((u["archivo"], u["linea"]) for e in m["errores"] for u in e["ubicaciones"])
    assert max(ubic.values()) == 1


def test_cada_error_esta_donde_dice(generado, tablas, conciliacion):
    salida, m = generado
    por_ubic = {(a, l): f for filas in tablas.values() for a, l, f in filas}
    ids_conc_erp = {c["erp_id"] for c in conciliacion}
    ids_conc_lin = {c["statement_line_id"] for c in conciliacion}
    for e in m["errores"]:
        t = e["tipo"]
        if t == "COTIZACION_FALTANTE":
            k = e["clave"]
            assert not any(f["rate_date"] == k["rate_date"] and f["currency"] == k["currency"]
                           for _, _, f in tablas["fx_rates"]), e["id"]
            continue
        assert e["ubicaciones"], f"{e['id']} sin ubicación"
        for u in e["ubicaciones"]:
            fila = por_ubic[(u["archivo"], u["linea"])]
            pk, valor_pk = next(iter(e["clave"].items()))
            assert fila[pk] == valor_pk, e["id"]
            if e["campo"]:
                assert fila[e["campo"]] == e["valor_inyectado"], e["id"]
            if t == "DUP_EXACTO":
                mismas = [f for a, _, f in tablas[e["tabla"]] if a == u["archivo"] and f == fila]
                assert len(mismas) == 2, e["id"]
            elif t == "DUP_REENVIO":
                otras = [a for a, _, f in tablas["bank_statements"]
                         if f["statement_line_id"] == valor_pk and a != u["archivo"]]
                assert len(otras) == 1, e["id"]
            elif t == "DUP_LOGICO":
                gemelas = [f for _, _, f in tablas["invoices"] if f["invoice_number"] == fila["invoice_number"]
                           and f["counterparty_id"] == fila["counterparty_id"]]
                assert len(gemelas) == 2, e["id"]
            elif t == "EXTRACTO_SIN_MATCH":
                assert valor_pk not in ids_conc_lin, e["id"]
            elif t == "PAGO_SIN_EXTRACTO":
                assert valor_pk not in ids_conc_erp, e["id"]


# --------------------------------------------------------------------------- filas limpias
def test_facturas_limpias(tablas, marcadas):
    filas = limpias(tablas, marcadas, "invoices")
    assert len({f["invoice_id"] for f in filas}) == len(filas)
    assert len({(f["counterparty_id"], f["invoice_number"]) for f in filas}) == len(filas)
    cps = {f["counterparty_id"] for _, _, f in tablas["counterparties"]}
    for f in filas:
        assert es_monto(f["amount"]) and Decimal(f["amount"]) > 0, f
        assert es_fecha(f["issue_date"]) and es_fecha(f["due_date"]), f
        assert gd.INICIO <= date.fromisoformat(f["issue_date"]) <= gd.FIN, f
        assert f["due_date"] >= f["issue_date"], f
        assert f["currency"] in gd.MONEDAS and f["counterparty_id"] in cps, f


@pytest.mark.parametrize("tabla,pk,fecha", [("payments", "payment_id", "payment_date"),
                                            ("collections", "collection_id", "collection_date")])
def test_pagos_y_cobranzas_limpios(tablas, marcadas, generado, tabla, pk, fecha):
    _, m = generado
    filas = limpias(tablas, marcadas, tabla)
    facturas = {f["invoice_id"]: f for _, _, f in tablas["invoices"]}
    cuentas = {f["account_id"]: f for _, _, f in tablas["bank_accounts"]}
    assert len({f[pk] for f in filas}) == len(filas)
    for f in filas:
        assert es_monto(f["amount"]) and Decimal(f["amount"]) > 0, f
        assert es_fecha(f[fecha]) and gd.INICIO <= date.fromisoformat(f[fecha]) <= gd.FIN, f
        inv = facturas[f["invoice_id"]]                     # la factura existe
        assert f["counterparty_id"] == inv["counterparty_id"], f
        assert f["currency"] == inv["currency"] == cuentas[f["account_id"]]["currency"], f
    # Nunca se paga más que la factura, salvo los dobles pagos plantados como anomalía.
    # (Solo contra facturas limpias: una factura con monto roto a propósito no es referencia.)
    dobles = {a["invoice_id"] for a in m["anomalias_negocio"] if a["tipo"] == "POSIBLE_DOBLE_PAGO"}
    facturas_ok = {f["invoice_id"]: f for f in limpias(tablas, marcadas, "invoices")}
    total = defaultdict(Decimal)
    for f in filas:
        total[f["invoice_id"]] += Decimal(f["amount"])
    for inv_id, pagado in total.items():
        if inv_id in facturas_ok and inv_id not in dobles:
            assert pagado <= Decimal(facturas_ok[inv_id]["amount"]), inv_id


def test_extracto_limpio_y_sin_match_exacto(tablas, marcadas, generado, conciliacion):
    _, m = generado
    filas = limpias(tablas, marcadas, "bank_statements")
    cuentas = {f["account_number"]: f for _, _, f in tablas["bank_accounts"]}
    assert len({f["statement_line_id"] for f in filas}) == len(filas)
    for f in filas:
        assert es_monto(f["amount"]) and Decimal(f["amount"]) != 0, f
        assert es_fecha(f["booking_date"]) and f["currency"] == cuentas[f["account_number"]]["currency"], f
    # Toda transferencia limpia tiene su pago/cobranza: las únicas sin match son las inyectadas.
    en_conc = {c["statement_line_id"] for c in conciliacion}
    sin_match = [f for f in filas if f["bank_tx_code"].startswith("TRF") and f["statement_line_id"] not in en_conc]
    assert not sin_match
    # Y todo pago/cobranza limpio está en el extracto, salvo los que quedaron en tránsito al corte.
    transito = set(m["ruido_conciliacion"].get("payments_en_transito", []) +
                   m["ruido_conciliacion"].get("collections_en_transito", []))
    erp_conc = {c["erp_id"] for c in conciliacion}
    for tabla, pk in (("payments", "payment_id"), ("collections", "collection_id")):
        faltan = [f[pk] for f in limpias(tablas, marcadas, tabla) if f[pk] not in erp_conc | transito]
        assert not faltan, faltan


def test_conciliacion_esperada_consistente(conciliacion, generado):
    _, m = generado
    con_comision = set(m["ruido_conciliacion"]["comision_descontada_del_monto"])
    for c in conciliacion:
        dif = Decimal(c["monto_banco"]) - Decimal(c["monto_erp"])
        assert dif == Decimal(c["diferencia"])
        assert (dif != 0) == (c["erp_id"] in con_comision), c


def test_tipos_de_cambio_completos_y_en_rango(tablas, marcadas):
    filas = limpias(tablas, marcadas, "fx_rates")
    por_moneda = defaultdict(list)
    for f in filas:
        por_moneda[f["currency"]].append(Decimal(f["rate_per_usd"]))
    for moneda, tasas in por_moneda.items():
        mediana = sorted(tasas)[len(tasas) // 2]
        assert all(mediana / 2 < t < mediana * 2 for t in tasas), moneda
    presentes = {(f["rate_date"], f["currency"]) for _, _, f in tablas["fx_rates"]}
    faltan = {(d.isoformat(), c) for d in gd.HABILES for c in gd.MONEDAS} - presentes
    assert len(faltan) == ERRORES_ESPERADOS["fx_rates.COTIZACION_FALTANTE"]


def test_contrapartes_limpias(tablas, marcadas):
    for snapshot in gd.SNAPSHOTS:
        archivo = f"maestros/counterparties_{snapshot.isoformat()}.csv"
        filas = [f for a, l, f in tablas["counterparties"] if a == archivo and (a, l) not in marcadas]
        assert filas
        assert all(f["tax_id"] and "@" in f["email"] for f in filas)
        assert len({f["tax_id"] for f in filas}) == len(filas)


def test_saldos_bancarios_cuadran(tablas, generado):
    """Saldo inicial + movimientos = saldo final, mes a mes. Las líneas reenviadas (duplicadas)
    no cuentan; las que tienen el importe o la fecha rotos cuentan con su valor real."""
    _, m = generado
    reenvios = {(u["archivo"], u["linea"]) for e in m["errores"] if e["tipo"] == "DUP_REENVIO"
                for u in e["ubicaciones"]}
    real = {(u["archivo"], u["linea"]): e["valor_original"] for e in m["errores"]
            if e["tabla"] == "bank_statements" and e["campo"] == "amount" for u in e["ubicaciones"]}
    movs = defaultdict(Decimal)
    for a, l, f in tablas["bank_statements"]:
        if (a, l) not in reenvios:
            movs[(f["account_number"], a[:7])] += Decimal(real.get((a, l), f["amount"]))
    cierre_anterior = {}
    for _, _, s in sorted(tablas["bank_balances"], key=lambda x: (x[2]["account_number"], x[2]["period"])):
        apertura, cierre = Decimal(s["opening_balance"]), Decimal(s["closing_balance"])
        assert apertura + movs[(s["account_number"], s["period"])] == cierre, s
        assert cierre_anterior.get(s["account_number"], apertura) == apertura, s
        assert cierre >= 0, f"cuenta en descubierto: {s}"
        cierre_anterior[s["account_number"]] = cierre


def test_scd2_los_cambios_se_ven_en_el_segundo_snapshot(tablas, generado):
    _, m = generado
    snap = {s: {f["counterparty_id"]: f for a, _, f in tablas["counterparties"]
                if a == f"maestros/counterparties_{s.isoformat()}.csv"} for s in gd.SNAPSHOTS}
    for c in m["cambios_scd2"]:
        assert snap[gd.SNAPSHOTS[0]][c["counterparty_id"]][c["campo"]] == c["antes"]
        assert snap[gd.SNAPSHOTS[1]][c["counterparty_id"]][c["campo"]] == c["despues"]
    nuevas = snap[gd.SNAPSHOTS[1]].keys() - snap[gd.SNAPSHOTS[0]].keys()
    assert len(nuevas) == 5
