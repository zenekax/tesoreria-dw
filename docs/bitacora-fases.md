# Bitácora por fase

Detalle de lo que se hizo en cada fase, con sus decisiones, resultados y hallazgos. El resumen está en el
[README](../README.md). Los títulos siguen el orden en que se construyó el proyecto.

## Fase 0: entorno (decisiones)

- **Imagen con tag fijo** (`2022-CU28-ubuntu-22.04`) en vez de `2022-latest`: si se borra el
  contenedor y se vuelve a levantar, la versión es la misma.
- **Límite de memoria** (`MSSQL_MEMORY_LIMIT_MB=2048`) para convivir con otros contenedores.
- **Scripts montados en `/sql` (solo lectura)**: se ejecutan con el `sqlcmd` que trae el
  contenedor, sin depender de herramientas instaladas en el Mac.
- **Schemas por capa** (`stg`, `dw`, `audit`, `sec`): permiten dar permisos por schema en la Fase 8.
- **Recovery model SIMPLE**: no hace falta backup de log en un entorno de portfolio.
- **Workaround de OpenSSL acotado al venv** en vez de cambiar el OpenSSL del sistema: no rompe
  otros programas que ya usan OpenSSL 4.
- Desde la Fase 2 la carga usa el login `tdw_etl` (rol `rol_etl`, mínimo privilegio); `sa` queda solo
  para el despliegue y los tests. En la Fase 8 se agregan los roles de analistas y auditoría.

## Fase 1: datos sintéticos

`python/generar_datos.py` simula el ERP y los bancos de la fintech: facturas AP/AR, pagos, cobranzas,
extractos bancarios, saldos y tipos de cambio, en **archivos mensuales** (como llegan los extractos).
Detalle completo en [docs/datos-sinteticos.md](datos-sinteticos.md).

| | Escala 1 |
|---|---|
| Facturas / pagos / cobranzas | 6.008 / 2.795 / 2.577 |
| Líneas de extracto | 6.440 (transferencias, comisiones, impuesto Ley 25.413, FX) |
| Errores inyectados | **174** en 12 categorías, uno por fila, con archivo y línea en `data/_verdad/errores_inyectados.json` |
| Anomalías de negocio | 5 pagos atípicos, 3 posibles dobles pagos |
| Tiempo de generación | < 1 s (escala 20: ~11 s, 120 mil facturas) |

Decisiones principales:
- **Seed fija y salida determinística**: dos corridas dan archivos idénticos byte a byte (test).
- **Manifiesto exacto**: los tests verifican que cada error está donde dice *y* que toda fila fuera del
  manifiesto está limpia. Así la Fase 5 puede medir falsos positivos y falsos negativos, no solo "detectó algo".
- **Realismo de conciliación**: desfase de fechas, referencias parciales, comisiones descontadas del monto y
  partidas en tránsito. La respuesta correcta está en `data/_verdad/conciliacion_esperada.csv`.
- **Dos snapshots del maestro de contrapartes** (nov-25 y may-26) con cambios de riesgo, plazo y segmento para el SCD2.

## Fase 2: staging

```
data/AAAA-MM/*.csv ──► python/cargar_staging.py ──► stg.<tabla>        (copia fiel, todo NVARCHAR)
   (extractos crudos)    usuario tdw_etl          └► audit.carga_staging (1 fila por archivo y corrida)
```

- **9 tablas `stg.*`**, una por tipo de archivo (los dos snapshots de contrapartes van a la misma tabla).
  Cada fila lleva su linaje: `_row_id`, `_carga_id`, `_source_file`, `_source_line`, `_loaded_at`.
- **Todo NVARCHAR, sin claves de negocio**: staging es el extracto crudo. Si `amount` fuera `DECIMAL`,
  la fila `1.234.567,89` o la fecha `2026-02-30` haría fallar la carga y el error nunca llegaría a los
  controles de la Fase 5; si hubiera una clave única, los duplicados tampoco. La conversión se hace
  después con `TRY_CONVERT`.
- **Idempotente por archivo**: si el sha256 y las filas coinciden con la última carga, se omite; si el
  archivo cambió (o alguien borró filas de staging), se borra y se recarga ese archivo en una transacción.
  Por eso se puede cargar mes a mes (`--mes 2026-03`) o todo junto, N veces, sin duplicar.
- **Controles antes de insertar**: el encabezado del CSV tiene que coincidir con la tabla y ningún valor
  puede exceder el largo de su columna. Si falla, el archivo queda en `ERROR` en la bitácora (con columna
  y línea) y la versión anterior en staging queda intacta.
- **`fast_executemany`** con `setinputsizes` explícito: escala 1 (76 archivos, ~19.500 filas) carga en ~1 s.
- **Mínimo privilegio**: `rol_etl` tiene `SELECT/INSERT/DELETE` en `stg` y `SELECT/INSERT` en `audit`
  (más `UPDATE` solo en la bitácora). No puede crear ni borrar tablas, truncar, editar staging ni borrar
  la bitácora: los tests lo verifican por código de error.
- **Base de test aparte**: el nombre de la base es una variable SQLCMD (`$(DB_NAME)`), así los tests
  despliegan `TesoreriaDW_test` con los mismos scripts y nunca tocan la base de trabajo.

Verificado: 17 tests de integración (copia fiel fila por fila contra los CSV, cada uno de los 174 errores
inyectados presente en staging por archivo y línea, re-ejecución sin duplicados, archivo corregido,
filas borradas, encabezado inválido, valor demasiado largo, permisos), y reconstrucción completa desde
cero (contenedor y volumen borrados): staging queda idéntico.

## Fase 3: modelo dimensional

Esquema estrella en `dw` (detalle, diagrama Mermaid y matriz de bus en [docs/modelo.md](modelo.md)):

| Dimensiones | Hechos | Tipo | Grano (una fila por...) |
|---|---|---|---|
| `dim_fecha` (AAAAMMDD, 2019–2027) | `fact_facturas` | transacción | factura AP/AR |
| `dim_moneda` | `fact_pagos` | transacción | pago ejecutado |
| `dim_contraparte` (**SCD2**) | `fact_cobranzas` | transacción | cobranza recibida |
| `dim_banco_cuenta` | `fact_movimientos_bancarios` | transacción | línea del extracto (monto con signo) |
| `dim_tipo_movimiento` | `fact_saldo_bancario_mensual` | snapshot periódico | cuenta × mes |
| | `fact_tipo_cambio` | snapshot periódico | moneda × día hábil |
| | `fact_conciliacion` | **snapshot acumulativo** | partida de conciliación (libro, banco o ambos) |

Decisiones principales:
- **SCD2 en contrapartes** (riesgo, plazo, segmento, estado) con `vigente_desde/hasta`, hashes persistidos para
  detectar cambios e **índice único filtrado** que garantiza una sola versión vigente.
- **`fact_conciliacion` con grano "partida"**, como la planilla de conciliación bancaria: conciliadas, con
  diferencia, pendientes en banco y pendientes en libros. Los CHECK impiden estados incoherentes (por ejemplo,
  "conciliada" sin línea del banco) y los únicos filtrados impiden que una línea concilie dos pagos.
- **Integridad en la base, no solo en el ETL**: 30 FK verificadas, 25 CHECK de negocio (montos, fechas,
  saldo que cuadra) y miembros `-1`/`-2` en lugar de NULL.
- `DECIMAL(19,2)` + TC + monto en USD en cada hecho; `dim_fecha` generada con `GENERATE_SERIES` (SQL Server 2022),
  sin depender del idioma ni de `SET DATEFIRST`.

Verificado: 56 tests (estructura, calendario, datos estáticos y 27 reglas probadas con **control positivo**:
la fila válida entra y la misma fila con un campo roto falla con el código esperado). Contraprueba: al sacar dos
reglas del DDL fallaron exactamente sus dos tests. Despliegue completo dos veces seguidas sin errores.

## Fase 4: ETL en T-SQL

```
stg.* ──► dw.usp_run_etl ──► usp_load_dim_banco_cuenta     (MERGE, SCD1)
           (orquestador)  ├► usp_load_dim_contraparte      (SCD2, snapshots en orden)
                          ├► usp_load_fact_tipo_cambio
                          ├► usp_load_fact_facturas
                          ├► usp_load_fact_pagos / _cobranzas
                          ├► usp_load_fact_movimientos_bancarios
                          ├► usp_load_fact_saldo_bancario_mensual
                          └► usp_load_fact_conciliacion    (alta de partidas; el matching es la Fase 6)
                 cada paso ──► audit.etl_log (leídas / insertadas / actualizadas / descartadas + motivo / error)
```

| Paso | Leídas | Insertadas | Descartadas (motivo) | Duplicadas |
|---|---:|---:|---|---:|
| dim_contraparte | 245 | 142 (125 + 17 versiones SCD2) | — | — |
| fact_facturas | 6.008 | 5.980 | 28 (monto con formato `1.234,56`, negativo, sin vencimiento, vence antes de emitirse) | — |
| fact_pagos | 2.795 | 2.769 | 16 (fecha `2026-02-30`, monto negativo, moneda `US$`) | 10 |
| fact_cobranzas | 2.577 | 2.561 | 10 (sin moneda, monto negativo) | 6 |
| fact_movimientos_bancarios | 6.440 | 6.424 | 6 (sin importe, fecha inválida) | 10 (reenvíos del banco) |
| fact_conciliacion | — | 10.679 partidas | — | — |

Escala 1, carga completa: ~1,8 s. Lo descartado coincide **exactamente** con los errores inyectados que violan
reglas del DW (lo verifica un test). El resto de los errores entra al DW: los ataja la Fase 5.

**Decisiones:**
- **MERGE vs. INSERT/UPDATE explícito: los dos, cada uno donde conviene.** `MERGE ... WITH (HOLDLOCK)` en
  `dim_banco_cuenta` (upsert simple, `OUTPUT $action` da los conteos). UPDATE + INSERT explícitos en el SCD2 y en
  los hechos: el SCD2 tiene tres operaciones (corregir tipo 1, cerrar versión, abrir versión) que en un MERGE quedan
  enredadas, y separadas cada paso se cuenta y se depura solo; además MERGE tuvo bugs conocidos y sin `HOLDLOCK`
  tiene problemas de concurrencia.
- **Detección de cambios con `WHERE EXISTS (SELECT origen EXCEPT SELECT destino)`**: trata NULL = NULL (con `<>`
  columna por columna un NULL esconde el cambio). Sin cambios no se escribe nada: re-ejecutar es un no-op.
- **Transacción por paso + `TRY/CATCH` + `XACT_ABORT ON`**: un error revierte el paso entero, queda en
  `audit.etl_log` con número y línea (el log se escribe fuera de la transacción, así no se revierte con ella) y el
  orquestador frena (fail fast). Como todo es idempotente, volver a correr retoma sin duplicar.
- **Incremental por fecha de negocio**: cada hecho procesa desde su marca de agua menos 7 días (líneas que el banco
  informa tarde). Las fechas inválidas usan el mes del archivo para caer en alguna ventana y quedar contadas.
  **Las fechas futuras no mueven la marca de agua**: un pago fechado 2027 por error la empujaba y la corrida
  siguiente se salteaba fines de octubre (lo encontró la primera prueba del incremental).
- **Lookup punto en el tiempo** de la contraparte SCD2 y **último tipo de cambio disponible** (`OUTER APPLY ... TOP 1`).
- **Mínimo privilegio**: `rol_etl` solo tiene `EXECUTE` sobre `dw.usp_run_etl`; los demás procedimientos y tablas los usa
  por *ownership chaining*. Hallazgo: con ese permiso, `OBJECT_NAME(@@PROCID)` devuelve NULL (el usuario no "ve" la
  metadata del procedimiento), así que cada procedimiento declara su nombre como texto fijo.

**Verificado** (23 tests nuevos, 146 en total, en cualquier orden de módulos): conteos que cuadran por paso, lo
descartado = lo esperado según el manifiesto, re-ejecución sin cambios (incremental y completa), **carga por partes
(hasta marzo + incremental) idéntica a la carga completa**, cada hecho apunta a la versión SCD2 vigente en su fecha,
conversión a USD con el último TC, error a mitad de paso (rollback + log + fail fast) y permisos. Además: dos
reconstrucciones completas desde cero (contenedor, datos, staging y DW) dan exactamente el mismo DW.

## Fase 5: calidad de datos

Detalle en [docs/calidad-de-datos.md](calidad-de-datos.md).

- **51 reglas** en `audit.dq_reglas`: 43 sobre staging antes de cargar (completitud, unicidad, formato, rango,
  integridad referencial lógica, consistencia entre fuentes) y 8 totales de control staging vs. DW después de cargar.
- Resultados por regla y ejecución en **`audit.dq_resultados`** (regla, tabla, filas evaluadas, filas con error,
  %, severidad, fecha) y detalle por fila en `audit.dq_errores` (archivo, línea, clave, valor observado).
- **ERROR → cuarentena** (`audit.cuarentena_*`, copia fiel de la fila, nada se borra; al corregir y recargar queda
  `LIBERADA`). **ADVERTENCIA → entra y se informa** (maestro de contrapartes, partidas sin contrapartida).
- El ETL excluye lo que está en cuarentena y **retira del DW** lo que ya había entrado; descartes sin explicar: **0**.

| Resultado (escala 1) | |
|---|---|
| Errores inyectados detectados (recall) | **174 / 174 = 100%** |
| Precisión a nivel fila | 97,8% (los 4 sobrantes son las parejas de CUIT duplicado, explicados) |
| En cuarentena | 141 filas (36 facturas, 59 pagos, 26 cobranzas, 16 líneas de extracto, 4 cotizaciones) |
| Totales de control | filas y montos cuadran; **6 cuentas-mes** donde el saldo del banco no se explica (= las líneas en cuarentena) |
| Tiempo de validación | ~1,7 s sobre 19.362 filas |

Hallazgos del camino: los primeros 5 falsos positivos venían de **culpar a un comprobante por el error de otro**
(un pago con fecha futura dejaba "sin match" a su línea del banco; una línea con importe en blanco dejaba "sin
extracto" a su cobranza) y se corrigieron con la regla de no marcar sin evidencia. Y las `#tablas` temporales
necesitan `COLLATE DATABASE_DEFAULT` porque toman la collation de `tempdb`, no la de la base.

**Verificado**: 18 tests nuevos (9 × 2 datasets), 164 en total, en cualquier orden de módulos.

## Fase 6: conciliación y análisis

**Conciliación automática** (`dw.usp_conciliar`, corre dentro del ETL): para cada pago/cobranza busca su movimiento
en el extracto, en la misma cuenta, con el mismo signo, entre el día del ERP y 7 días después, en tres pasadas por
prioridad: **referencia completa**, **referencia parcial** (últimos 5 caracteres) y **monto + fecha**. Tolerancia de
USD 50 en cuentas en dólares (comisiones SWIFT descontadas). El emparejamiento es **1 a 1 por "mejor mutuo"**
iterativo (`ROW_NUMBER` desde los dos lados), así dos pagos iguales se reparten las dos líneas del banco por cercanía.

| Conciliación (escala 1) | |
|---|---|
| Pares conciliados | 5.265 (4.745 por referencia, 520 por monto y fecha) |
| Contra la conciliación "perfecta" del generador | **precisión 100%, recall 100%** |
| Con diferencia (comisión descontada) | 138, exactamente las que el generador marcó como ruido |
| Pendientes en banco / en libros | 22 / 84: lo que no tiene pareja en el DW (en tránsito, rechazado, sin registrar o en cuarentena) |

**Consultas** (`sql/06_queries/`, cada una con el comentario de negocio de qué responde):

| Archivo | Responde | Técnicas |
|---|---|---|
| `01_conciliacion.sql` | % conciliado por cuenta, calidad del matching, partidas pendientes más viejas | agregación condicional, `SUM() OVER`, `ROW_NUMBER` |
| `02_aging_cobranzas.sql` | cartera a cobrar por tramo de vencimiento, por cliente y por moneda, **revaluada al TC de cierre** | CTE encadenadas, `CROSS APPLY` (último TC), **`PIVOT`**, acumulado |
| `03_flujo_caja_diario.sql` | ingresos, egresos y **saldo acumulado diario por moneda** (todos los días, con o sin movimientos) | calendario `CROSS JOIN`, `SUM() OVER (ROWS UNBOUNDED PRECEDING)`, `LAG`, promedio móvil |
| `04_top_contrapartes.sql` | top 10 de pagos y cobranzas, concentración por cuartil, Pareto, últimos 3 movimientos | `RANK`, **`NTILE(4)`**, `SUM() OVER`, `CROSS APPLY TOP 3` |
| `05_anomalias.sql` | pagos atípicos (> 5× la mediana), posibles dobles pagos, facturas pagadas de más, clientes que se atrasan cada vez más | `PERCENTILE_CONT` como window function, `LAG`, días hábiles con el calendario |
| `06_pivot_dinamico_seguro.sql` | reporte contraparte × mes de pagos, cobranzas o facturas | **SQL dinámico seguro**: lista blanca + `QUOTENAME` + parámetros de `sp_executesql` |
| `07_evolucion_cartera_recursiva.sql` | evolución mensual de la cartera, % vencida > 30 días y **DSO** | **CTE recursiva** (serie de cierres de mes, `MAXRECURSION`), `CROSS APPLY`, `LAG` |

Verificado (20 tests): conciliación 100%/100% y pendientes explicados uno por uno; el aging cuadra con un cálculo
independiente en Python; el **saldo de cierre del flujo de caja difiere del saldo del banco exactamente en la plata de
las líneas en cuarentena**; los 5 pagos atípicos y los 3 dobles pagos plantados se detectan sin falsos positivos; el
PIVOT dinámico suma lo mismo que el hecho y **rechaza intentos de inyección** (`'PAGOS; DROP TABLE ...'`,
`N'ARS'' OR 1=1 --'`); la serie recursiva coincide con el aging al cierre.

## Fase 7: performance

Medido con `python/medir_performance.py` sobre `TesoreriaDW_perf` (escala 20: 113 mil movimientos, 120 mil facturas),
mediana de 5 corridas con `SET STATISTICS IO, TIME ON` y planes reales guardados en `sql/07_performance/planes/`.
Tabla completa y operadores del plan en [sql/07_performance/resultados.md](../sql/07_performance/resultados.md).

| Consulta | Cambio | Lecturas lógicas antes → después |
|---|---|---|
| Q1 flujo de caja diario | columnstore no agrupado (batch mode) | 4.087 → 145 (**28x**) |
| Q2 evolución de cartera | índice NC con INCLUDE + filtrado **solo** (1,1x) y **reescritura** con suma acumulada + `MAXDOP 1` | 1.302.345 → 3.638 (**358x**) |
| Q3 pendientes de conciliación | índice filtrado (y `IN` en vez de `LIKE` para que el filtro se use) | 6.553 → 609 (**11x**) |

Hallazgos: el índice solo no arregla una subconsulta correlacionada (Q2); una reescritura con unión por desigualdad fue
**peor** (spool, 20 s de CPU) y se descartó midiendo. A escala 20 la validación de calidad tardaba 151 s y perdía
detecciones (reglas de "existencia"): las reglas ERP vs. banco pasaron a usar la conciliación 1 a 1 → **5,7 s y recall
174/174 sin falsos positivos**. La conciliación con orden fecha-antes-que-diferencia da 100% en 107.701 pares.

## Fase 8: seguridad

Detalle y modelo de amenazas en [docs/seguridad.md](seguridad.md).

| Usuario (`EXECUTE AS`) | Monedas que ve (RLS) | CBU | Email | Staging | Escribir |
|---|---|---|---|---|---|
| `analista_ar` (`rol_lectura_analistas`) | ARS, USD | `XXXX...7809` | `cXXX@XXXX.com` | denegado | denegado |
| `analista_br` (`rol_lectura_analistas`) | BRL | enmascarado | enmascarado | denegado | denegado |
| `auditor_demo` (`rol_auditoria`) | todas | real | real | lee | denegado |
| `tdw_etl` (`rol_etl`) | todas | real | real | escribe | solo vía `usp_run_etl` |

- **Roles con GRANT/DENY a nivel de schema** y DENY explícito sobre staging, auditoría y seguridad para analistas.
- **RLS** con funciones inline `SCHEMABINDING` y una política de filtro sobre los 6 hechos con moneda y las cuentas.
- **Dynamic Data Masking** de CBU/CLABE, email y CUIT; `UNMASK` para auditoría y el ETL (sin él, la carga copiaba
  valores enmascarados a tablas temporales y los cruces fallaban). Las huellas SCD se niegan por columna (DENY 230).
- Login `tdw_powerbi` de solo lectura para la Fase 9; claves en `.env`.

Verificado: 31 tests de seguridad (216 en total) y la prueba `04_pruebas_permisos.sql` en cada despliegue.

## Fase 9: capa de consumo (Power BI)

12 vistas en el schema `rpt` (`sql/08_reporting/01_vistas_rpt.sql`):
- **estrella** para Power BI: `dim_fecha`, `dim_moneda`, `dim_cuenta`, `dim_contraparte`, `fact_movimientos`, `fact_pagos`,
  `fact_cobranzas`, `fact_facturas`, `fact_conciliacion`, con nombres de negocio y sin claves técnicas, hashes ni datos sensibles;
- **calculadas**: `v_flujo_caja_diario` (saldo acumulado por moneda, todos los días), `v_aging_cobranzas` (al último
  cierre, revaluado al TC de ese día) y `v_evolucion_cartera` (cartera, vencida > 30 días y DSO por mes).

La seguridad viaja sola: **RLS y masking se aplican a través de las vistas**. El login `tdw_powerbi` ve todas las monedas
con CBU enmascarado; un analista de Brasil ve solo BRL en el mismo tablero.

Guía paso a paso del tablero (conexión desde Windows al SQL Server del Mac, modelo, medidas DAX y 3 páginas: flujo
de caja, aging y conciliación) en [docs/powerbi.md](powerbi.md). La guía de capturas está en [docs/img/README.md](img/README.md).

Verificado: 18 tests. Cada vista responde para el login de Power BI, no expone datos sensibles, respeta RLS y **da los
mismos números que las consultas de análisis de la Fase 6**. **No verificado:** el `.pbix` en sí (Power BI Desktop
requiere Windows); las capturas quedan para hacer con la guía.
