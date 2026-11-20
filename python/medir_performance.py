#!/usr/bin/env python3
"""
medir_performance.py — Mide 3 consultas antes y después de los índices de la Fase 7.

Metodología (la misma que se usaría a mano en Azure Data Studio):
  1. Línea base: se quitan los índices de la Fase 7 (sql/07_performance/00_quitar_indices.sql).
  2. Por consulta: 1 corrida de calentamiento (para que el caché y el plan no distorsionen) y
     N corridas medidas con SET STATISTICS IO, TIME ON. Se toma la MEDIANA.
  3. Se captura el plan de ejecución REAL (SET STATISTICS XML ON) y se guarda como .sqlplan
     (se abre con doble clic en Azure Data Studio / SSMS).
  4. Se crean los índices (sql/02_dw/04_indices.sql) y se repiten 2 y 3.
  5. Se escribe sql/07_performance/resultados.md con la tabla antes/después.

Métrica principal: LECTURAS LÓGICAS (páginas de 8 KB leídas de memoria). No dependen del caché
ni de la carga de la máquina: son la medida estable del "trabajo" de una consulta. El tiempo
se informa también, pero en un contenedor emulado (Apple Silicon) varía más.

Uso:
    python python/medir_performance.py --base TesoreriaDW_perf --repeticiones 5
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

from db import RAIZ, conectar
from ejecutar_sql import lotes

# id -> (título, consulta "antes", consulta "después"). Q2 además se reescribe: se mide la original
# con índices ("solo índice") para separar cuánto aportó el índice y cuánto la reescritura.
CONSULTAS = {
    "Q1": ("Flujo de caja diario por moneda", "sql/07_performance/01_q1_flujo_caja.sql",
           "sql/07_performance/01_q1_flujo_caja.sql"),
    "Q2": ("Evolución mensual de la cartera (CTE recursiva)", "sql/07_performance/02_q2_evolucion_cartera.sql",
           "sql/07_performance/02b_q2_evolucion_cartera_reescrita.sql"),
    "Q3": ("Partidas pendientes de conciliación", "sql/07_performance/03_q3_pendientes_conciliacion.sql",
           "sql/07_performance/03_q3_pendientes_conciliacion.sql"),
}
DIR_PERF = RAIZ / "sql" / "07_performance"
NS = {"p": "http://schemas.microsoft.com/sqlserver/2004/07/showplan"}


def consulta_principal(ruta: Path, base: str) -> str:
    """El lote que contiene la consulta (sin USE ni SET STATISTICS, que pone este script)."""
    return next(b for b in lotes(ruta, base) if "SELECT" in b.upper() and "SET STATISTICS" not in b.upper()
                and not b.strip().upper().startswith("SET NOCOUNT"))


def ejecutar_con_mensajes(cn, sql: str) -> tuple[list[str], list[str]]:
    """Ejecuta y devuelve (mensajes informativos, planes XML). Consume todos los result sets."""
    cur = cn.cursor()
    cur.execute(sql)
    mensajes, planes = [m[1] for m in cur.messages], []
    while True:
        if cur.description:
            filas = cur.fetchall()
            if cur.description[0][0].startswith("Microsoft SQL Server") and filas:
                planes.append(filas[0][0])
        if not cur.nextset():
            break
        mensajes += [m[1] for m in cur.messages]
    return mensajes, planes


def parsear(mensajes: list[str]) -> dict:
    lecturas, por_tabla, cpu, total = 0, {}, 0, 0
    for m in mensajes:
        t = re.search(r"Table '([^']+)'", m)
        if t:
            n = sum(int(x) for x in re.findall(r"(?:lob )?logical reads (\d+)", m))
            por_tabla[t.group(1)] = por_tabla.get(t.group(1), 0) + n
            lecturas += n
        e = re.search(r"SQL Server Execution Times:\s*CPU time = (\d+) ms,\s*elapsed time = (\d+) ms", m)
        if e:
            cpu += int(e.group(1))
            total += int(e.group(2))
    return {"lecturas_logicas": lecturas, "por_tabla": por_tabla, "cpu_ms": cpu, "total_ms": total}


def resumir_plan(xml: str) -> list[str]:
    """Operadores físicos relevantes del plan (scan/seek/columnstore), con su modo de ejecución."""
    raiz = ET.fromstring(xml)
    vistos = []
    for op in raiz.iter("{%s}RelOp" % NS["p"]):
        fisico = op.get("PhysicalOp")
        obj = op.find(".//p:Object", NS)
        if fisico and obj is not None and any(k in fisico for k in ("Scan", "Seek")):
            tabla = (obj.get("Table") or "").strip("[]")
            if tabla.startswith("#") or not tabla:
                continue
            indice = (obj.get("Index") or "").strip("[]")
            modo = op.get("EstimatedExecutionMode") or op.get("ActualExecutionMode") or ""
            texto = f"{fisico} en {tabla}" + (f" ({indice})" if indice else "") + (" — batch mode" if modo == "Batch" else "")
            if texto not in vistos:
                vistos.append(texto)
    return vistos


def medir(cn, base: str, etiqueta: str, repeticiones: int) -> dict:
    """etiqueta: 'antes' (consulta original, sin índices), 'solo_indice' (original con índices,
    solo para las que se reescriben) o 'despues' (consulta final con índices)."""
    res = {}
    for q, (titulo, ruta_antes, ruta_despues) in CONSULTAS.items():
        if etiqueta == "solo_indice" and ruta_antes == ruta_despues:
            continue
        ruta = ruta_despues if etiqueta == "despues" else ruta_antes
        sql = consulta_principal(RAIZ / ruta, base)
        ejecutar_con_mensajes(cn, sql)                                          # calentamiento
        corridas = [parsear(ejecutar_con_mensajes(cn, "SET STATISTICS IO, TIME ON;\n" + sql)[0])
                    for _ in range(repeticiones)]
        _, planes = ejecutar_con_mensajes(cn, "SET STATISTICS XML ON;\n" + sql + "\n;SET STATISTICS XML OFF;")
        plan = max(planes, key=len)
        (DIR_PERF / "planes").mkdir(exist_ok=True)
        (DIR_PERF / "planes" / f"{q}_{etiqueta}.sqlplan").write_text(plan, encoding="utf-8")
        cn.execute("SET STATISTICS IO, TIME OFF")
        res[q] = {"titulo": titulo,
                  "lecturas_logicas": int(statistics.median(c["lecturas_logicas"] for c in corridas)),
                  "por_tabla": corridas[-1]["por_tabla"],
                  "cpu_ms": int(statistics.median(c["cpu_ms"] for c in corridas)),
                  "total_ms": int(statistics.median(c["total_ms"] for c in corridas)),
                  "operadores": resumir_plan(plan)}
        print(f"  {etiqueta:<7} {q}: {res[q]['lecturas_logicas']:>9,} lecturas  {res[q]['cpu_ms']:>6} ms CPU  "
              f"{res[q]['total_ms']:>6} ms total")
    return res


def ejecutar_archivo(cn, ruta: str, base: str):
    for lote in lotes(RAIZ / ruta, base):
        cn.execute(lote)


def volumen(cn) -> dict:
    tablas = ["fact_movimientos_bancarios", "fact_facturas", "fact_cobranzas", "fact_pagos", "fact_conciliacion"]
    return {t: cn.execute(f"SELECT COUNT(*) FROM dw.{t}").fetchone()[0] for t in tablas}


def escribir_resultados(base: str, vol: dict, antes: dict, despues: dict, repeticiones: int, solo_indice: dict):
    def mejora(a, d):
        return f"{a / d:,.1f}x" if d else "∞"
    lineas = [
        "# Resultados de performance (Fase 7)", "",
        f"Generado por `python/medir_performance.py` el {datetime.now():%Y-%m-%d %H:%M} sobre `{base}` "
        f"(mediana de {repeticiones} corridas en caliente, SQL Server 2022 en Docker emulado amd64 sobre Apple Silicon).", "",
        "Volumen: " + ", ".join(f"`{t}` {n:,} filas" for t, n in vol.items()) + ".", "",
        "| Consulta | Lecturas lógicas antes | después | mejora | CPU ms antes | después | Total ms antes | después |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for q in CONSULTAS:
        a, d = antes[q], despues[q]
        if q in solo_indice:   # fila intermedia: el índice solo, sin reescribir la consulta
            i = solo_indice[q]
            lineas.append(f"| {q} solo con índices (consulta original) | {a['lecturas_logicas']:,} | {i['lecturas_logicas']:,} | "
                          f"{mejora(a['lecturas_logicas'], i['lecturas_logicas'])} | {a['cpu_ms']:,} | {i['cpu_ms']:,} | "
                          f"{a['total_ms']:,} | {i['total_ms']:,} |")
        sufijo = " (reescrita + índices)" if q in solo_indice else ""
        lineas.append(f"| **{q}** {a['titulo']}{sufijo} | {a['lecturas_logicas']:,} | {d['lecturas_logicas']:,} | "
                      f"**{mejora(a['lecturas_logicas'], d['lecturas_logicas'])}** | {a['cpu_ms']:,} | {d['cpu_ms']:,} | "
                      f"{a['total_ms']:,} | {d['total_ms']:,} |")
    lineas += ["", "## Planes de ejecución (operadores de acceso a datos)", ""]
    for q in CONSULTAS:
        lineas += [f"### {q}. {antes[q]['titulo']}", "", "**Antes:**", ""]
        lineas += [f"- {o}" for o in antes[q]["operadores"]] + ["", "**Después:**", ""]
        lineas += [f"- {o}" for o in despues[q]["operadores"]] + [""]
        lineas += ["Lecturas por tabla (antes → después): " + ", ".join(
            f"`{t}` {antes[q]['por_tabla'].get(t, 0):,} → {despues[q]['por_tabla'].get(t, 0):,}"
            for t in sorted(set(antes[q]["por_tabla"]) | set(despues[q]["por_tabla"]))) + "", "",
                   f"Planes completos: `planes/{q}_antes.sqlplan`, `planes/{q}_despues.sqlplan`.", ""]
    (DIR_PERF / "resultados.md").write_text("\n".join(lineas), encoding="utf-8")
    (DIR_PERF / "resultados.json").write_text(json.dumps({"antes": antes, "solo_indice": solo_indice,
                                                          "despues": despues, "volumen": vol},
                                                         ensure_ascii=False, indent=2), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", default="TesoreriaDW_perf")
    ap.add_argument("--repeticiones", type=int, default=5)
    a = ap.parse_args()
    with conectar(database=a.base, autocommit=True) as cn:
        vol = volumen(cn)
        print("Volumen:", vol)
        ejecutar_archivo(cn, "sql/07_performance/00_quitar_indices.sql", a.base)
        print("Línea base (sin índices de la Fase 7):")
        antes = medir(cn, a.base, "antes", a.repeticiones)
        ejecutar_archivo(cn, "sql/02_dw/04_indices.sql", a.base)
        print("Con índices, consulta original (solo las que se reescriben):")
        solo_indice = medir(cn, a.base, "solo_indice", a.repeticiones)
        print("Con índices (consulta final):")
        despues = medir(cn, a.base, "despues", a.repeticiones)
        escribir_resultados(a.base, vol, antes, despues, a.repeticiones, solo_indice)
    print(f"Resultados en {DIR_PERF / 'resultados.md'}")


if __name__ == "__main__":
    main()
