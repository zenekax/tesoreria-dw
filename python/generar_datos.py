#!/usr/bin/env python3
"""
generar_datos.py — Datos sintéticos de tesorería de una fintech (ficticia) de pagos
transfronterizos, con errores inyectados de forma controlada.

Qué genera (todo en `data/`, ver docs/datos-sinteticos.md):
    maestros/    banks, bank_accounts, counterparties_<snapshot>.csv (2 snapshots para SCD2)
    AAAA-MM/     invoices, payments, collections, bank_statements, bank_balances, fx_rates
    _verdad/     errores_inyectados.json  -> lista exacta de errores (la "respuesta" de la Fase 5)
                 conciliacion_esperada.csv -> qué línea de extracto corresponde a qué pago/cobranza

Analogía de tesorería: el script hace de ERP + bancos. Los archivos mensuales son los
extractos y listados que te mandan a fin de mes; `_verdad/` es la conciliación "perfecta"
que nadie tiene en la vida real, pero que acá nos sirve para medir si los controles funcionan.

Reproducible: misma seed + misma escala => archivos idénticos byte a byte (lo verifica un test).

Uso:
    python python/generar_datos.py                  # escala 1 (~6.000 facturas)
    python python/generar_datos.py --escala 20      # más volumen para la Fase 7
"""
from __future__ import annotations

import argparse
import bisect
import csv
import hashlib
import json
import math
import random
import re
import shutil
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal
from itertools import accumulate
from pathlib import Path

from faker import Faker

VERSION = "1.0"
SEED = 42
INICIO = date(2025, 11, 1)
FIN = date(2026, 10, 31)                  # fecha de corte de la extracción
SNAPSHOTS = (date(2025, 11, 1), date(2026, 5, 1))
RAIZ = Path(__file__).resolve().parent.parent

MONEDAS = ["ARS", "USD", "BRL", "MXN", "COP"]
PAISES = {  # país -> (moneda local, locale de Faker, sufijo societario)
    "AR": ("ARS", "es_AR", "S.A."),
    "US": ("USD", "en_US", "Inc."),
    "BR": ("BRL", "pt_BR", "Ltda."),
    "MX": ("MXN", "es_MX", "S.A. de C.V."),
    "CO": ("COP", "es_CO", "S.A.S."),
}
# Unidades de moneda local por 1 USD al inicio. ARS con deriva (devaluación diaria).
FX_BASE = {"ARS": 1450.0, "BRL": 5.35, "MXN": 18.40, "COP": 3900.0}
FX_DERIVA = {"ARS": 0.0008, "BRL": 0.0, "MXN": 0.0, "COP": 0.0}
FX_VOL = {"ARS": 0.005, "BRL": 0.007, "MXN": 0.006, "COP": 0.006}

# Bancos y cuentas FICTICIOS. Los BIC terminan en "ZZ" para no coincidir con BIC reales.
BANCOS = [
    ("B01", "Banco del Plata (ficticio)", "AR", "XPLAARZZ", "991"),
    ("B02", "Banco Austral (ficticio)", "AR", "XAUSARZZ", "992"),
    ("B03", "First Demo Bank (fictitious)", "US", "XFDBUSZZ", "999"),
    ("B04", "Banco Paulista (fictício)", "BR", "XPAUBRZZ", "999"),
    ("B05", "Banco Meseta (ficticio)", "MX", "XMESMXZZ", "999"),
    ("B06", "Banco Andino (ficticio)", "CO", "XANDCOZZ", "999"),
]
CUENTAS = [  # id, banco, moneda, tipo, alias
    ("ACC01", "B01", "ARS", "CC", "Operativa ARS"),
    ("ACC02", "B02", "ARS", "CC", "Payouts ARS"),
    ("ACC03", "B01", "USD", "CA", "USD Argentina"),
    ("ACC04", "B03", "USD", "CHK", "Operating USD"),
    ("ACC05", "B03", "USD", "CHK", "Payouts USD"),
    ("ACC06", "B04", "BRL", "CC", "Operacional BRL"),
    ("ACC07", "B04", "BRL", "CC", "Payouts BRL"),
    ("ACC08", "B05", "MXN", "CC", "Operativa MXN"),
    ("ACC09", "B06", "COP", "CC", "Operativa COP"),
]

COLUMNAS = {
    "banks": ["bank_id", "bank_name", "country", "swift_bic"],
    "bank_accounts": ["account_id", "bank_id", "account_number", "currency", "account_type",
                      "account_alias", "opened_date"],
    "counterparties": ["counterparty_id", "counterparty_type", "legal_name", "tax_id", "country",
                       "default_currency", "email", "segment", "risk_rating", "payment_terms_days",
                       "is_active", "created_at", "snapshot_date"],
    "fx_rates": ["rate_date", "currency", "rate_per_usd", "source"],
    "invoices": ["invoice_id", "invoice_number", "counterparty_id", "invoice_type", "issue_date",
                 "due_date", "currency", "amount", "description"],
    "payments": ["payment_id", "payment_reference", "invoice_id", "counterparty_id", "account_id",
                 "payment_date", "currency", "amount", "payment_method"],
    "collections": ["collection_id", "collection_reference", "invoice_id", "counterparty_id",
                    "account_id", "collection_date", "currency", "amount", "collection_method"],
    "bank_statements": ["statement_line_id", "account_number", "booking_date", "value_date",
                        "currency", "amount", "bank_tx_code", "description", "bank_reference"],
    "bank_balances": ["account_number", "period", "currency", "opening_balance", "total_credits",
                      "total_debits", "closing_balance", "line_count"],
}
PK = {"invoices": "invoice_id", "payments": "payment_id", "collections": "collection_id",
      "bank_statements": "statement_line_id", "counterparties": "counterparty_id"}

# --------------------------------------------------------------------------- utilidades
HABILES = [INICIO + timedelta(i) for i in range((FIN - INICIO).days + 1)
           if (INICIO + timedelta(i)).weekday() < 5]


def d2(x) -> Decimal:
    return Decimal(str(x)).quantize(Decimal("0.01"), ROUND_HALF_UP)


def habil_siguiente(d: date) -> date:
    while d.weekday() >= 5:
        d += timedelta(days=1)
    return d


def sumar_habiles(d: date, n: int) -> date:
    d = habil_siguiente(d)
    for _ in range(n):
        d = habil_siguiente(d + timedelta(days=1))
    return d


def mes(d: date) -> str:
    return f"{d:%Y-%m}"


def ascii_mayus(s: str) -> str:
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().upper()


def formato_ar(m: Decimal) -> str:
    """1234567.89 -> '1.234.567,89' (como lo exporta un Excel en castellano)."""
    return f"{m:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


@dataclass
class Contraparte:
    id: str
    tipo: str
    nombre: str
    pais: str
    moneda: str
    tax_id: str
    email: str
    segmento: str
    riesgo: str
    plazo: int
    alta: date
    peso: float
    base_usd: float
    perfil_cobro: str = "PUNTUAL"
    desde: date = INICIO          # primera fecha en que puede operar
    hasta: date = FIN             # última fecha en que puede operar
    nueva: bool = False           # aparece recién en el 2do snapshot
    v2: dict = field(default_factory=dict)       # atributos que cambian en el 2do snapshot
    errores: list = field(default_factory=list)  # errores inyectados en el maestro

    def plazo_en(self, d: date) -> int:
        return self.v2.get("plazo", self.plazo) if d >= SNAPSHOTS[1] else self.plazo


# --------------------------------------------------------------------------- inyector de errores
class Inyector:
    """Registra cada error inyectado. Regla: un solo error por fila, así cada control de
    calidad de la Fase 5 se puede verificar contra una fila puntual."""

    def __init__(self, rng: random.Random):
        self.rng = rng
        self.errores: list[dict] = []
        self._usadas: set[int] = set()

    def elegir(self, filas: list, n: int, filtro=lambda f: True) -> list:
        candidatas = [f for f in filas if id(f) not in self._usadas
                      and not f.get("_anomalia") and filtro(f)]
        elegidas = self.rng.sample(candidatas, n)
        self._usadas.update(id(f) for f in elegidas)
        return elegidas

    def registrar(self, fila: dict | None, tabla: str, tipo: str, categoria: str, campo,
                  original, inyectado, descripcion: str, clave: dict | None = None) -> dict:
        err = {"id": f"E{len(self.errores) + 1:04d}", "categoria": categoria, "tipo": tipo,
               "tabla": tabla, "clave": clave, "campo": campo, "valor_original": original,
               "valor_inyectado": inyectado, "descripcion": descripcion, "ubicaciones": []}
        if fila is not None:
            err["_fila"] = fila
            fila.setdefault("_errores", []).append(err)
        self.errores.append(err)
        return err


# --------------------------------------------------------------------------- generador
class Generador:
    def __init__(self, escala: float, seed: int):
        self.escala, self.seed = escala, seed
        self.rng = random.Random(seed)
        self.fakers = {}
        for i, pais in enumerate(PAISES):
            f = Faker(PAISES[pais][1])
            f.seed_instance(seed + i)
            self.fakers[pais] = f
        self.iny = Inyector(self.rng)
        self.ruido: dict[str, list] = defaultdict(list)
        self.anomalias: list[dict] = []
        self.cambios_scd2: list[dict] = []

    # ------------------------------------------------------------------ tipos de cambio
    def generar_fx(self):
        """Random walk diario (log-normal) sobre días hábiles. ARS con deriva devaluatoria."""
        self.tasas: dict[date, dict[str, Decimal]] = {}
        nivel = dict(FX_BASE)
        self.fx_filas = []
        for d in HABILES:
            fila = {"USD": Decimal("1")}
            for c in FX_BASE:
                nivel[c] *= math.exp(FX_DERIVA[c] + self.rng.gauss(0, FX_VOL[c]))
                fila[c] = Decimal(f"{nivel[c]:.6f}")
            self.tasas[d] = fila
            for c in MONEDAS:
                self.fx_filas.append({"rate_date": d.isoformat(), "currency": c,
                                      "rate_per_usd": f"{fila[c]:.6f}", "source": "REF_MERCADO",
                                      "_mes": mes(d), "_orden": (d.isoformat(), c, 0)})

    def tasa(self, d: date, moneda: str) -> Decimal:
        """Último tipo de cambio hábil disponible a la fecha d (fines de semana usan el viernes)."""
        i = max(bisect.bisect_right(HABILES, d) - 1, 0)
        return self.tasas[HABILES[i]][moneda]

    def de_usd(self, usd: float, moneda: str, d: date) -> Decimal:
        return d2(Decimal(str(usd)) * self.tasa(d, moneda))

    # ------------------------------------------------------------------ bancos y cuentas
    def generar_bancos_y_cuentas(self):
        r = self.rng
        self.bancos = {b[0]: {"bank_id": b[0], "bank_name": b[1], "country": b[2],
                              "swift_bic": b[3], "_codigo": b[4]} for b in BANCOS}
        self.cuentas = {}
        for acc_id, banco, moneda, tipo, alias in CUENTAS:
            pais = self.bancos[banco]["country"]
            self.cuentas[acc_id] = {
                "account_id": acc_id, "bank_id": banco,
                "account_number": self._numero_cuenta(pais, self.bancos[banco]["_codigo"]),
                "currency": moneda, "account_type": tipo, "account_alias": alias,
                "opened_date": date(r.randint(2019, 2024), r.randint(1, 12), r.randint(1, 28)).isoformat(),
                "_pais": pais,
            }
        self.cuentas_por_moneda = defaultdict(list)
        for c in self.cuentas.values():
            self.cuentas_por_moneda[c["currency"]].append(c)

    def _numero_cuenta(self, pais: str, codigo: str) -> str:
        r = self.rng
        if pais == "AR":  # CBU de 22 dígitos con dígitos verificadores reales (validable en Fase 5)
            b1 = codigo + f"{r.randint(0, 9999):04d}"
            dv1 = (10 - sum(int(a) * p for a, p in zip(b1, [7, 1, 3, 9, 7, 1, 3])) % 10) % 10
            cta = f"{r.randint(0, 10**13 - 1):013d}"
            dv2 = (10 - sum(int(a) * p for a, p in zip(cta, [3, 9, 7, 1] * 3 + [3])) % 10) % 10
            return f"{b1}{dv1}{cta}{dv2}"
        if pais == "MX":  # CLABE de 18 dígitos con dígito verificador
            base = codigo + f"{r.randint(0, 999):03d}" + f"{r.randint(0, 10**11 - 1):011d}"
            s = sum((int(a) * p) % 10 for a, p in zip(base, [3, 7, 1] * 6))
            return base + str((10 - s % 10) % 10)
        if pais == "BR":
            return f"{r.randint(1, 9999):04d}-{r.randint(0, 10**8 - 1):08d}-{r.randint(0, 9)}"
        if pais == "CO":
            return f"{r.randint(0, 10**11 - 1):011d}"
        return f"{r.randint(10**9, 10**10 - 1)}"  # US

    def cuenta_para(self, moneda: str, cp: Contraparte) -> dict:
        if moneda == "USD":  # USD de contrapartes argentinas sale/entra por la cuenta USD local
            return self.cuentas["ACC03"] if cp.pais == "AR" else self.rng.choice(
                [self.cuentas["ACC04"], self.cuentas["ACC05"]])
        return self.rng.choice(self.cuentas_por_moneda[moneda])

    def metodo(self, cuenta: dict, cp: Contraparte) -> str:
        if cuenta["currency"] == "USD":
            if cuenta["_pais"] != cp.pais:
                return "SWIFT"
            return "WIRE" if cuenta["_pais"] == "US" else "TRANSFERENCIA"
        return {"ARS": "TRANSFERENCIA", "MXN": "SPEI", "COP": "ACH"}.get(
            cuenta["currency"]) or ("PIX" if self.rng.random() < 0.7 else "TED")

    # ------------------------------------------------------------------ contrapartes
    def generar_contrapartes(self):
        r = self.rng
        k = math.sqrt(self.escala)
        cantidades = {"SUPPLIER": 40, "CORRESPONDENT": 20, "CUSTOMER": 60}
        dist_pais = {
            "SUPPLIER": ([0.5, 0.25, 0.1, 0.08, 0.07]),
            "CORRESPONDENT": ([0.2, 0.1, 0.25, 0.25, 0.2]),
            "CUSTOMER": ([0.25, 0.35, 0.15, 0.15, 0.10]),
        }
        base_usd = {"SUPPLIER": 2500, "CORRESPONDENT": 12000, "CUSTOMER": 6000}
        plazos = {"SUPPLIER": [30, 45, 60], "CORRESPONDENT": [15, 30], "CUSTOMER": [15, 30, 45]}
        pct_usd = {"SUPPLIER": 0.15, "CORRESPONDENT": 0.4, "CUSTOMER": 0.3}
        self.cps: list[Contraparte] = []
        nombres_usados: set[str] = set()

        def nueva_cp(tipo: str, alta: date) -> Contraparte:
            pais = r.choices(list(PAISES), weights=dist_pais[tipo])[0]
            moneda_local, _, sufijo = PAISES[pais]
            moneda = moneda_local if pais == "US" or r.random() > pct_usd[tipo] else "USD"
            nombre = self._nombre_empresa(pais, sufijo, nombres_usados)
            perfil = "PUNTUAL"
            if tipo == "CUSTOMER":
                perfil = r.choices(["PUNTUAL", "DEMORADO", "MOROSO"], [0.6, 0.3, 0.1])[0]
            riesgo = r.choices(["LOW", "MEDIUM", "HIGH"], [0.6, 0.3, 0.1])[0]
            if perfil == "MOROSO":
                riesgo = r.choice(["MEDIUM", "HIGH"])
            cp = Contraparte(
                id=f"CP{len(self.cps) + 1:04d}", tipo=tipo, nombre=nombre, pais=pais, moneda=moneda,
                tax_id=self._tax_id(pais), email=self._email(nombre), alta=alta,
                segmento=r.choices(["STRATEGIC", "ENTERPRISE", "SME"], [0.15, 0.35, 0.5])[0],
                riesgo=riesgo, plazo=r.choice(plazos[tipo]),
                peso=min(r.paretovariate(1.16), 25.0),  # Pareto: pocas contrapartes concentran volumen
                base_usd=r.lognormvariate(math.log(base_usd[tipo]), 0.8), perfil_cobro=perfil)
            self.cps.append(cp)
            return cp

        for tipo, n in cantidades.items():
            for _ in range(max(5, round(n * k))):
                nueva_cp(tipo, date(2019, 1, 1) + timedelta(days=r.randint(0, 2477)))

        iniciales = list(self.cps)
        # Altas del semestre: aparecen recién en el snapshot de mayo y operan desde ahí.
        for tipo in ["SUPPLIER", "CUSTOMER", "CUSTOMER", "CORRESPONDENT", "SUPPLIER"]:
            cp = nueva_cp(tipo, date(2026, 4, r.randint(1, 30)))
            cp.nueva, cp.desde = True, SNAPSHOTS[1]
        # Bajas: dejan de operar antes del 2do snapshot.
        for cp in r.sample([c for c in iniciales if c.segmento != "STRATEGIC"], 3):
            cp.hasta = SNAPSHOTS[1] - timedelta(days=1)
            cp.v2["activo"] = "N"
            self.cambios_scd2.append({"counterparty_id": cp.id, "campo": "is_active", "antes": "Y",
                                      "despues": "N", "tipo_scd": 2, "vigente_desde": SNAPSHOTS[1].isoformat()})
        # Cambios de atributos (SCD2: riesgo, plazo, segmento; SCD1: email).
        sin_baja = [c for c in iniciales if "activo" not in c.v2]
        for cp in r.sample(sin_baja, max(6, round(0.12 * len(iniciales)))):
            campo = r.choice(["riesgo", "plazo", "segmento"])
            if campo == "riesgo":
                antes, despues = cp.riesgo, r.choice([x for x in ["LOW", "MEDIUM", "HIGH"] if x != cp.riesgo])
            elif campo == "plazo":
                antes, despues = cp.plazo, r.choice([x for x in [15, 30, 45, 60, 90] if x != cp.plazo])
            else:
                antes, despues = cp.segmento, r.choice([x for x in ["STRATEGIC", "ENTERPRISE", "SME"] if x != cp.segmento])
            cp.v2[campo] = despues
            col = {"riesgo": "risk_rating", "plazo": "payment_terms_days", "segmento": "segment"}[campo]
            self.cambios_scd2.append({"counterparty_id": cp.id, "campo": col, "antes": str(antes),
                                      "despues": str(despues), "tipo_scd": 2,
                                      "vigente_desde": SNAPSHOTS[1].isoformat()})
        for cp in r.sample([c for c in sin_baja if not c.v2], 3):
            nuevo = cp.email.replace("@", ".finanzas@", 1)
            cp.v2["email"] = nuevo
            self.cambios_scd2.append({"counterparty_id": cp.id, "campo": "email", "antes": cp.email,
                                      "despues": nuevo, "tipo_scd": 1,
                                      "vigente_desde": SNAPSHOTS[1].isoformat()})

    def _nombre_empresa(self, pais: str, sufijo: str, usados: set) -> str:
        while True:
            # Se sacan TODOS los sufijos societarios que trae Faker (a veces vienen dos, como
            # "A.C. S.A. de C.V."), para poner después el del país una sola vez.
            base = self.fakers[pais].company()
            while True:
                limpio = re.sub(r"[\s,]+(Inc|LLC|Ltd|S/A|S\.A\.( de C\.V\.)?|Ltda|A\.C\.|S\.C\.|S\.A\.S\.|ME|EIRELI|PLC|Group)\.?$",
                                "", base).strip(" ,-")
                if limpio == base:
                    break
                base = limpio
            # Algunos locales de Faker mezclan inglés ("Gomez, Ruiz and Diaz"): se castellaniza.
            base = base.replace(" and ", {"BR": " e ", "US": " and "}.get(pais, " y "))
            nombre = f"{base} {sufijo}"
            if nombre not in usados:
                usados.add(nombre)
                return nombre

    def _tax_id(self, pais: str) -> str:
        r = self.rng
        if pais == "AR":
            return f"{r.choice(['30', '33', '30'])}-{r.randint(10**7, 10**8 - 1)}-{r.randint(0, 9)}"
        if pais == "BR":
            return f"{r.randint(10, 99)}.{r.randint(100, 999)}.{r.randint(100, 999)}/0001-{r.randint(10, 99)}"
        if pais == "MX":
            letras = "".join(r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(3))
            return f"{letras}{r.randint(0, 99):02d}{r.randint(1, 12):02d}{r.randint(1, 28):02d}{r.choice('ABCDEFGH')}{r.randint(10, 99)}"
        if pais == "CO":
            return f"{r.randint(800_000_000, 999_999_999)}-{r.randint(0, 9)}"
        return f"{r.randint(10, 99)}-{r.randint(10**6, 10**7 - 1)}"

    def _email(self, nombre: str) -> str:
        # Dominio .example: reservado por RFC 2606, nunca va a existir un email real así.
        slug = re.sub(r"[^a-z0-9]", "", ascii_mayus(nombre).lower())[:20] or "empresa"
        return f"{self.rng.choice(['tesoreria', 'pagos', 'finanzas', 'cobranzas', 'ap'])}@{slug}.example"

    def _habil_al_azar(self, desde: date, hasta: date) -> date:
        lo = bisect.bisect_left(HABILES, desde)
        hi = bisect.bisect_right(HABILES, hasta) - 1
        return HABILES[self.rng.randint(lo, hi)]

    # ------------------------------------------------------------------ facturas
    def generar_facturas(self):
        r = self.rng
        n = max(300, round(6000 * self.escala))
        cum = list(accumulate(cp.peso for cp in self.cps))
        tmp = []
        for _ in range(n):
            cp = r.choices(self.cps, cum_weights=cum)[0]
            tmp.append((self._habil_al_azar(cp.desde, cp.hasta), cp.id,
                        max(50.0, cp.base_usd * r.lognormvariate(0, 0.45)), cp))
        tmp.sort(key=lambda t: (t[0], t[1], t[2]))

        numeradores: dict[str, list] = {}
        nro_propio = r.randint(1000, 5000)
        conceptos = {
            "SUPPLIER": ["Servicios de hosting cloud", "Licencias de software", "Honorarios legales",
                         "Campaña de marketing digital", "Servicio de verificación KYC/AML",
                         "Consultoría contable", "Alquiler de oficinas", "Soporte de infraestructura"],
            "CORRESPONDENT": ["Comisiones de payout", "Fee por dispersión de remesas",
                              "Servicio de corresponsalía"],
            "CUSTOMER": ["Fee por procesamiento de pagos", "Servicio de pagos transfronterizos",
                         "Comisión por remesas enviadas"],
        }
        self.facturas = []
        for i, (d, _, usd, cp) in enumerate(tmp, start=1):
            tipo = "AR" if cp.tipo == "CUSTOMER" else "AP"
            if tipo == "AR":  # facturas propias: punto de venta 00003, numeración correlativa
                nro_propio += 1
                numero = f"A-00003-{nro_propio:08d}"
            else:
                st = numeradores.setdefault(cp.id, [r.randint(1, 20), r.randint(1, 5000)])
                st[1] += 1
                numero = {"AR": f"A-{st[0]:05d}-{st[1]:08d}", "BR": f"NFE-{st[1]:09d}",
                          "MX": f"F{st[0]:02d}-{st[1]:06d}", "CO": f"FE{st[1]:07d}",
                          "US": f"INV-{st[1]:06d}"}[cp.pais]
            monto = self.de_usd(usd, cp.moneda, d)
            vto = d + timedelta(days=cp.plazo_en(d))
            self.facturas.append({
                "invoice_id": f"INV-{i:07d}", "invoice_number": numero, "counterparty_id": cp.id,
                "invoice_type": tipo, "issue_date": d.isoformat(), "due_date": vto.isoformat(),
                "currency": cp.moneda, "amount": f"{monto:.2f}",
                "description": f"{r.choice(conceptos[cp.tipo])} {d:%m/%Y}",
                "_cp": cp, "_fecha": d, "_vto": vto, "_monto": monto,
                "_mes": mes(d), "_orden": (d.isoformat(), f"INV-{i:07d}", 0)})

    def anomalia_montos_atipicos(self):
        """Facturas válidas pero 8-12x más grandes que lo habitual del proveedor (Fase 6)."""
        r = self.rng
        conteo = defaultdict(int)
        for f in self.facturas:
            conteo[f["counterparty_id"]] += 1
        candidatas = [f for f in self.facturas if f["_cp"].tipo == "SUPPLIER"
                      and conteo[f["counterparty_id"]] >= 10 and f["_vto"] <= FIN - timedelta(days=20)]
        for f in r.sample(candidatas, 5):
            factor = round(r.uniform(8, 12), 2)
            f["_monto"] = d2(f["_monto"] * Decimal(str(factor)))
            f["amount"] = f"{f['_monto']:.2f}"
            f["_anomalia"] = "PAGO_ATIPICO"
            self.anomalias.append({"tipo": "PAGO_ATIPICO", "invoice_id": f["invoice_id"],
                                   "counterparty_id": f["counterparty_id"], "factor": factor,
                                   "_factura": f})

    # ------------------------------------------------------------------ pagos y cobranzas
    def generar_liquidaciones(self):
        """Cada factura se paga/cobra completa, en 2 parciales, o queda abierta al cierre."""
        r = self.rng
        self.pagos, self.cobranzas = [], []
        nunca = {"PUNTUAL": 0.01, "DEMORADO": 0.04, "MOROSO": 0.25}
        for f in self.facturas:
            cp = f["_cp"]
            x = r.random()
            if f["invoice_type"] == "AP":
                if f.get("_anomalia"):
                    modo = "TOTAL"
                elif x < 0.04:
                    continue  # factura en disputa: no se paga
                else:
                    modo = "PARCIAL" if x < 0.09 else "TOTAL"
                desvio = r.randint(-5, 3) if r.random() < 0.9 else r.randint(4, 20)
            else:
                if x < nunca[cp.perfil_cobro]:
                    continue  # incobrable
                modo = "PARCIAL" if r.random() < 0.08 else "TOTAL"
                desvio = {"PUNTUAL": r.randint(-3, 5), "DEMORADO": r.randint(5, 45),
                          "MOROSO": r.randint(30, 120)}[cp.perfil_cobro]
            f1 = max(habil_siguiente(f["_vto"] + timedelta(days=desvio)), sumar_habiles(f["_fecha"], 1))
            if f1 > FIN:
                continue  # abierta al corte: alimenta el aging
            cuenta = self.cuenta_para(f["currency"], cp)
            if modo == "PARCIAL":
                p1 = d2(f["_monto"] * Decimal(str(round(r.uniform(0.4, 0.6), 2))))
                partes = [(f1, p1, 1)]
                f2 = sumar_habiles(f1, r.randint(10, 20))
                if f2 <= FIN:
                    partes.append((f2, f["_monto"] - p1, 2))
            else:
                partes = [(f1, f["_monto"], 1)]
            destino = self.pagos if f["invoice_type"] == "AP" else self.cobranzas
            for fecha, monto, parte in partes:
                destino.append({"_fecha": fecha, "_monto": monto, "_cuenta": cuenta, "_cp": cp,
                                "_inv": f, "_parte": parte, "_modo": modo,
                                "_metodo": self.metodo(cuenta, cp),
                                "_anomalia": f.get("_anomalia")})

    def anomalia_doble_pago(self):
        """Mismo proveedor, misma factura, mismo monto, 1-2 días hábiles después (Fase 6)."""
        r = self.rng
        candidatos = [p for p in self.pagos if p["_modo"] == "TOTAL" and not p["_anomalia"]
                      and sumar_habiles(p["_fecha"], 5) <= FIN]
        for p in r.sample(candidatos, 3):
            dup = dict(p)
            dup["_fecha"] = sumar_habiles(p["_fecha"], r.randint(1, 2))
            dup["_parte"] = 9
            p["_anomalia"] = dup["_anomalia"] = "POSIBLE_DOBLE_PAGO"
            self.pagos.append(dup)
            self.anomalias.append({"tipo": "POSIBLE_DOBLE_PAGO", "invoice_id": p["_inv"]["invoice_id"],
                                   "counterparty_id": p["_cp"].id, "_pagos": [p, dup]})

    def numerar(self):
        r = self.rng
        self.pagos.sort(key=lambda p: (p["_fecha"], p["_inv"]["invoice_id"], p["_parte"]))
        por_mes = defaultdict(int)
        for i, p in enumerate(self.pagos, start=1):
            por_mes[mes(p["_fecha"])] += 1
            p.update({"payment_id": f"PAY-{i:07d}",
                      "payment_reference": f"OP-{p['_fecha']:%Y%m}-{por_mes[mes(p['_fecha'])]:05d}",
                      "invoice_id": p["_inv"]["invoice_id"], "counterparty_id": p["_cp"].id,
                      "account_id": p["_cuenta"]["account_id"], "payment_date": p["_fecha"].isoformat(),
                      "currency": p["_inv"]["currency"], "amount": f"{p['_monto']:.2f}",
                      "payment_method": p["_metodo"], "_mes": mes(p["_fecha"]),
                      "_orden": (p["_fecha"].isoformat(), f"PAY-{i:07d}", 0)})
        self.cobranzas.sort(key=lambda c: (c["_fecha"], c["_inv"]["invoice_id"], c["_parte"]))
        for i, c in enumerate(self.cobranzas, start=1):
            ref = c["_inv"]["invoice_number"] if r.random() < 0.6 else f"REM{r.randint(10**8, 10**9 - 1)}"
            c.update({"collection_id": f"COL-{i:07d}", "collection_reference": ref,
                      "invoice_id": c["_inv"]["invoice_id"], "counterparty_id": c["_cp"].id,
                      "account_id": c["_cuenta"]["account_id"], "collection_date": c["_fecha"].isoformat(),
                      "currency": c["_inv"]["currency"], "amount": f"{c['_monto']:.2f}",
                      "collection_method": c["_metodo"], "_mes": mes(c["_fecha"]),
                      "_orden": (c["_fecha"].isoformat(), f"COL-{i:07d}", 0)})
        for a in self.anomalias:  # completar ids de pagos en el registro de anomalías
            if a["tipo"] == "PAGO_ATIPICO":
                a["payment_ids"] = [p["payment_id"] for p in self.pagos if p["_inv"] is a["_factura"]]
            else:
                a["payment_ids"] = [p["payment_id"] for p in a["_pagos"]]

    # ------------------------------------------------------------------ extracto bancario
    def _linea(self, cuenta, fecha, monto, codigo, desc, erp=None, **extra) -> dict:
        l = {"_cuenta": cuenta, "_fecha": fecha, "_monto": d2(monto), "_codigo": codigo,
             "_desc": " ".join(desc.split())[:80].rstrip(), "_erp": erp, "_valor": fecha}
        l.update(extra)
        self.lineas.append(l)
        return l

    def generar_lineas_banco(self):
        """Lo que el banco registra: transferencias (con desfase y referencias imperfectas),
        comisiones SWIFT (a veces descontadas del monto) y, más adelante, FX e impuestos."""
        r = self.rng
        self.lineas: list[dict] = []
        pref_out = {"SWIFT": "TRF SWIFT ENVIADA", "TRANSFERENCIA": "TRANSFERENCIA ENVIADA",
                    "WIRE": "OUTGOING WIRE", "PIX": "PIX ENVIADO", "TED": "TED ENVIADA",
                    "SPEI": "SPEI ENVIADO", "ACH": "ACH ENVIADO"}
        pref_in = {"SWIFT": "TRF SWIFT RECIBIDA", "TRANSFERENCIA": "TRANSFERENCIA RECIBIDA",
                   "WIRE": "INCOMING WIRE", "PIX": "PIX RECEBIDO", "TED": "TED RECEBIDA",
                   "SPEI": "SPEI RECIBIDO", "ACH": "ACH RECIBIDO"}
        for tipo, registros in (("PAYMENT", self.pagos), ("COLLECTION", self.cobranzas)):
            for x in registros:
                desfase = r.choices([0, 1, 2, 3], [60, 30, 8, 2])[0]
                booking = sumar_habiles(x["_fecha"], desfase)
                pk = x["payment_id"] if tipo == "PAYMENT" else x["collection_id"]
                if booking > FIN:
                    self.ruido[f"{tipo.lower()}s_en_transito"].append(pk)
                    continue
                nombre = ascii_mayus(x["_cp"].nombre)[:22]
                ref = x["payment_reference"] if tipo == "PAYMENT" else x["collection_reference"]
                modo_ref = r.choices(["COMPLETA", "PARCIAL", "SIN_REF"], [70, 20, 10])[0]
                pref = (pref_out if tipo == "PAYMENT" else pref_in)[x["_metodo"]]
                desc = {"COMPLETA": f"{pref} {ref} {nombre}", "PARCIAL": f"{pref} {ref[-5:]} {nombre[:12]}",
                        "SIN_REF": f"{pref} {nombre}"}[modo_ref]
                monto = -x["_monto"] if tipo == "PAYMENT" else x["_monto"]
                comision_desc = None
                if x["_metodo"] == "SWIFT":
                    if tipo == "PAYMENT" and r.random() < 0.3:
                        comision_desc = d2(r.uniform(15, 45))
                        monto -= comision_desc
                    elif tipo == "COLLECTION" and r.random() < 0.25:
                        comision_desc = d2(r.uniform(10, 40))
                        monto -= comision_desc
                linea = self._linea(x["_cuenta"], booking, monto, "TRF_OUT" if tipo == "PAYMENT" else "TRF_IN",
                                    desc, erp=(tipo, x), _desfase=desfase, _modo_ref=modo_ref)
                if tipo == "COLLECTION" and r.random() < 0.1:
                    linea["_valor"] = sumar_habiles(booking, 1)
                x["_linea"] = linea
                if comision_desc is not None:
                    self.ruido["comision_descontada_del_monto"].append(pk)
                elif x["_metodo"] == "SWIFT" and tipo == "PAYMENT":
                    linea["_fee"] = self._linea(x["_cuenta"], booking, -d2(r.uniform(20, 35)), "FEE",
                                                f"COMISION SWIFT {ref}")

    def error_pagos_sin_extracto(self):
        """El ERP dice que se pagó, pero el banco nunca lo debitó (ej.: rechazado)."""
        quitar = set()
        for p in self.iny.elegir(self.pagos, 8, lambda p: p.get("_linea") is not None):
            quitar.add(id(p["_linea"]))
            if p["_linea"].get("_fee"):
                quitar.add(id(p["_linea"]["_fee"]))
            p["_linea"] = None
            self.iny.registrar(p, "payments", "PAGO_SIN_EXTRACTO", "pagos_sin_extracto", None, None, None,
                               "Pago registrado en el ERP sin débito en el extracto bancario")
        self.lineas = [l for l in self.lineas if id(l) not in quitar]

    def error_extractos_sin_match(self):
        """Movimientos reales del banco que nadie cargó en el ERP."""
        r = self.rng
        for i in range(15):
            cuenta = r.choice(list(self.cuentas.values()))
            fecha = r.choice(HABILES)
            nombre = ascii_mayus(self.fakers[cuenta["_pais"]].company())[:22]
            entrada = i < 9
            monto = self.de_usd(r.lognormvariate(math.log(3000), 0.6), cuenta["currency"], fecha)
            l = self._linea(cuenta, fecha, monto if entrada else -monto, "TRF_IN" if entrada else "TRF_OUT",
                            f"{'TRANSFERENCIA RECIBIDA' if entrada else 'DEBITO TRANSFERENCIA'} {nombre}")
            self.iny._usadas.add(id(l))
            self.iny.registrar(l, "bank_statements", "EXTRACTO_SIN_MATCH", "extractos_sin_match", None, None,
                               None, "Movimiento bancario sin pago ni cobranza en el ERP")

    def generar_conversiones_fx(self):
        """Compra/venta de USD para fondear (o vaciar) las cuentas en moneda local cada mes."""
        neto = defaultdict(Decimal)
        for l in self.lineas:
            if l["_cuenta"]["currency"] != "USD":
                neto[(l["_cuenta"]["currency"], mes(l["_fecha"]))] += l["_monto"]
        meses = sorted({mes(d) for d in HABILES})
        for moneda in ["ARS", "BRL", "MXN", "COP"]:
            local = self.cuentas_por_moneda[moneda][0]
            usd_cta = self.cuentas["ACC03"] if moneda == "ARS" else self.cuentas["ACC04"]
            for m in meses:
                n = neto[(moneda, m)]
                dias = [d for d in HABILES if mes(d) == m]
                if n < 0:
                    fecha, monto_local, spread = dias[0], d2(-n * Decimal("1.1")), Decimal("1.003")
                elif n > 0:
                    fecha, monto_local, spread = dias[-1], -d2(n * Decimal("0.9")), Decimal("0.997")
                else:
                    continue
                tc = (self.tasa(fecha, moneda) * spread).quantize(Decimal("0.0001"))
                usd = d2(abs(monto_local) / tc)
                ref = f"FX{fecha:%Y%m%d}{moneda}"
                op = "COMPRA" if monto_local > 0 else "VENTA"
                self._linea(local, fecha, monto_local, "FX", f"{op} {moneda} C/USD TC {tc} {ref}")
                self._linea(usd_cta, fecha, -usd if monto_local > 0 else usd, "FX",
                            f"{'VENTA' if op == 'COMPRA' else 'COMPRA'} USD P/{moneda} TC {tc} {ref}")

    def generar_comisiones_e_impuestos(self):
        # Impuesto a los débitos y créditos (Ley 25.413): 0,6% sobre cada movimiento en ARS.
        dia = defaultdict(lambda: [Decimal(0), Decimal(0)])
        for l in self.lineas:
            if l["_cuenta"]["currency"] == "ARS" and l["_codigo"] in ("TRF_IN", "TRF_OUT", "FX"):
                k = (l["_cuenta"]["account_id"], l["_fecha"])
                dia[k][0 if l["_monto"] > 0 else 1] += abs(l["_monto"])
        for (acc, fecha), (creditos, debitos) in sorted(dia.items()):
            if creditos:
                self._linea(self.cuentas[acc], fecha, -d2(creditos * Decimal("0.006")), "TAX",
                            "IMP LEY 25413 S/CREDITOS")
            if debitos:
                self._linea(self.cuentas[acc], fecha, -d2(debitos * Decimal("0.006")), "TAX",
                            "IMP LEY 25413 S/DEBITOS")
        # Comisión de mantenimiento: último día hábil de cada mes, equivalente a USD 30.
        ultimos = {}
        for d in HABILES:
            ultimos[mes(d)] = d
        for d in ultimos.values():
            for c in self.cuentas.values():
                self._linea(c, d, -self.de_usd(30, c["currency"], d), "FEE", "COMISION MANTENIMIENTO CUENTA")

    def asignar_ids_y_saldos(self):
        """Ordena el extracto, asigna ids de línea y calcula saldos mensuales por cuenta.
        El saldo inicial se elige para que ninguna cuenta quede en descubierto."""
        r = self.rng
        orden = {"TRF_IN": 0, "FX": 1, "TRF_OUT": 2, "FEE": 3, "TAX": 4}
        self.lineas.sort(key=lambda l: (l["_cuenta"]["account_id"], l["_fecha"], orden[l["_codigo"]],
                                        l["_desc"], l["_monto"]))
        seq = defaultdict(int)
        for l in self.lineas:
            c = l["_cuenta"]
            k = (c["account_id"], l["_fecha"])
            seq[k] += 1
            lid = f"{c['bank_id']}{c['account_id'][-2:]}-{l['_fecha']:%Y%m%d}-{seq[k]:04d}"
            ref = ""
            if l["_codigo"].startswith("TRF"):
                ref = f"TRN{r.randint(10**9, 10**10 - 1)}"
            elif l["_codigo"] == "FX":
                ref = l["_desc"].split()[-1]
            l.update({"statement_line_id": lid, "account_number": c["account_number"],
                      "booking_date": l["_fecha"].isoformat(), "value_date": l["_valor"].isoformat(),
                      "currency": c["currency"], "amount": f"{l['_monto']:.2f}", "bank_tx_code": l["_codigo"],
                      "description": l["_desc"], "bank_reference": ref, "_mes": mes(l["_fecha"]),
                      "_orden": (l["_fecha"].isoformat(), lid, 0)})

        self.saldos = []
        meses = sorted({mes(d) for d in HABILES})
        for c in self.cuentas.values():
            movs = defaultdict(lambda: [Decimal(0), Decimal(0), 0])
            acumulado, minimo = Decimal(0), Decimal(0)
            for l in self.lineas:
                if l["_cuenta"] is c:
                    acumulado += l["_monto"]
                    minimo = min(minimo, acumulado)
                    m = movs[mes(l["_fecha"])]
                    m[0 if l["_monto"] > 0 else 1] += l["_monto"]
                    m[2] += 1
            colchon = self.de_usd(50_000, c["currency"], INICIO)
            saldo = Decimal(math.ceil((-minimo + colchon) / 1000) * 1000)
            for m in meses:
                cred, deb, n = movs[m]
                cierre = saldo + cred + deb
                self.saldos.append({"account_number": c["account_number"], "period": m,
                                    "currency": c["currency"], "opening_balance": f"{saldo:.2f}",
                                    "total_credits": f"{cred:.2f}", "total_debits": f"{deb:.2f}",
                                    "closing_balance": f"{cierre:.2f}", "line_count": str(n),
                                    "_mes": m, "_orden": (m, c["account_id"], 0)})
                saldo = cierre

    # ------------------------------------------------------------------ errores de "representación"
    def inyectar_errores(self):
        """Errores en cómo viene escrito el dato (no en lo que pasó en el banco)."""
        r, iny = self.rng, self.iny
        ids_fact = {f["invoice_id"] for f in self.facturas}

        def poner(fila, tabla, tipo, cat, campo, valor, desc):
            iny.registrar(fila, tabla, tipo, cat, campo, fila[campo], valor, desc)
            fila[campo] = valor

        def duplicar(lista, fila, tabla, tipo, desc, **cambios):
            dup = {k: v for k, v in fila.items() if k != "_errores"}
            dup.update(cambios)
            dup["_orden"] = fila["_orden"][:2] + (1,)
            lista.append(dup)
            iny._usadas.add(id(dup))  # la copia no puede recibir otro error
            iny.registrar(dup, tabla, tipo, "duplicados", None, None, None, desc)
            return dup

        fechas_invalidas = ["2026-02-30", "2026-04-31", "2026-13-05", "2025-11-31", "2026-06-31"]
        monedas_invalidas = ["US$", "AR$", "DOLARES", "REALES"]

        # ---- payments
        P = self.pagos
        for p in iny.elegir(P, 10):
            duplicar(P, p, "payments", "DUP_EXACTO", "Fila de pago repetida en la exportación del ERP")
        for p in iny.elegir(P, 6):
            poner(p, "payments", "NULO", "nulos", "counterparty_id", "", "Pago sin contraparte")
        for p in iny.elegir(P, 4):
            poner(p, "payments", "FECHA_INVALIDA", "fechas_imposibles", "payment_date",
                  r.choice(fechas_invalidas), "Fecha de pago inexistente en el calendario")
        for p in iny.elegir(P, 4):
            futura = p["_fecha"].replace(year=p["_fecha"].year + 1).isoformat()
            poner(p, "payments", "FECHA_FUTURA", "fechas_imposibles", "payment_date", futura,
                  "Fecha de pago posterior al corte de la extracción")
        for p in iny.elegir(P, 8):
            poner(p, "payments", "MONTO_NEGATIVO", "montos_negativos", "amount", f"-{p['amount']}",
                  "Monto de pago negativo")
        for p in iny.elegir(P, 8):
            poner(p, "payments", "MONEDA_INCONSISTENTE", "monedas_inconsistentes", "currency",
                  r.choice([m for m in MONEDAS if m != p["currency"]]),
                  "Moneda del pago distinta a la de la factura y la cuenta")
        for p in iny.elegir(P, 4):
            poner(p, "payments", "MONEDA_INVALIDA", "monedas_inconsistentes", "currency",
                  r.choice(monedas_invalidas), "Código de moneda que no es ISO 4217")
        for p in iny.elegir(P, 10):
            falso = f"INV-9{r.randint(0, 999999):06d}"
            while falso in ids_fact:
                falso = f"INV-9{r.randint(0, 999999):06d}"
            poner(p, "payments", "PAGO_SIN_FACTURA", "pagos_sin_factura", "invoice_id", falso,
                  "Pago que referencia una factura inexistente")
        cps_ids = {c.id for c in self.cps}
        for p in iny.elegir(P, 5):
            falso = f"CP9{r.randint(0, 999):03d}"
            while falso in cps_ids:
                falso = f"CP9{r.randint(0, 999):03d}"
            poner(p, "payments", "CONTRAPARTE_INEXISTENTE", "integridad_referencial", "counterparty_id",
                  falso, "Pago a una contraparte que no está en el maestro")

        # ---- invoices
        F = self.facturas
        siguiente = len(F) + 1
        for f in iny.elegir(F, 8):
            duplicar(F, f, "invoices", "DUP_LOGICO",
                     "Misma factura del proveedor cargada dos veces con otro id interno",
                     invoice_id=f"INV-{siguiente:07d}")
            siguiente += 1
        for f in iny.elegir(F, 5):
            poner(f, "invoices", "NULO", "nulos", "amount", "", "Factura sin monto")
        for f in iny.elegir(F, 4):
            poner(f, "invoices", "NULO", "nulos", "due_date", "", "Factura sin fecha de vencimiento")
        for f in iny.elegir(F, 8):
            vto = (f["_fecha"] - timedelta(days=r.randint(10, 40))).isoformat()
            poner(f, "invoices", "VENCIMIENTO_ANTERIOR_A_EMISION", "fechas_imposibles", "due_date", vto,
                  "Vencimiento anterior a la fecha de emisión")
        for f in iny.elegir(F, 5):
            poner(f, "invoices", "MONTO_NEGATIVO", "montos_negativos", "amount", f"-{f['amount']}",
                  "Monto de factura negativo")
        for f in iny.elegir(F, 6, lambda f: f["_monto"] >= 1000):
            poner(f, "invoices", "FORMATO_MONTO", "formato_invalido", "amount", formato_ar(f["_monto"]),
                  "Monto con formato regional (punto de miles y coma decimal)")

        # ---- collections
        C = self.cobranzas
        for c in iny.elegir(C, 6):
            duplicar(C, c, "collections", "DUP_EXACTO", "Fila de cobranza repetida en la exportación")
        for c in iny.elegir(C, 6):
            poner(c, "collections", "NULO", "nulos", "currency", "", "Cobranza sin moneda")
        for c in iny.elegir(C, 4):
            poner(c, "collections", "MONTO_NEGATIVO", "montos_negativos", "amount", f"-{c['amount']}",
                  "Monto de cobranza negativo")
        for c in iny.elegir(C, 5):
            poner(c, "collections", "MONEDA_INCONSISTENTE", "monedas_inconsistentes", "currency",
                  r.choice([m for m in MONEDAS if m != c["currency"]]),
                  "Moneda de la cobranza distinta a la de la factura y la cuenta")
        for c in iny.elegir(C, 5):
            falso = f"INV-9{r.randint(0, 999999):06d}"
            poner(c, "collections", "COBRANZA_SIN_FACTURA", "pagos_sin_factura", "invoice_id", falso,
                  "Cobranza que referencia una factura inexistente")

        # ---- bank_statements
        L = self.lineas
        trf = lambda l: l["_codigo"].startswith("TRF") and l["_erp"] is not None  # noqa: E731
        for l in iny.elegir(L, 10, lambda l: trf(l) and l["_fecha"] < date(2026, 10, 1)):
            sig = habil_siguiente((l["_fecha"].replace(day=1) + timedelta(days=32)).replace(day=1))
            duplicar(L, l, "bank_statements", "DUP_REENVIO",
                     "El banco reenvía la línea en el extracto del mes siguiente", _mes=mes(sig))
        for l in iny.elegir(L, 3, trf):
            poner(l, "bank_statements", "NULO", "nulos", "amount", "", "Línea de extracto sin importe")
        for l in iny.elegir(L, 3, trf):
            poner(l, "bank_statements", "FECHA_INVALIDA", "fechas_imposibles", "booking_date",
                  r.choice(fechas_invalidas), "Fecha de imputación inexistente")

        # ---- counterparties (el error vive en el maestro y aparece en ambos snapshots)
        limpias = [c for c in self.cps if not c.nueva and not c.v2]
        elegidas = r.sample(limpias, 7)
        for cp in elegidas[:3]:
            malo = cp.email.replace("@", ".")
            cp.errores.append(iny.registrar(None, "counterparties", "EMAIL_INVALIDO", "formato_invalido",
                                            "email", cp.email, malo, "Email sin @",
                                            clave={"counterparty_id": cp.id}))
            cp.email = malo
        for cp in elegidas[3:5]:
            cp.errores.append(iny.registrar(None, "counterparties", "NULO", "nulos", "tax_id", cp.tax_id, "",
                                            "Contraparte sin identificación fiscal",
                                            clave={"counterparty_id": cp.id}))
            cp.tax_id = ""
        for cp in elegidas[5:7]:
            otra = r.choice([c for c in self.cps if c.pais == cp.pais and c is not cp and c not in elegidas])
            cp.errores.append(iny.registrar(None, "counterparties", "TAX_ID_DUPLICADO", "duplicados", "tax_id",
                                            cp.tax_id, otra.tax_id,
                                            f"Misma identificación fiscal que {otra.id}",
                                            clave={"counterparty_id": cp.id}))
            cp.tax_id = otra.tax_id

        # ---- fx_rates
        X = [x for x in self.fx_filas if x["currency"] != "USD"]
        faltantes = iny.elegir(X, 3)
        ids_faltantes = {id(x) for x in faltantes}
        self.fx_filas = [x for x in self.fx_filas if id(x) not in ids_faltantes]
        for x in faltantes:
            iny.registrar(None, "fx_rates", "COTIZACION_FALTANTE", "completitud", None, None, None,
                          "Día hábil sin cotización publicada",
                          clave={"rate_date": x["rate_date"], "currency": x["currency"]})
        for x in iny.elegir(X, 2):
            poner(x, "fx_rates", "NULO", "nulos", "rate_per_usd", "", "Cotización vacía")
        for x in iny.elegir(X, 2):
            poner(x, "fx_rates", "FUERA_DE_RANGO", "valores_fuera_de_rango", "rate_per_usd",
                  f"{Decimal(x['rate_per_usd']) * 10:.6f}", "Cotización 10x (error de tipeo de la coma)")

    # ------------------------------------------------------------------ escritura
    def filas_contrapartes(self, snapshot: date) -> list[dict]:
        filas = []
        for cp in self.cps:
            if cp.nueva and snapshot < SNAPSHOTS[1]:
                continue
            v2 = cp.v2 if snapshot >= SNAPSHOTS[1] else {}
            filas.append({
                "counterparty_id": cp.id, "counterparty_type": cp.tipo, "legal_name": cp.nombre,
                "tax_id": cp.tax_id, "country": cp.pais, "default_currency": cp.moneda,
                "email": v2.get("email", cp.email), "segment": v2.get("segmento", cp.segmento),
                "risk_rating": v2.get("riesgo", cp.riesgo),
                "payment_terms_days": str(v2.get("plazo", cp.plazo)), "is_active": v2.get("activo", "Y"),
                "created_at": cp.alta.isoformat(), "snapshot_date": snapshot.isoformat(),
                "_errores": cp.errores, "_orden": (cp.id, "", 0)})
        return filas

    def escribir(self, salida: Path) -> dict:
        _limpiar_salida(salida)
        archivos: dict[str, int] = {}

        def escribir_csv(rel: str, tabla: str, filas: list[dict]):
            ruta = salida / rel
            ruta.parent.mkdir(parents=True, exist_ok=True)
            with open(ruta, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh, lineterminator="\n")
                w.writerow(COLUMNAS[tabla])
                for i, f in enumerate(sorted(filas, key=lambda f: f["_orden"]), start=2):
                    w.writerow([f[c] for c in COLUMNAS[tabla]])
                    for e in f.get("_errores", []):
                        e["ubicaciones"].append({"archivo": rel, "linea": i})
            archivos[rel] = len(filas)

        escribir_csv("maestros/banks.csv", "banks", [dict(b, _orden=(b["bank_id"],)) for b in self.bancos.values()])
        escribir_csv("maestros/bank_accounts.csv", "bank_accounts",
                     [dict(c, _orden=(c["account_id"],)) for c in self.cuentas.values()])
        for s in SNAPSHOTS:
            escribir_csv(f"maestros/counterparties_{s.isoformat()}.csv", "counterparties", self.filas_contrapartes(s))
        mensuales = {"invoices": self.facturas, "payments": self.pagos, "collections": self.cobranzas,
                     "bank_statements": self.lineas, "bank_balances": self.saldos, "fx_rates": self.fx_filas}
        for tabla, filas in mensuales.items():
            por_mes = defaultdict(list)
            for f in filas:
                por_mes[f["_mes"]].append(f)
            for m in sorted(por_mes):
                escribir_csv(f"{m}/{tabla}.csv", tabla, por_mes[m])

        # Respuesta esperada de la conciliación (Fase 6): qué línea del banco es qué pago/cobranza.
        verdad = salida / "_verdad"
        verdad.mkdir(parents=True, exist_ok=True)
        with open(verdad / "conciliacion_esperada.csv", "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh, lineterminator="\n")
            w.writerow(["statement_line_id", "account_id", "erp_tipo", "erp_id", "erp_reference",
                        "monto_erp", "monto_banco", "diferencia", "dias_habiles_desfase", "referencia_en_descripcion"])
            for l in self.lineas:
                if l.get("_erp") is None or l["_orden"][2] == 1:
                    continue
                tipo, x = l["_erp"]
                monto_erp = -x["_monto"] if tipo == "PAYMENT" else x["_monto"]
                w.writerow([l["statement_line_id"], l["_cuenta"]["account_id"], tipo,
                            x["payment_id"] if tipo == "PAYMENT" else x["collection_id"],
                            x["payment_reference"] if tipo == "PAYMENT" else x["collection_reference"],
                            f"{monto_erp:.2f}", f"{l['_monto']:.2f}", f"{l['_monto'] - monto_erp:.2f}",
                            l["_desfase"], l["_modo_ref"]])
        return archivos

    def manifiesto(self, salida: Path, archivos: dict) -> dict:
        for e in self.iny.errores:
            fila = e.pop("_fila", None)
            if e["clave"] is None and fila is not None:
                pk = PK.get(e["tabla"])
                e["clave"] = {pk: fila[pk]} if pk else {"rate_date": fila["rate_date"], "currency": fila["currency"]}
        por_cat, por_tipo = defaultdict(int), defaultdict(int)
        for e in self.iny.errores:
            por_cat[e["categoria"]] += 1
            por_tipo[f"{e['tabla']}.{e['tipo']}"] += 1
        for a in self.anomalias:
            a.pop("_factura", None)
            a.pop("_pagos", None)
        m = {
            "generador": {"script": "python/generar_datos.py", "version": VERSION, "seed": self.seed,
                          "escala": self.escala, "periodo": {"desde": INICIO.isoformat(), "hasta": FIN.isoformat()},
                          "snapshots_contrapartes": [s.isoformat() for s in SNAPSHOTS]},
            "archivos": {rel: {"filas": n, "sha256": _sha256(salida / rel)} for rel, n in sorted(archivos.items())},
            "total_errores": len(self.iny.errores),
            "errores_por_categoria": dict(sorted(por_cat.items())),
            "errores_por_tipo": dict(sorted(por_tipo.items())),
            "errores": self.iny.errores,
            "ruido_conciliacion": {k: sorted(v) for k, v in sorted(self.ruido.items())},
            "anomalias_negocio": self.anomalias,
            "cambios_scd2": self.cambios_scd2,
        }
        with open(salida / "_verdad" / "errores_inyectados.json", "w", encoding="utf-8") as fh:
            json.dump(m, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        return m

    def correr(self, salida: Path) -> dict:
        self.generar_fx()
        self.generar_bancos_y_cuentas()
        self.generar_contrapartes()
        self.generar_facturas()
        self.anomalia_montos_atipicos()
        self.generar_liquidaciones()
        self.anomalia_doble_pago()
        self.numerar()
        self.generar_lineas_banco()
        self.error_pagos_sin_extracto()     # cambian lo que el banco registró:
        self.error_extractos_sin_match()    # van antes de calcular saldos
        self.generar_conversiones_fx()
        self.generar_comisiones_e_impuestos()
        self.asignar_ids_y_saldos()
        self.inyectar_errores()             # cambian cómo viene escrito el dato
        return self.manifiesto(salida, self.escribir(salida))


def _sha256(ruta: Path) -> str:
    return hashlib.sha256(ruta.read_bytes()).hexdigest()


def _limpiar_salida(salida: Path):
    """Borra solo lo que este script genera (nunca toda la carpeta)."""
    salida.mkdir(parents=True, exist_ok=True)
    for p in salida.iterdir():
        if p.is_dir() and (p.name in ("maestros", "_verdad") or re.fullmatch(r"\d{4}-\d{2}", p.name)):
            shutil.rmtree(p)


def generar(salida: Path, escala: float = 1.0, seed: int = SEED) -> dict:
    return Generador(escala, seed).correr(salida)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--escala", type=float, default=1.0, help="multiplicador de volumen (default 1)")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--salida", type=Path, default=RAIZ / "data")
    a = ap.parse_args()
    m = generar(a.salida, a.escala, a.seed)
    totales = defaultdict(int)
    for rel, info in m["archivos"].items():
        totales[Path(rel).stem.split("_20")[0]] += info["filas"]
    print(f"Datos generados en {a.salida} (seed={a.seed}, escala={a.escala})")
    for t, n in totales.items():
        print(f"  {t:<16} {n:>9,} filas")
    print(f"  errores inyectados: {m['total_errores']} -> {a.salida / '_verdad' / 'errores_inyectados.json'}")
    for cat, n in m["errores_por_categoria"].items():
        print(f"    {cat:<26} {n:>3}")


if __name__ == "__main__":
    main()
