# Resultados de performance (Fase 7)

Generado por `python/medir_performance.py` el 2026-11-19 20:27 sobre `TesoreriaDW_perf` (mediana de 5 corridas en caliente, SQL Server 2022 en Docker emulado amd64 sobre Apple Silicon).

Volumen: `fact_movimientos_bancarios` 113,244 filas, `fact_facturas` 119,972 filas, `fact_cobranzas` 52,327 filas, `fact_pagos` 55,545 filas, `fact_conciliacion` 107,956 filas.

| Consulta | Lecturas lógicas antes | después | mejora | CPU ms antes | después | Total ms antes | después |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Q1** Flujo de caja diario por moneda | 4,087 | 145 | **28.2x** | 116 | 16 | 117 | 15 |
| Q2 solo con índices (consulta original) | 1,302,345 | 1,197,072 | 1.1x | 1,653 | 2,020 | 1,653 | 2,024 |
| **Q2** Evolución mensual de la cartera (CTE recursiva) (reescrita + índices) | 1,302,345 | 3,638 | **358.0x** | 1,653 | 1,166 | 1,653 | 1,166 |
| **Q3** Partidas pendientes de conciliación | 6,553 | 609 | **10.8x** | 87 | 3 | 23 | 4 |

## Planes de ejecución (operadores de acceso a datos)

### Q1. Flujo de caja diario por moneda

**Antes:**

- Clustered Index Scan en dim_moneda (pk_dim_moneda)
- Clustered Index Scan en fact_saldo_bancario_mensual (pk_fact_saldo_bancario_mensual)
- Index Seek en dim_fecha (ux_dim_fecha_fecha)
- Clustered Index Scan en fact_movimientos_bancarios (pk_fact_movimientos_bancarios)

**Después:**

- Clustered Index Scan en fact_saldo_bancario_mensual (pk_fact_saldo_bancario_mensual)
- Index Scan en dim_moneda (uq_dim_moneda_codigo) — batch mode
- Clustered Index Seek en dim_moneda (pk_dim_moneda)
- Index Seek en dim_fecha (ux_dim_fecha_fecha)
- Index Scan en fact_movimientos_bancarios (ncci_fact_movimientos_bancarios) — batch mode

Lecturas por tabla (antes → después): `Workfile` 0 → 0, `Worktable` 747 → 0, `dim_fecha` 2 → 10, `dim_moneda` 2 → 10, `fact_movimientos_bancarios` 3,312 → 121, `fact_saldo_bancario_mensual` 24 → 4

Planes completos: `planes/Q1_antes.sqlplan`, `planes/Q1_despues.sqlplan`.

### Q2. Evolución mensual de la cartera (CTE recursiva)

**Antes:**

- Clustered Index Scan en dim_fecha (pk_dim_fecha)
- Clustered Index Scan en fact_facturas (pk_fact_facturas)
- Clustered Index Scan en fact_cobranzas (pk_fact_cobranzas)

**Después:**

- Clustered Index Scan en dim_fecha (pk_dim_fecha)
- Index Scan en fact_cobranzas (ix_fact_cobranzas_factura)
- Index Seek en fact_facturas (fx_fact_facturas_ar_emision)

Lecturas por tabla (antes → después): `Workfile` 0 → 0, `Worktable` 1,264,679 → 73, `dim_fecha` 468 → 78, `fact_cobranzas` 1,054 → 358, `fact_facturas` 36,144 → 3,129

Planes completos: `planes/Q2_antes.sqlplan`, `planes/Q2_despues.sqlplan`.

### Q3. Partidas pendientes de conciliación

**Antes:**

- Clustered Index Seek en dim_fecha (pk_dim_fecha)
- Clustered Index Scan en fact_conciliacion (pk_fact_conciliacion)
- Clustered Index Seek en dim_banco_cuenta (pk_dim_banco_cuenta)
- Index Seek en fact_movimientos_bancarios (uq_fact_movimientos_linea)
- Clustered Index Seek en fact_movimientos_bancarios (pk_fact_movimientos_bancarios)

**Después:**

- Clustered Index Scan en dim_banco_cuenta (pk_dim_banco_cuenta) — batch mode
- Index Seek en fact_conciliacion (fx_fact_conciliacion_pendientes) — batch mode
- Clustered Index Seek en dim_fecha (pk_dim_fecha) — batch mode
- Clustered Index Seek en dim_fecha (pk_dim_fecha)
- Index Seek en fact_movimientos_bancarios (uq_fact_movimientos_linea)
- Clustered Index Seek en fact_movimientos_bancarios (pk_fact_movimientos_bancarios)

Lecturas por tabla (antes → después): `Worktable` 0 → 0, `dim_banco_cuenta` 510 → 2, `dim_fecha` 224 → 78, `fact_conciliacion` 5,268 → 11, `fact_movimientos_bancarios` 551 → 518

Planes completos: `planes/Q3_antes.sqlplan`, `planes/Q3_despues.sqlplan`.
