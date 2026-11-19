# Calidad de datos (Fase 5)

> Analogía: es el **manual de controles** del cierre de tesorería. Antes de contabilizar, cada
> comprobante pasa por una lista de controles; lo que falla va a la **bandeja de observados**
> (cuarentena) con el motivo, y no se contabiliza hasta que el área lo corrija. Después del cierre,
> la **cuadratura**: lo que vino en los archivos tiene que estar en el libro, y el saldo del banco
> tiene que explicarse con los movimientos registrados.

## Cómo funciona

```
stg.* ──► audit.usp_dq_validar_staging ──► audit.dq_resultados  (1 fila por regla y ejecución)
             (43 reglas PRE_CARGA)       ├► audit.dq_errores     (detalle: archivo, línea, clave, valor)
                                         └► audit.cuarentena_*   (filas con reglas ERROR, copia fiel)
      ──► dw.usp_load_*  (excluyen lo que está en cuarentena; retiran del DW lo que ya había entrado)
      ──► audit.usp_dq_controles_post_carga (8 totales de control staging vs. DW)
```

Todo corre dentro de `dw.usp_run_etl` (parámetro `@validar_calidad = 1` por defecto).

| Severidad | Qué pasa con la fila | Ejemplos |
|---|---|---|
| **ERROR** | Va a **cuarentena** y no entra al DW | monto negativo, fecha `2026-02-30`, pago sin factura, duplicado |
| **ADVERTENCIA** | Entra al DW y se **informa** | email inválido de un proveedor, pago sin débito en el extracto (lo resuelve la conciliación), día sin cotización |

**La cuarentena no borra nada.** Hay una tabla por fuente (`audit.cuarentena_payments`, etc.) con las mismas
columnas que staging, la fila tal como vino, las reglas que violó y su estado:

- `EN_CUARENTENA`: sigue fallando.
- `LIBERADA`: el área corrigió el archivo, se recargó y la fila ya no falla. Queda en el historial con su fecha de liberación.

Si una fila que **ya estaba en el DW** pasa a cuarentena (porque se agregó una regla o porque cambió el archivo),
la carga la **retira** del DW y lo registra en `audit.etl_log.filas_eliminadas`. Sigue estando en la cuarentena.

## Reglas (51)

### Antes de cargar (sobre staging)

| Tabla | Completitud | Unicidad | Formato | Rango | Integridad referencial | Consistencia entre fuentes |
|---|---|---|---|---|---|---|
| invoices | id, monto, vencimiento | id repetido; **misma factura del proveedor con otro id** | monto no numérico (`1.234,56`), fecha, moneda | monto ≤ 0, vence antes de emitirse | contraparte | — |
| payments | contraparte | pago repetido | fecha, moneda no ISO | monto ≤ 0, **fecha posterior al corte** | factura, contraparte, cuenta | moneda ≠ factura/cuenta; *pago sin débito en el extracto* |
| collections | moneda | cobranza repetida | fecha, moneda | monto ≤ 0 | factura, contraparte | moneda ≠ factura/cuenta; *cobranza sin crédito en el extracto* |
| bank_statements | importe | **línea reenviada por el banco** | fecha | — | cuenta | moneda ≠ cuenta; *transferencia sin pago/cobranza en el ERP* |
| fx_rates | cotización vacía; *día hábil sin cotización* | — | — | **salto > 50% contra el día anterior y el siguiente** | — | — |
| counterparties | *tax_id* | *mismo CUIT/CNPJ en dos contrapartes* | *email* | — | — | — |

En *cursiva*, las reglas de severidad ADVERTENCIA. El catálogo completo está en `audit.dq_reglas`
(`sql/04_quality/02_dq_catalogo_reglas.sql`).

### Después de cargar (totales de control)

| Regla | Control |
|---|---|
| `CTL_FILAS_*` (4) | filas válidas de staging (clave única, sin cuarentena) = filas en el DW |
| `CTL_MONTO_*` (3) | suma por moneda de staging válido = suma en el DW |
| `CTL_SALDO_EXTRACTO` | saldo inicial + movimientos cargados = saldo final que informa el banco (cuenta × mes) |
| `CTL_SALDO_CONTINUIDAD` | saldo final de un mes = saldo inicial del siguiente |

## Resultados (escala 1, seed 42)

| | |
|---|---|
| Filas evaluadas | 19.362 de staging |
| Detecciones | 185: 141 ERROR (a cuarentena) y 44 ADVERTENCIA |
| En cuarentena | 36 facturas, 59 pagos, 26 cobranzas, 16 líneas de extracto, 4 cotizaciones |
| Descartes del ETL sin explicar | **0** (antes de la Fase 5: 62 descartes y 26 duplicados que el ETL resolvía solo, sin dejar regla ni detalle) |
| Totales de control | filas y montos **cuadran** en las 4 tablas; continuidad de saldos OK |
| `CTL_SALDO_EXTRACTO` | **6 cuentas-mes no cuadran**: son exactamente las que tienen una línea del banco en cuarentena (importe en blanco o fecha rota). El banco movió esa plata, pero el DW no la tiene: es lo que el tesorero tiene que ir a mirar |

### Contra los errores inyectados (la "planilla de control" de la Fase 1)

| Categoría | Detectados |
|---|---|
| duplicados | 36 / 36 |
| nulos | 28 / 28 |
| fechas imposibles | 19 / 19 |
| montos negativos | 17 / 17 |
| monedas inconsistentes | 17 / 17 |
| pagos sin factura | 15 / 15 |
| extractos sin match | 15 / 15 |
| formato inválido | 9 / 9 |
| pagos sin extracto | 8 / 8 |
| integridad referencial | 5 / 5 |
| completitud (cotizaciones faltantes) | 3 / 3 |
| valores fuera de rango | 2 / 2 |
| **Total (recall)** | **174 / 174 = 100%** |

**Precisión a nivel fila: 97,8%** (4 falsos positivos sobre 182 detecciones). Los 4 están explicados: la regla de
CUIT duplicado marca a las **dos** contrapartes que comparten el número (la inyectada y su "pareja"), en los dos
snapshots, porque sin revisar los papeles no se puede saber cuál es la correcta. El test exige exactamente esa explicación.

## Decisiones

- **Reglas set-based** (un `INSERT ... SELECT ... WHERE <viola la regla>` por regla), sin cursores fila por fila.
- **El maestro de contrapartes no va a cuarentena**: un email inválido no impide registrar un pago; poner en
  cuarentena al proveedor dejaría huérfanos todos sus hechos. Sus reglas son ADVERTENCIA.
- **Consistencia ERP ↔ banco**: misma cuenta, mismo importe (tolerancia de USD 50 en cuentas en dólares por
  comisiones SWIFT descontadas), dentro de los 7 días. Se compara en valor absoluto y sin mirar la moneda: si el ERP
  tiene el signo o la moneda mal, eso lo marca otra regla; acá solo importa si el dinero se movió.
- **Período de tránsito**: los pagos y cobranzas de los últimos 5 días antes del corte no se evalúan contra el
  extracto (el banco los puede imputar en el extracto siguiente).
- **No culpar a un comprobante por el error de otro**: si la línea del banco que le corresponde a una cobranza está
  rota (importe en blanco), la cobranza no se marca "sin extracto"; la línea ya va a cuarentena por su propia regla.
  Del mismo modo, una fecha del ERP posterior al corte se considera no confiable y el match se hace por cuenta + importe.
  Las dos decisiones salieron de investigar 5 falsos positivos de la primera versión.
- **Cotización fuera de rango = salto contra los DOS vecinos** (`LAG`/`LEAD`): una devaluación real se mueve contra
  uno solo de los dos, un error de tipeo contra ambos.
- **Cuarentena con SQL dinámico solo en el despliegue**: las tablas se generan leyendo la estructura de staging
  (`sys.columns` + `QUOTENAME` + `sp_executesql`), así nunca quedan desalineadas. En tiempo de ejecución el SQL es
  estático: el SQL dinámico corta el *ownership chaining* y obligaría a darle al usuario del ETL permisos directos.
- **Tablas temporales con `COLLATE DATABASE_DEFAULT`**: las `#tablas` toman la collation de `tempdb` (la del
  servidor) y los JOIN contra la base fallaban con "collation conflict".

## Limitaciones conocidas

- Un pago rechazado por el banco en los últimos 5 días antes del corte no se puede distinguir de uno en tránsito:
  la regla no lo marca hasta el corte siguiente.
- Si una línea del banco rota cae en la misma cuenta y semana que un pago que realmente no se debitó, ese pago no se
  marca (no hay evidencia suficiente). Con los datos de prueba no pasa, pero es posible.
- Las reglas de consistencia buscan *existencia* de contrapartida, no un emparejamiento 1 a 1: el emparejamiento
  exacto (y la detección de un pago que "usa" la línea de otro) es la conciliación de la Fase 6.

## Cómo se verifica

`python/tests/test_calidad.py` (9 tests × 2 datasets: seed 42 escala 0,3 y seed 7 escala 0,5):

- **recall 100%**: cada error del manifiesto lo detecta la regla que corresponde, en su archivo y línea;
- **falsos positivos explicados**: lo único que sobra son las parejas de CUIT duplicado;
- un resultado por regla activa, con los conteos coherentes con el detalle;
- la cuarentena tiene exactamente las filas con reglas ERROR (y es copia fiel de staging);
- el ETL no descarta nada sin explicar y nada en cuarentena llega al DW;
- totales de control: cuadran filas y montos; el saldo no cuadra exactamente en las cuentas-mes esperadas;
- re-ejecutar no cambia nada;
- **corregir y recargar**: se corrige un pago con monto negativo en el CSV, se recarga, la fila queda `LIBERADA`,
  el pago entra al DW con el monto correcto y los demás errores del archivo siguen en cuarentena.
