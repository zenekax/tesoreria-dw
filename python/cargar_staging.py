#!/usr/bin/env python3
"""
cargar_staging.py — Carga los CSV de `data/` a las tablas `stg.*` tal cual vienen (EL de ELT).

Analogía: es el cadete que lleva cada extracto al archivo. No corrige nada; abrocha el papel
en la carpeta correcta, anota en la bitácora (audit.carga_staging) qué trajo y cuándo, y si
el mismo extracto ya estaba abrochado, no lo vuelve a abrochar.

Reglas de idempotencia (por archivo, dentro de una transacción):
  - mismo sha256 que la última carga exitosa Y staging tiene esas filas -> OMITIDO
  - archivo nuevo                                                       -> CARGADO
  - archivo que cambió (o filas que faltan en staging)                  -> REEMPLAZADO
    (se borran las filas de ese archivo y se cargan de nuevo, todo o nada)
Por eso se puede correr N veces, o mes a mes (carga incremental), sin duplicar.

Controles antes de insertar (si fallan, el archivo queda en ERROR y no se toca staging):
  - el encabezado del CSV coincide con las columnas de la tabla (detecta cambios de formato)
  - ningún valor excede el largo de su columna (avisa columna y línea)

Uso:
    python python/cargar_staging.py                    # todo lo que haya en data/
    python python/cargar_staging.py --mes 2026-03      # solo maestros + ese mes
    python python/cargar_staging.py --recargar         # fuerza recargar aunque no cambie
Sale con código 1 si algún archivo quedó en ERROR.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import logging
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pyodbc

from db import RAIZ, conectar_etl

LOTE = 5_000  # filas por executemany: balance entre memoria y viajes a la base
log = logging.getLogger("cargar_staging")


def configurar_logging(archivo_log: Path | None) -> None:
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    raiz = logging.getLogger()
    raiz.setLevel(logging.DEBUG)
    consola = logging.StreamHandler(sys.stdout)
    consola.setLevel(logging.INFO)
    consola.setFormatter(fmt)
    raiz.addHandler(consola)
    if archivo_log:
        archivo_log.parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(archivo_log, encoding="utf-8")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        raiz.addHandler(fh)


def tabla_destino(rel: str) -> str:
    """'2026-03/payments.csv' -> 'payments'; 'maestros/counterparties_2025-11-01.csv' -> 'counterparties'."""
    return re.sub(r"_\d{4}-\d{2}-\d{2}$", "", Path(rel).stem)


def descubrir_archivos(datos: Path, meses: list[str] | None) -> list[Path]:
    """Maestros primero, después los meses en orden. `_verdad/` no es una fuente: se ignora."""
    archivos = sorted((datos / "maestros").glob("*.csv"))
    for carpeta in sorted(p for p in datos.iterdir() if p.is_dir() and re.fullmatch(r"\d{4}-\d{2}", p.name)):
        if meses is None or carpeta.name in meses:
            archivos += sorted(carpeta.glob("*.csv"))
    return archivos


def sha256(ruta: Path) -> str:
    return hashlib.sha256(ruta.read_bytes()).hexdigest()


class Cargador:
    def __init__(self, cn: pyodbc.Connection, datos: Path, recargar: bool):
        self.cn, self.datos, self.recargar = cn, datos, recargar
        self.ejecucion_id = str(uuid.uuid4())
        self._columnas: dict[str, list[tuple[str, int]]] = {}

    def columnas(self, tabla: str) -> list[tuple[str, int]]:
        """Columnas de negocio (sin las técnicas "_...") en orden, con su largo máximo en caracteres."""
        if tabla not in self._columnas:
            filas = self.cn.execute(
                "SELECT c.name, c.max_length / 2 FROM sys.columns c "
                "WHERE c.object_id = OBJECT_ID(?) AND c.name NOT LIKE '\\_%' ESCAPE '\\' "
                "ORDER BY c.column_id", f"stg.{tabla}").fetchall()
            if not filas:
                raise RuntimeError(f"No existe la tabla stg.{tabla} (¿corriste scripts/run_sql.sh?)")
            self._columnas[tabla] = [(n, int(l)) for n, l in filas]
        return self._columnas[tabla]

    def _bitacora(self, cur, rel, tabla, resultado, inicio, **campos) -> int:
        cur.execute(
            "INSERT INTO audit.carga_staging (ejecucion_id, archivo, tabla_destino, sha256, filas_archivo, "
            "filas_cargadas, resultado, mensaje, inicio_utc, fin_utc) "
            "OUTPUT INSERTED.carga_id VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            self.ejecucion_id, rel, tabla, campos.get("sha"), campos.get("filas_archivo"),
            campos.get("filas_cargadas"), resultado, campos.get("mensaje"), inicio, campos.get("fin"))
        return cur.fetchone()[0]

    def cargar_archivo(self, ruta: Path) -> str:
        rel = ruta.relative_to(self.datos).as_posix()
        tabla = tabla_destino(rel)
        inicio = datetime.now(timezone.utc).replace(tzinfo=None)
        t0 = time.perf_counter()
        hash_ = sha256(ruta)
        cur = self.cn.cursor()
        try:
            columnas = self.columnas(tabla)
            nombres = [c for c, _ in columnas]
            with open(ruta, encoding="utf-8", newline="") as fh:
                lector = csv.reader(fh)
                encabezado = next(lector, [])
                if encabezado != nombres:
                    raise ValueError(f"encabezado distinto al esperado por stg.{tabla}: "
                                     f"{encabezado} != {nombres}")
                # (linea, valores). '' -> NULL: en un CSV no hay otra forma de expresar "sin dato".
                filas = [(i, [v if v != "" else None for v in valores])
                         for i, valores in enumerate(lector, start=2)]
            for linea, valores in filas:
                if len(valores) != len(nombres):
                    raise ValueError(f"línea {linea}: {len(valores)} campos, se esperaban {len(nombres)}")
                for (col, largo), v in zip(columnas, valores):
                    if v is not None and len(v) > largo:
                        raise ValueError(f"línea {linea}: '{col}' tiene {len(v)} caracteres (máx. {largo})")

            # ¿Ya está cargado exactamente este archivo?
            previo = cur.execute(
                "SELECT TOP (1) sha256, filas_cargadas FROM audit.carga_staging "
                "WHERE archivo = ? AND resultado IN ('CARGADO', 'REEMPLAZADO') ORDER BY carga_id DESC",
                rel).fetchone()
            en_stg = cur.execute(f"SELECT COUNT(*) FROM stg.{tabla} WHERE _source_file = ?", rel).fetchone()[0]
            if not self.recargar and previo and previo[0] == hash_ and previo[1] == en_stg == len(filas):
                self._bitacora(cur, rel, tabla, "OMITIDO", inicio, sha=hash_, filas_archivo=len(filas),
                               filas_cargadas=0, mensaje="sin cambios desde la última carga",
                               fin=datetime.now(timezone.utc).replace(tzinfo=None))
                self.cn.commit()
                log.debug("OMITIDO     %-45s sin cambios", rel)
                return "OMITIDO"

            # Transacción por archivo: o queda entero o no queda nada (autocommit está apagado).
            resultado = "REEMPLAZADO" if en_stg else "CARGADO"
            carga_id = self._bitacora(cur, rel, tabla, "EN_CURSO", inicio, sha=hash_, filas_archivo=len(filas))
            if en_stg:
                cur.execute(f"DELETE FROM stg.{tabla} WHERE _source_file = ?", rel)
            cols_sql = ", ".join(["_carga_id", "_source_file", "_source_line", "_loaded_at"] + nombres)
            sql = f"INSERT INTO stg.{tabla} ({cols_sql}) VALUES ({', '.join('?' * (4 + len(nombres)))})"
            cur.fast_executemany = True  # envía el lote entero en un solo viaje (array binding)
            cur.setinputsizes([(pyodbc.SQL_INTEGER, 0, 0), (pyodbc.SQL_WVARCHAR, 260, 0),
                               (pyodbc.SQL_INTEGER, 0, 0), (pyodbc.SQL_TYPE_TIMESTAMP, 23, 3)]
                              + [(pyodbc.SQL_WVARCHAR, largo, 0) for _, largo in columnas])
            for i in range(0, len(filas), LOTE):
                cur.executemany(sql, [[carga_id, rel, linea, inicio] + valores
                                      for linea, valores in filas[i:i + LOTE]])
            cur.fast_executemany = False
            cur.setinputsizes(None)
            cur.execute("UPDATE audit.carga_staging SET resultado = ?, filas_cargadas = ?, fin_utc = ? "
                        "WHERE carga_id = ?", resultado, len(filas),
                        datetime.now(timezone.utc).replace(tzinfo=None), carga_id)
            self.cn.commit()
            log.info("%-11s %-45s %7d filas  %6.2fs", resultado, rel, len(filas), time.perf_counter() - t0)
            return resultado

        except Exception as e:  # noqa: BLE001 - se registra y se sigue con el próximo archivo
            self.cn.rollback()
            mensaje = f"{type(e).__name__}: {e}"[:2000]
            try:
                self._bitacora(self.cn.cursor(), rel, tabla, "ERROR", inicio, sha=hash_, mensaje=mensaje,
                               fin=datetime.now(timezone.utc).replace(tzinfo=None))
                self.cn.commit()
            except pyodbc.Error:
                self.cn.rollback()
                log.exception("no se pudo registrar el error en audit.carga_staging")
            log.error("ERROR       %-45s %s", rel, mensaje)
            return "ERROR"


def cargar(datos: Path, meses: list[str] | None = None, recargar: bool = False,
           database: str | None = None) -> dict[str, list[str]]:
    """Carga todos los archivos y devuelve {resultado: [archivos]}. Importable desde los tests."""
    archivos = descubrir_archivos(datos, meses)
    if not archivos:
        raise SystemExit(f"No hay CSV en {datos} (¿corriste python/generar_datos.py?)")
    resumen: dict[str, list[str]] = {}
    with conectar_etl(database) as cn:
        c = Cargador(cn, datos, recargar)
        log.info("Ejecución %s: %d archivos desde %s", c.ejecucion_id, len(archivos), datos)
        t0 = time.perf_counter()
        for ruta in archivos:
            r = c.cargar_archivo(ruta)
            resumen.setdefault(r, []).append(ruta.relative_to(datos).as_posix())
        log.info("Fin en %.1fs: %s", time.perf_counter() - t0,
                 ", ".join(f"{k}={len(v)}" for k, v in sorted(resumen.items())))
    return resumen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--datos", type=Path, default=RAIZ / "data")
    ap.add_argument("--mes", action="append", metavar="AAAA-MM", help="cargar solo estos meses (repetible)")
    ap.add_argument("--recargar", action="store_true", help="recargar aunque el archivo no haya cambiado")
    ap.add_argument("--base", help="base destino (default: MSSQL_DATABASE del .env)")
    ap.add_argument("--log", type=Path, default=RAIZ / "logs" / "cargar_staging.log")
    a = ap.parse_args()
    configurar_logging(a.log)
    resumen = cargar(a.datos, a.mes, a.recargar, a.base)
    return 1 if "ERROR" in resumen else 0


if __name__ == "__main__":
    sys.exit(main())
