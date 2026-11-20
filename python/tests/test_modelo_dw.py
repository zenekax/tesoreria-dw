"""Tests del modelo dimensional (Fase 3): estructura, datos estáticos y constraints.

Cada regla de integridad se prueba con CONTROL POSITIVO:
  1) una fila base válida se inserta sin error (prueba que el caso "bueno" pasa);
  2) la misma fila con UN solo campo roto falla con el código de error esperado.
Sin el paso 1, un test de "tiene que fallar" podría pasar por la razón equivocada
(por ejemplo, porque a la fila base le faltaba una columna obligatoria).
Todo se hace dentro de una transacción que se deshace: la base de test queda limpia.

Códigos de SQL Server: 547 = viola CHECK o FOREIGN KEY; 2601 = viola índice único;
2627 = viola PRIMARY KEY / UNIQUE constraint.
"""
from __future__ import annotations

import sys
from datetime import date, timedelta
from pathlib import Path

import pyodbc
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import db  # noqa: E402
from conftest import codigo_error  # noqa: E402

DIMENSIONES = ["dim_banco_cuenta", "dim_contraparte", "dim_fecha", "dim_moneda", "dim_tipo_movimiento"]
HECHOS = ["fact_cobranzas", "fact_conciliacion", "fact_facturas", "fact_movimientos_bancarios",
          "fact_pagos", "fact_saldo_bancario_mensual", "fact_tipo_cambio"]


@pytest.fixture
def cn(base_test):
    """Conexión en una transacción que se deshace al final de cada test."""
    c = db.conectar(database=base_test)
    yield c
    c.rollback()
    c.close()


def insertar(cn, tabla: str, fila: dict):
    cols = ", ".join(fila)
    cn.execute(f"INSERT INTO dw.{tabla} ({cols}) VALUES ({', '.join('?' * len(fila))})", *fila.values())


# --------------------------------------------------------------------------- filas base válidas
# Usan los miembros -1 y fechas reales del calendario: no dependen de datos cargados.
BASE = {
    "fact_facturas": dict(factura_id="T-INV-1", numero_factura="A-00001-00000001", tipo_factura="AP",
                          contraparte_key=-1, moneda_key=1, fecha_emision_key=20260301,
                          fecha_vencimiento_key=20260331, monto=100, tipo_cambio_usd=1, monto_usd=100),
    "fact_pagos": dict(pago_id="T-PAY-1", referencia_pago="OP-1", factura_id="T-INV-1", contraparte_key=-1,
                       banco_cuenta_key=-1, moneda_key=1, fecha_pago_key=20260315, medio_pago="TRANSFERENCIA",
                       monto=100, tipo_cambio_usd=1, monto_usd=100),
    "fact_cobranzas": dict(cobranza_id="T-COL-1", referencia_cobranza="REM1", factura_id="T-INV-2",
                           contraparte_key=-1, banco_cuenta_key=-1, moneda_key=1, fecha_cobranza_key=20260315,
                           medio_cobro="PIX", monto=100, tipo_cambio_usd=1, monto_usd=100),
    "fact_movimientos_bancarios": dict(linea_extracto_id="T-LIN-1", banco_cuenta_key=-1, moneda_key=1,
                                       tipo_movimiento_key=2, fecha_imputacion_key=20260316,
                                       fecha_valor_key=20260316, monto=-100, tipo_cambio_usd=1, monto_usd=-100),
    "fact_saldo_bancario_mensual": dict(banco_cuenta_key=-1, fecha_cierre_key=20260331, moneda_key=1,
                                        saldo_inicial=1000, total_creditos=500, total_debitos=-300,
                                        saldo_final=1200, cantidad_movimientos=10),
    "fact_tipo_cambio": dict(fecha_key=20260316, moneda_key=1, tipo_cambio_por_usd=1500, fuente="TEST"),
    "dim_contraparte": dict(contraparte_id="T-CP-1", tipo_contraparte="PROVEEDOR", razon_social="Prueba S.A.",
                            pais="AR", moneda_default="ARS", segmento="PYME", calificacion_riesgo="BAJO",
                            plazo_pago_dias=30, activa=1, vigente_desde="2025-11-01"),
}
# Tres partidas de conciliación válidas, una por estado típico.
CONC_PENDIENTE = dict(origen="PAGO", pago_id="T-PAY-1", contraparte_key=-1, banco_cuenta_key=-1, moneda_key=1,
                      fecha_libro_key=20260315, monto_libro=-100, estado="PENDIENTE_EN_BANCO")
CONC_OK = dict(CONC_PENDIENTE, pago_id="T-PAY-2", linea_extracto_id="T-LIN-1", fecha_banco_key=20260316,
               fecha_conciliacion_key=20260317, monto_banco=-100, estado="CONCILIADA", metodo_match="REFERENCIA")
CONC_BANCO = dict(origen="BANCO", linea_extracto_id="T-LIN-9", contraparte_key=-1, banco_cuenta_key=-1,
                  moneda_key=1, fecha_banco_key=20260316, monto_banco=3150, estado="PENDIENTE_EN_LIBROS")
CONCILIACIONES_VALIDAS = {"pendiente_en_banco": CONC_PENDIENTE, "conciliada": CONC_OK,
                          "pendiente_en_libros": CONC_BANCO,
                          "con_diferencia": dict(CONC_OK, pago_id="T-PAY-3", linea_extracto_id="T-LIN-2",
                                                 monto_banco=-125, estado="CONCILIADA_CON_DIFERENCIA")}

# (id del caso, tabla, fila base, cambios que la rompen, código esperado)
CASOS = [
    ("factura monto negativo", "fact_facturas", BASE["fact_facturas"], dict(monto=-5), 547),
    ("factura vence antes de emitirse", "fact_facturas", BASE["fact_facturas"], dict(fecha_vencimiento_key=20260201), 547),
    ("factura tipo inválido", "fact_facturas", BASE["fact_facturas"], dict(tipo_factura="XX"), 547),
    ("factura contraparte inexistente", "fact_facturas", BASE["fact_facturas"], dict(contraparte_key=999999), 547),
    ("factura fecha fuera del calendario", "fact_facturas", BASE["fact_facturas"], dict(fecha_emision_key=20300101), 547),
    ("pago monto cero", "fact_pagos", BASE["fact_pagos"], dict(monto=0), 547),
    ("pago tipo de cambio cero", "fact_pagos", BASE["fact_pagos"], dict(tipo_cambio_usd=0), 547),
    ("pago cuenta inexistente", "fact_pagos", BASE["fact_pagos"], dict(banco_cuenta_key=999), 547),
    ("cobranza moneda inexistente", "fact_cobranzas", BASE["fact_cobranzas"], dict(moneda_key=999), 547),
    ("movimiento monto cero", "fact_movimientos_bancarios", BASE["fact_movimientos_bancarios"], dict(monto=0), 547),
    ("movimiento signo USD distinto", "fact_movimientos_bancarios", BASE["fact_movimientos_bancarios"], dict(monto_usd=100), 547),
    ("movimiento tipo inexistente", "fact_movimientos_bancarios", BASE["fact_movimientos_bancarios"], dict(tipo_movimiento_key=99), 547),
    ("saldo que no cuadra", "fact_saldo_bancario_mensual", BASE["fact_saldo_bancario_mensual"], dict(saldo_final=1201), 547),
    ("saldo con créditos negativos", "fact_saldo_bancario_mensual", BASE["fact_saldo_bancario_mensual"],
     dict(total_creditos=-1, saldo_final=699), 547),
    ("tipo de cambio cero", "fact_tipo_cambio", BASE["fact_tipo_cambio"], dict(tipo_cambio_por_usd=0), 547),
    ("contraparte riesgo inválido", "dim_contraparte", BASE["dim_contraparte"], dict(calificacion_riesgo="XYZ"), 547),
    ("contraparte plazo > 365", "dim_contraparte", BASE["dim_contraparte"], dict(plazo_pago_dias=400), 547),
    ("contraparte vigente con fecha de cierre", "dim_contraparte", BASE["dim_contraparte"],
     dict(vigente_hasta="2026-04-30"), 547),
    ("contraparte cerrada antes de abrir", "dim_contraparte", BASE["dim_contraparte"],
     dict(es_vigente=0, vigente_hasta="2025-10-01"), 547),
    ("conciliada sin línea del banco", "fact_conciliacion", CONC_OK, dict(linea_extracto_id=None), 547),
    ("conciliada con diferencia", "fact_conciliacion", CONC_OK, dict(monto_banco=-125), 547),
    ("conciliada sin fecha de conciliación", "fact_conciliacion", CONC_OK, dict(fecha_conciliacion_key=-2), 547),
    ("pago con monto positivo", "fact_conciliacion", CONC_PENDIENTE, dict(monto_libro=100), 547),
    ("pago y cobranza en la misma partida", "fact_conciliacion", CONC_PENDIENTE, dict(cobranza_id="T-COL-1"), 547),
    ("pendiente con método de match", "fact_conciliacion", CONC_PENDIENTE, dict(metodo_match="MANUAL"), 547),
    ("partida del banco con monto de libro", "fact_conciliacion", CONC_BANCO, dict(monto_libro=3150), 547),
    ("estado inválido", "fact_conciliacion", CONC_PENDIENTE, dict(estado="EN_REVISION"), 547),
]


# --------------------------------------------------------------------------- estructura
def test_existen_todas_las_tablas(cn):
    tablas = {r[0] for r in cn.execute("SELECT name FROM sys.tables WHERE schema_id = SCHEMA_ID('dw')")}
    assert tablas == set(DIMENSIONES + HECHOS)


def test_claves_foraneas_habilitadas_y_verificadas(cn):
    """is_not_trusted = 1 significaría que se creó WITH NOCHECK: el optimizador no
    confía en ella y podría haber datos que la violan."""
    malas = cn.execute("SELECT name FROM sys.foreign_keys WHERE schema_id = SCHEMA_ID('dw') "
                       "AND (is_disabled = 1 OR is_not_trusted = 1)").fetchall()
    assert not malas
    assert cn.execute("SELECT COUNT(*) FROM sys.foreign_keys WHERE schema_id = SCHEMA_ID('dw')").fetchone()[0] == 30


def test_toda_columna_key_de_un_hecho_tiene_fk(cn):
    """Ninguna columna *_key de un hecho queda "suelta" sin apuntar a su dimensión
    (salvo su propia clave surrogate)."""
    sueltas = cn.execute("""
        SELECT t.name + '.' + c.name
        FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id
        WHERE t.schema_id = SCHEMA_ID('dw') AND t.name LIKE 'fact[_]%' AND c.name LIKE '%[_]key'
          AND c.is_identity = 0
          AND NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns fkc
                          WHERE fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id)
    """).fetchall()
    assert not sueltas


def test_hashes_scd_persistidos(cn):
    filas = cn.execute("SELECT name, is_persisted FROM sys.computed_columns "
                       "WHERE object_id = OBJECT_ID('dw.dim_contraparte')").fetchall()
    assert {(n, p) for n, p in filas} == {("hash_tipo1", True), ("hash_tipo2", True)}


# --------------------------------------------------------------------------- datos estáticos
def test_miembros_desconocidos(cn):
    for dim, key in [("dim_banco_cuenta", "banco_cuenta_key"), ("dim_contraparte", "contraparte_key"),
                     ("dim_fecha", "fecha_key"), ("dim_moneda", "moneda_key"),
                     ("dim_tipo_movimiento", "tipo_movimiento_key")]:
        assert cn.execute(f"SELECT COUNT(*) FROM dw.{dim} WHERE {key} = -1").fetchone()[0] == 1, dim
    assert cn.execute("SELECT descripcion FROM dw.dim_fecha WHERE fecha_key = -2").fetchone()[0] == "Todavía no ocurrió"


def test_datos_estaticos_no_se_duplican_al_redesplegar(cn):
    """El fixture desplegó dos veces: si los INSERT no fueran idempotentes habría el doble."""
    assert cn.execute("SELECT COUNT(*) FROM dw.dim_moneda").fetchone()[0] == 6
    assert cn.execute("SELECT COUNT(*) FROM dw.dim_tipo_movimiento").fetchone()[0] == 6
    assert [r[0] for r in cn.execute("SELECT codigo_iso FROM dw.dim_moneda WHERE moneda_key > 0 ORDER BY moneda_key")] \
        == ["ARS", "USD", "BRL", "MXN", "COP"]


def test_calendario_completo_y_sin_huecos(cn):
    desde, hasta = date(2019, 1, 1), date(2027, 12, 31)
    fechas = [r[0] for r in cn.execute("SELECT fecha FROM dw.dim_fecha WHERE fecha IS NOT NULL ORDER BY fecha")]
    assert fechas == [desde + timedelta(i) for i in range((hasta - desde).days + 1)]


def test_calendario_atributos(cn):
    def dia(k):
        return cn.execute("SELECT nombre_dia, es_habil, es_ultimo_habil_mes, anio_mes, semana_iso "
                          "FROM dw.dim_fecha WHERE fecha_key = ?", k).fetchone()
    assert tuple(dia(20260319)) == ("jueves", True, False, "2026-03", 12)
    assert tuple(dia(20260321))[:2] == ("sábado", False)
    assert tuple(dia(20261030))[2] is True          # viernes 30/10: último hábil de octubre
    assert tuple(dia(20261031))[2] is False         # sábado 31/10: fin de mes pero no hábil
    # exactamente un último día hábil por mes, y 5 hábiles por semana ISO completa
    assert cn.execute("SELECT COUNT(*) FROM (SELECT anio_mes FROM dw.dim_fecha WHERE fecha IS NOT NULL "
                      "GROUP BY anio_mes HAVING SUM(CAST(es_ultimo_habil_mes AS INT)) <> 1) x").fetchone()[0] == 0
    # el día de la semana no depende de SET DATEFIRST / idioma del servidor
    assert cn.execute("SELECT COUNT(*) FROM dw.dim_fecha WHERE fecha IS NOT NULL "
                      "AND dia_semana <> (DATEPART(WEEKDAY, fecha) + @@DATEFIRST + 5) % 7 + 1").fetchone()[0] == 0


# --------------------------------------------------------------------------- constraints
@pytest.mark.parametrize("tabla", list(BASE))
def test_control_positivo_fila_base_valida(cn, tabla):
    insertar(cn, tabla, BASE[tabla])


@pytest.mark.parametrize("nombre", list(CONCILIACIONES_VALIDAS))
def test_control_positivo_partidas_validas(cn, nombre):
    insertar(cn, "fact_conciliacion", CONCILIACIONES_VALIDAS[nombre])


@pytest.mark.parametrize("caso,tabla,base,cambios,codigo", CASOS, ids=[c[0] for c in CASOS])
def test_constraint_rechaza(cn, caso, tabla, base, cambios, codigo):
    with pytest.raises(pyodbc.Error) as exc:
        insertar(cn, tabla, {**base, **cambios})
    assert codigo_error(exc.value) == codigo, str(exc.value)


@pytest.mark.parametrize("tabla,codigo", [("fact_facturas", 2627), ("fact_pagos", 2627),
                                          ("fact_movimientos_bancarios", 2627), ("fact_tipo_cambio", 2627),
                                          ("fact_saldo_bancario_mensual", 2627), ("dim_contraparte", 2627)])
def test_duplicado_de_clave_de_negocio(cn, tabla, codigo):
    insertar(cn, tabla, BASE[tabla])
    with pytest.raises(pyodbc.Error) as exc:
        insertar(cn, tabla, BASE[tabla])
    assert codigo_error(exc.value) == codigo


def test_scd2_una_sola_version_vigente(cn):
    """Dos versiones de la misma contraparte: la vieja cerrada + la nueva vigente está bien;
    dos vigentes a la vez, no (índice único filtrado)."""
    vieja = {**BASE["dim_contraparte"], "es_vigente": 0, "vigente_hasta": "2026-04-30"}
    nueva = {**BASE["dim_contraparte"], "vigente_desde": "2026-05-01", "calificacion_riesgo": "ALTO"}
    insertar(cn, "dim_contraparte", vieja)
    insertar(cn, "dim_contraparte", nueva)
    hashes = cn.execute("SELECT hash_tipo1, hash_tipo2 FROM dw.dim_contraparte WHERE contraparte_id = 'T-CP-1' "
                        "ORDER BY vigente_desde").fetchall()
    assert hashes[0][0] == hashes[1][0], "solo cambió un atributo tipo 2: el hash tipo 1 es igual"
    assert hashes[0][1] != hashes[1][1], "cambió el riesgo: el hash tipo 2 cambia"
    with pytest.raises(pyodbc.Error) as exc:
        insertar(cn, "dim_contraparte", {**BASE["dim_contraparte"], "vigente_desde": "2026-06-01"})
    assert codigo_error(exc.value) == 2601


def test_una_linea_del_banco_concilia_una_sola_partida(cn):
    insertar(cn, "fact_conciliacion", CONC_OK)
    with pytest.raises(pyodbc.Error) as exc:
        insertar(cn, "fact_conciliacion", dict(CONC_OK, pago_id="T-PAY-99"))
    assert codigo_error(exc.value) == 2601


def test_diferencia_calculada(cn):
    insertar(cn, "fact_conciliacion", CONCILIACIONES_VALIDAS["con_diferencia"])
    assert cn.execute("SELECT diferencia FROM dw.fact_conciliacion WHERE pago_id = 'T-PAY-3'").fetchone()[0] == -25


def test_dim_fecha_clave_coherente_con_la_fecha(cn):
    with pytest.raises(pyodbc.Error) as exc:
        cn.execute("INSERT INTO dw.dim_fecha (fecha_key, fecha, anio, trimestre, mes, nombre_mes, anio_mes, dia, "
                   "dia_semana, nombre_dia, semana_iso, es_habil, es_fin_de_mes, es_ultimo_habil_mes, descripcion) "
                   "VALUES (20280102, '2028-01-01', 2028, 1, 1, 'enero', '2028-01', 1, 6, 'sábado', 52, 0, 0, 0, 'x')")
    assert codigo_error(exc.value) == 547
