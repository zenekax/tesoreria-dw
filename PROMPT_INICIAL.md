# Prompt inicial para Claude Code

> Copiá todo lo que está debajo de la línea y pegalo en Claude Code, parado en la carpeta `tesoreria-dw/` (con `CLAUDE.md` y `docs/REQUISITOS.md` ya adentro).

---

Leé `CLAUDE.md` y `docs/REQUISITOS.md` antes de hacer nada. Vamos a construir `tesoreria-dw`: un data warehouse de tesorería en SQL Server 2022 (Docker) con ETL en Python + T-SQL, control de calidad, seguridad y análisis. Es un proyecto de portfolio para postularme a puestos de analista/desarrollador de datos con SQL Server.

**Cómo quiero trabajar**
- Una fase por vez, en el orden de abajo. Al cerrar cada fase: corré las pruebas, hacé commit en una rama `feat/fase-N-...`, actualizá `README.md` y decime en 5 líneas qué hiciste y qué decisiones tomaste. Esperá mi OK antes de la fase siguiente.
- Antes de escribir código de cada fase, mostrame un plan corto (tablas/archivos que vas a crear) y esperá confirmación solo si hay una decisión de diseño no obvia.
- Explicame lo no trivial como a alguien que viene de tesorería/SAP y está aprendiendo T-SQL avanzado y modelado dimensional.
- Todo reproducible: si borro el contenedor y corro los scripts en orden, tiene que quedar igual.

**Fases**

**Fase 0 — Entorno.** Creá `docker-compose.yml` (SQL Server 2022, `platform: linux/amd64` porque estoy en Mac Apple Silicon), `.env.example`, `.gitignore`, venv de Python y `requirements.txt`. Inicializá Git. Verificá que el contenedor levanta y que podés conectarte con `sqlcmd` o `pyodbc`. Si falta el driver ODBC de Mac, decime el comando de Homebrew exacto.

**Fase 1 — Datos sintéticos.** `python/generar_datos.py` con `faker` y seed fija. Generá ~12 meses de datos de una fintech de remesas/pagos con: bancos y cuentas bancarias (varias monedas: ARS, USD, BRL, MXN, COP), contrapartes (proveedores y clientes/corresponsales), facturas (`invoices`), pagos (`payments`), cobranzas (`collections`), extracto bancario (`bank_statements`) y tipos de cambio diarios. **Inyectá errores a propósito y de forma controlada** (duplicados, nulos, fechas imposibles, montos negativos, monedas inconsistentes, pagos sin factura, extractos sin match) y guardá en un archivo aparte la lista exacta de errores inyectados para poder verificar luego que mis validaciones los detectan.

**Fase 2 — Staging.** Schema `stg` con tablas crudas (todo `NVARCHAR` donde convenga, más columnas `_loaded_at`, `_source_file`, `_row_id`). Script Python de carga con `pyodbc` (`fast_executemany`) y logging.

**Fase 3 — Modelo dimensional.** Diseñá un esquema estrella en schema `dw`: dimensiones (`dim_fecha`, `dim_moneda`, `dim_banco_cuenta`, `dim_contraparte` con SCD tipo 2, `dim_tipo_movimiento`) y hechos (`fact_pagos`, `fact_cobranzas`, `fact_movimientos_bancarios`, y una `fact_conciliacion` tipo accumulating snapshot). Documentá el grano de cada hecho y el diagrama en Mermaid en `docs/modelo.md`. Claves, FKs, constraints y tipos justificados.

**Fase 4 — ETL en T-SQL.** Stored procedures `dw.usp_load_*` idempotentes (MERGE o patrón insert/update explícito, justificá cuál), con `TRY/CATCH`, transacciones, logging en `audit.etl_log` y un `usp_run_etl` orquestador. Incluí carga incremental por fecha.

**Fase 5 — Calidad de datos.** Reglas en `sql/04_quality/` (completitud, unicidad, rangos, integridad referencial lógica, consistencia entre fuentes, totales de control staging vs. DW). Resultados a `audit.dq_resultados`; filas rechazadas a tablas de cuarentena. Un test (pytest) que verifique que se detectaron todos los errores inyectados en la Fase 1. Resumen en `docs/calidad-de-datos.md`.

**Fase 6 — Conciliación y análisis.** Consultas en `sql/06_queries/` que usen CTEs, window functions (`LAG`, `SUM() OVER`, `ROW_NUMBER`, `NTILE`), `CROSS APPLY`, `PIVOT`, SQL dinámico seguro y recursivas donde tenga sentido. Mínimo: conciliación pagos vs. extracto con matching por monto/fecha/referencia y tolerancia, aging de cobranzas, flujo de caja diario por moneda con saldo acumulado, top contrapartes, y detección de anomalías simples. Cada consulta con comentario de negocio de qué responde.

**Fase 7 — Performance.** Elegí 3 consultas lentas con volumen alto (subí el volumen sintético si hace falta), mostrá plan de ejecución y `SET STATISTICS IO, TIME ON` antes/después de agregar índices (clustered, nonclustered con INCLUDE, filtered, columnstore donde aplique). Documentá en `sql/07_performance/` y en el README con una tabla de resultados.

**Fase 8 — Seguridad.** Roles (`rol_lectura_analistas`, `rol_etl`, `rol_auditoria`), `GRANT/DENY` a nivel de schema, Row-Level Security (por ejemplo, analistas ven solo ciertas monedas/países), Dynamic Data Masking en datos sensibles (número de cuenta/CBU, email de contrapartes), y un script que pruebe los permisos con `EXECUTE AS`. Explicá en `docs/seguridad.md` el modelo de amenazas en 10 líneas.

**Fase 9 — Capa de consumo.** Vistas en schema `rpt` para Power BI. Guiame paso a paso para armar un tablero (flujo de caja, aging, conciliación) y dejá guía de capturas en `docs/img/`.

**Fase 10 — Cierre de portfolio.** README final con: problema de negocio, arquitectura (diagrama), cómo levantarlo en 3 comandos, decisiones de diseño, resultados de calidad y performance, y capturas. Completá `docs/uso-de-ia.md`. Preparame 10 preguntas de entrevista que este proyecto me permite responder, con respuestas modelo breves. Dejá un texto de 3 líneas para el CV y otro para LinkedIn.

**Criterios de calidad (no negociables)**
- Nada de credenciales en el repo. Datos 100% sintéticos.
- Cada script corre dos veces seguidas sin romper.
- Si algo no pudo probarse, decímelo explícitamente en vez de asumir que anda.
- Si hay algo que no sepas con certeza (versiones, sintaxis de Mac/Docker), verificalo ejecutando, no lo des por hecho.

Empezá por la Fase 0.
