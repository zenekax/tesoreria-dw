"""Tests de integración del ETL en T-SQL (Fase 4).

Base propia y limpia (se recrea al empezar el módulo): datos de escala 0.3 -> staging ->
dw.usp_run_etl ejecutado con el usuario de mínimo privilegio, como en producción.

Qué se prueba:
- cada paso termina OK y sus conteos cuadran (leídas = insertadas + descartadas + duplicadas);
- lo que NO entra al DW es exactamente lo que el manifiesto dice que viola reglas del DW;
- idempotencia: re-ejecutar no cambia ni una celda;
- incremental: cargar por partes (hasta marzo, después el resto) da lo mismo que cargar todo;
- SCD2: cada hecho apunta a la versión de la contraparte vigente en SU fecha;
- conversión a USD con el último tipo de cambio disponible;
- manejo de errores: un fallo a mitad de un paso revierte ese paso, queda en audit.etl_log
  con número de error, y el orquestador frena (fail fast);
- permisos: el ETL solo puede ejecutar el orquestador.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

import pyodbc
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cargar_staging as cs  # noqa: E402
import db  # noqa: E402
import ejecutar_etl as etl  # noqa: E402
import generar_datos as gd  # noqa: E402
from conftest import BASE_TEST, codigo_error  # noqa: E402

HECHOS = ["fact_tipo_cambio", "fact_facturas", "fact_pagos", "fact_cobranzas", "fact_movimientos_bancarios",
          "fact_saldo_bancario_mensual", "fact_conciliacion"]
# Errores del manifiesto que violan reglas del DW y por eso NO deben entrar (el resto entra
# y lo ataja la Fase 5). tabla de staging -> (columna id, tipos de error)
NO_ENTRAN = {
    "invoices": ("invoice_id", {"NULO", "VENCIMIENTO_ANTERIOR_A_EMISION", "MONTO_NEGATIVO", "FORMATO_MONTO"}),
    "payments": ("payment_id", {"FECHA_INVALIDA", "MONTO_NEGATIVO", "MONEDA_INVALIDA"}),
    "collections": ("collection_id", {"NULO", "MONTO_NEGATIVO"}),
    "bank_statements": ("statement_line_id", {"NULO", "FECHA_INVALIDA"}),
}
DESTINO = {"invoices": ("fact_facturas", "factura_id"), "payments": ("fact_pagos", "pago_id"),
           "collections": ("fact_cobranzas", "cobranza_id"),
           "bank_statements": ("fact_movimientos_bancarios", "linea_extracto_id")}


def sa():
    return db.conectar(database=BASE_TEST, autocommit=True)


def correr(**kw) -> list[dict]:
    # Sin las reglas de calidad (Fase 5): acá se prueba el ETL solo, con sus propios descartes.
    # La combinación ETL + calidad se prueba en test_calidad.py.
    return etl.ejecutar(BASE_TEST, validar_calidad=False, **kw)


def foto_dw() -> dict[str, list[tuple]]:
    """Contenido de negocio de todo el DW: sin claves IDENTITY de hechos ni fechas de auditoría
    (*_dw), que cambian en cada carga aunque el dato sea el mismo."""
    out = {}
    with sa() as cn:
        for t in ["dim_banco_cuenta", "dim_contraparte"] + HECHOS:
            cols = [r[0] for r in cn.execute(
                "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID(?) AND c.name NOT LIKE '%[_]dw' "
                "AND NOT (c.is_identity = 1 AND ? LIKE 'fact[_]%') ORDER BY c.column_id", f"dw.{t}", t)]
            out[t] = sorted(tuple(r) for r in cn.execute(f"SELECT {', '.join(cols)} FROM dw.{t}"))
    return out


def vaciar_dw():
    """Deja el DW como recién desplegado (dimensiones estáticas incluidas) y las claves
    IDENTITY de las dimensiones arrancando de nuevo en 1."""
    with sa() as cn:
        for t in reversed(HECHOS):
            cn.execute(f"DELETE FROM dw.{t}")
        cn.execute("DELETE FROM dw.dim_contraparte WHERE contraparte_key > 0")
        cn.execute("DELETE FROM dw.dim_banco_cuenta WHERE banco_cuenta_key > 0")
        cn.execute("DBCC CHECKIDENT ('dw.dim_contraparte', RESEED, 0) WITH NO_INFOMSGS")
        cn.execute("DBCC CHECKIDENT ('dw.dim_banco_cuenta', RESEED, 0) WITH NO_INFOMSGS")
        cn.execute("DELETE FROM audit.etl_marca_agua")


@pytest.fixture(scope="module")
def cargado(base_limpia, tmp_path_factory):
    datos = tmp_path_factory.mktemp("datos_etl")
    manifiesto = gd.generar(datos, escala=0.3)
    assert "ERROR" not in cs.cargar(datos, database=BASE_TEST)
    resumen = correr()
    return datos, manifiesto, resumen


# --------------------------------------------------------------------------- primera carga
def test_todos_los_pasos_ok(cargado):
    _, _, resumen = cargado
    assert [r["estado"] for r in resumen] == ["OK"] * 10
    assert resumen[0]["proceso"] == "dw.usp_run_etl"


def test_conteos_cuadran_por_paso(cargado):
    """Total de control de cada paso: todo lo leído se explica (entró, se descartó o era duplicado)."""
    _, _, resumen = cargado
    for r in resumen[1:]:
        if r["proceso"] in ("dw.usp_load_dim_contraparte", "dw.usp_load_fact_conciliacion"):
            continue  # la dimensión SCD2 inserta versiones; la conciliación lee desde el DW, no de staging
        assert r["filas_leidas"] == (r["filas_insertadas"] + r["filas_actualizadas"] + r["filas_descartadas"]
                                     + r["filas_duplicadas"]), r


@pytest.mark.parametrize("tabla_stg", list(NO_ENTRAN))
def test_lo_que_no_entra_es_exactamente_lo_esperado(cargado, tabla_stg):
    _, m, _ = cargado
    col, tipos = NO_ENTRAN[tabla_stg]
    destino, col_dw = DESTINO[tabla_stg]
    esperado = {e["clave"][col] for e in m["errores"] if e["tabla"] == tabla_stg and e["tipo"] in tipos}
    with sa() as cn:
        faltan = {r[0] for r in cn.execute(
            f"SELECT DISTINCT s.{col} FROM stg.{tabla_stg} s WHERE s.{col} IS NOT NULL "
            f"AND NOT EXISTS (SELECT 1 FROM dw.{destino} d WHERE d.{col_dw} = s.{col})")}
    assert faltan == esperado


def test_tipo_de_cambio_vacio_no_entra(cargado):
    _, m, _ = cargado
    nulos = [e["clave"] for e in m["errores"] if e["tabla"] == "fx_rates" and e["tipo"] == "NULO"]
    with sa() as cn:
        for k in nulos:
            n = cn.execute("SELECT COUNT(*) FROM dw.fact_tipo_cambio t JOIN dw.dim_moneda m ON m.moneda_key = t.moneda_key "
                           "WHERE t.fecha_key = CONVERT(INT, CONVERT(CHAR(8), CAST(? AS DATE), 112)) AND m.codigo_iso = ?",
                           k["rate_date"], k["currency"]).fetchone()[0]
            assert n == 0


def test_duplicados_entran_una_sola_vez(cargado):
    _, m, resumen = cargado
    dups = defaultdict(int)
    for e in m["errores"]:
        if e["tipo"] in ("DUP_EXACTO", "DUP_REENVIO"):
            dups[e["tabla"]] += 1
    log = {r["proceso"]: r["filas_duplicadas"] for r in resumen}
    assert log["dw.usp_load_fact_pagos"] == dups["payments"]
    assert log["dw.usp_load_fact_cobranzas"] == dups["collections"]
    assert log["dw.usp_load_fact_movimientos_bancarios"] == dups["bank_statements"]


def test_contraparte_inexistente_o_nula_va_al_miembro_desconocido(cargado):
    _, m, _ = cargado
    ids = {e["clave"]["payment_id"] for e in m["errores"] if e["tabla"] == "payments"
           and e["tipo"] in ("CONTRAPARTE_INEXISTENTE", "NULO") and e["campo"] == "counterparty_id"}
    with sa() as cn:
        en_menos_uno = {r[0] for r in cn.execute("SELECT pago_id FROM dw.fact_pagos WHERE contraparte_key = -1")}
    assert en_menos_uno == ids


# --------------------------------------------------------------------------- reglas de negocio de la carga
@pytest.mark.parametrize("hecho,fecha", [("fact_facturas", "fecha_emision_key"), ("fact_pagos", "fecha_pago_key"),
                                         ("fact_cobranzas", "fecha_cobranza_key")])
def test_scd2_cada_hecho_apunta_a_la_version_vigente_en_su_fecha(cargado, hecho, fecha):
    with sa() as cn:
        malas = cn.execute(f"""
            SELECT COUNT(*) FROM dw.{hecho} h
            JOIN dw.dim_contraparte d ON d.contraparte_key = h.contraparte_key
            JOIN dw.dim_fecha f ON f.fecha_key = h.{fecha}
            WHERE d.contraparte_key > 0 AND f.fecha NOT BETWEEN d.vigente_desde AND d.vigente_hasta""").fetchone()[0]
        con_dos_versiones = cn.execute(f"""
            SELECT COUNT(DISTINCT h.contraparte_key) FROM dw.{hecho} h
            JOIN dw.dim_contraparte d ON d.contraparte_key = h.contraparte_key
            WHERE d.contraparte_id IN (SELECT contraparte_id FROM dw.dim_contraparte GROUP BY contraparte_id
                                       HAVING COUNT(*) > 1)""").fetchone()[0]
    assert malas == 0
    assert con_dos_versiones > 0, "el test tiene que cubrir contrapartes con historia"


def test_scd2_versiones_segun_manifiesto(cargado):
    _, m, _ = cargado
    traduce = {"LOW": "BAJO", "MEDIUM": "MEDIO", "HIGH": "ALTO", "STRATEGIC": "ESTRATEGICO",
               "ENTERPRISE": "CORPORATIVO", "SME": "PYME", "Y": True, "N": False}
    columna = {"risk_rating": "calificacion_riesgo", "segment": "segmento", "payment_terms_days": "plazo_pago_dias",
               "is_active": "activa", "email": "email"}
    with sa() as cn:
        for c in m["cambios_scd2"]:
            col = columna[c["campo"]]
            versiones = cn.execute(f"SELECT vigente_desde, vigente_hasta, {col} FROM dw.dim_contraparte "
                                   "WHERE contraparte_id = ? ORDER BY vigente_desde", c["counterparty_id"]).fetchall()
            valor = lambda v: traduce.get(v, int(v) if v.isdigit() else v)  # noqa: E731
            if c["tipo_scd"] == 2:
                assert len(versiones) == 2, c
                assert versiones[0][1] == date(2026, 4, 30) and versiones[1][0] == date(2026, 5, 1), c
                assert (versiones[0][2], versiones[1][2]) == (valor(c["antes"]), valor(c["despues"])), c
            else:  # tipo 1: una sola versión con el dato corregido
                assert [v[2] for v in versiones] == [c["despues"]], c


def test_conversion_a_usd_con_el_ultimo_tipo_de_cambio(cargado):
    with sa() as cn:
        malas = cn.execute("""
            SELECT COUNT(*) FROM dw.fact_pagos p
            CROSS APPLY (SELECT TOP (1) t.tipo_cambio_por_usd FROM dw.fact_tipo_cambio t
                         WHERE t.moneda_key = p.moneda_key AND t.fecha_key <= p.fecha_pago_key
                         ORDER BY t.fecha_key DESC) tc
            WHERE p.tipo_cambio_usd <> tc.tipo_cambio_por_usd
               OR p.monto_usd <> ROUND(p.monto / p.tipo_cambio_usd, 2)""").fetchone()[0]
    assert malas == 0


def test_partidas_de_conciliacion(cargado):
    with sa() as cn:
        partidas = dict(cn.execute("SELECT origen, COUNT(*) FROM dw.fact_conciliacion GROUP BY origen").fetchall())
        pagos = cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0]
        cobranzas = cn.execute("SELECT COUNT(*) FROM dw.fact_cobranzas").fetchone()[0]
        transferencias = cn.execute("SELECT COUNT(*) FROM dw.fact_movimientos_bancarios m JOIN dw.dim_tipo_movimiento t "
                                    "ON t.tipo_movimiento_key = m.tipo_movimiento_key WHERE t.es_conciliable = 1").fetchone()[0]
        estados = {r[0] for r in cn.execute("SELECT DISTINCT estado FROM dw.fact_conciliacion")}
    assert partidas == {"PAGO": pagos, "COBRANZA": cobranzas, "BANCO": transferencias}
    assert estados == {"PENDIENTE_EN_BANCO", "PENDIENTE_EN_LIBROS"}, "el matching es de la Fase 6"


# --------------------------------------------------------------------------- idempotencia e incremental
def test_re_ejecutar_no_cambia_nada(cargado):
    antes = foto_dw()
    for completa in (False, True):   # incremental y completa: ninguna escribe nada
        resumen = correr(completa=completa)
        assert all(r["filas_insertadas"] in (0, None) and r["filas_actualizadas"] in (0, None) for r in resumen)
    assert foto_dw() == antes


def test_carga_incremental_por_partes_igual_a_completa(cargado):
    completa = foto_dw()
    vaciar_dw()
    r1 = correr(hasta=date(2026, 3, 31))
    pagos_hasta_marzo = next(r for r in r1 if r["proceso"] == "dw.usp_load_fact_pagos")["filas_insertadas"]
    assert 0 < pagos_hasta_marzo < len(completa["fact_pagos"])
    with sa() as cn:
        ultimo_pago = cn.execute("SELECT MAX(f.fecha) FROM dw.fact_pagos p "
                                 "JOIN dw.dim_fecha f ON f.fecha_key = p.fecha_pago_key").fetchone()[0]
    assert ultimo_pago <= date(2026, 3, 31)
    r2 = correr()                     # incremental: desde la marca de agua - 7 días
    ventana = next(r for r in r2 if r["proceso"] == "dw.usp_load_fact_pagos")
    assert (ultimo_pago - ventana["fecha_desde"]).days == 7
    assert foto_dw() == completa


# --------------------------------------------------------------------------- errores y permisos
def test_error_a_mitad_de_paso_revierte_y_queda_en_log(cargado):
    with sa() as cn:
        # Se borran 20 pagos grandes del DW y se agrega una regla que el re-insert va a violar.
        cn.execute("DELETE p FROM dw.fact_pagos p WHERE p.pago_id IN "
                   "(SELECT TOP (20) pago_id FROM dw.fact_pagos WHERE monto >= 1000 ORDER BY pago_id)")
        antes = cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0]
        cn.execute("ALTER TABLE dw.fact_pagos WITH NOCHECK ADD CONSTRAINT ck_test_falla CHECK (monto < 1000)")
    try:
        with pytest.raises(pyodbc.Error) as exc:
            correr(completa=True)
        assert codigo_error(exc.value) == 547
        with sa() as cn:
            assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0] == antes, "rollback del paso entero"
            ej = cn.execute("SELECT TOP 1 ejecucion_id FROM audit.etl_log ORDER BY etl_log_id DESC").fetchone()[0]
            log = {p: (e, n) for p, e, n in cn.execute(
                "SELECT proceso, estado, error_numero FROM audit.etl_log WHERE ejecucion_id = ?", ej)}
        assert log["dw.usp_load_fact_pagos"] == ("ERROR", 547)
        assert log["dw.usp_run_etl"] == ("ERROR", 547)
        assert "dw.usp_load_fact_cobranzas" not in log, "fail fast: no sigue con los pasos siguientes"
    finally:
        with sa() as cn:
            cn.execute("ALTER TABLE dw.fact_pagos DROP CONSTRAINT ck_test_falla")
    # Arreglada la causa, se vuelve a correr. Los 20 pagos borrados son de fechas viejas, FUERA de
    # la ventana incremental (marca de agua - 7 días): para recuperarlos hace falta la carga completa.
    # Es la lección operativa: el incremental no repara huecos viejos.
    correr(completa=True)
    with sa() as cn:
        assert cn.execute("SELECT COUNT(*) FROM dw.fact_pagos").fetchone()[0] == antes + 20


def test_parametros_invalidos_quedan_en_log(cargado):
    with pytest.raises(pyodbc.Error) as exc:
        correr(desde=date(2026, 5, 1), hasta=date(2026, 1, 1))
    assert codigo_error(exc.value) == 50001
    with sa() as cn:
        fila = cn.execute("SELECT TOP 1 proceso, estado, error_numero FROM audit.etl_log ORDER BY etl_log_id DESC").fetchone()
    assert tuple(fila) == ("dw.usp_run_etl", "ERROR", 50001)


@pytest.mark.parametrize("sentencia", [
    "EXEC dw.usp_load_fact_pagos",          # solo puede ejecutar el orquestador
    "SELECT TOP 1 * FROM dw.fact_pagos",    # no lee el DW directo
    "DELETE FROM audit.etl_log",            # no puede borrar la bitácora
    "UPDATE audit.etl_marca_agua SET fecha_max = '2000-01-01'",
])
def test_etl_solo_ejecuta_el_orquestador(cargado, sentencia):
    with db.conectar_etl(BASE_TEST) as cn:
        with pytest.raises(pyodbc.Error) as exc:
            cn.execute(sentencia)
        cn.rollback()
    assert codigo_error(exc.value) == 229, str(exc.value)
