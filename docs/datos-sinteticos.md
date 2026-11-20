# Datos sintéticos (Fase 1)

`python/generar_datos.py` simula **el ERP y los bancos** de una fintech ficticia de pagos
transfronterizos: le pagamos a proveedores y corresponsales (payouts), cobramos a clientes
corporativos, y operamos cuentas en ARS, USD, BRL, MXN y COP en 6 bancos ficticios.

- Período: **01/11/2025 al 31/10/2026** (corte de extracción: 31/10/2026). Días hábiles = lunes a viernes, sin feriados.
- `seed=42` fija → mismos archivos byte a byte en cada corrida (lo verifica un test).
- `--escala N` multiplica el volumen (la Fase 7 usa más volumen). Los errores inyectados son siempre los mismos 174.
- Nada es real: bancos con "(ficticio)" y BIC terminados en `ZZ`, emails con dominio `.example` (RFC 2606), CBU/CLABE con código de banco 99x.

## Archivos

Como le llegan a un tesorero: maestros por un lado, y un "paquete" de extractos y listados por mes.

| Archivo | Qué es (analogía SAP/tesorería) | Filas (escala 1) |
|---|---|---|
| `maestros/banks.csv` | Bancos (tabla de bancos propios, FI12) | 6 |
| `maestros/bank_accounts.csv` | Cuentas bancarias propias: CBU con dígitos verificadores reales, CLABE, etc. | 9 |
| `maestros/counterparties_2025-11-01.csv` y `_2026-05-01.csv` | Maestro de proveedores/clientes (XK03/XD03), **dos fotos** para el SCD2 | 120 + 125 |
| `AAAA-MM/invoices.csv` | Facturas AP (de proveedores) y AR (nuestras a clientes): partidas abiertas en FBL1N/FBL5N | ~6.000 |
| `AAAA-MM/payments.csv` | Pagos emitidos (corrida F110) | ~2.800 |
| `AAAA-MM/collections.csv` | Cobranzas recibidas (F-28) | ~2.600 |
| `AAAA-MM/bank_statements.csv` | Extracto bancario (MT940 / Interbanking), importe con signo | ~6.400 |
| `AAAA-MM/bank_balances.csv` | Saldo inicial/final del extracto por cuenta y mes (control de totales) | 108 |
| `AAAA-MM/fx_rates.csv` | Tipo de cambio diario (unidades de moneda por 1 USD) | ~1.300 |
| `_verdad/errores_inyectados.json` | **Lista exacta de errores** + ruido + anomalías + cambios SCD2 | 174 errores |
| `_verdad/conciliacion_esperada.csv` | Qué línea de extracto corresponde a qué pago/cobranza (la conciliación "perfecta") | ~5.300 |

`_verdad/` **no es una fuente**: es la respuesta del examen. La carga a staging (Fase 2) la ignora.

## Realismo de tesorería (no son errores)

Esto hace que la conciliación de la Fase 6 no sea un simple JOIN:

- **Desfase banco vs. ERP**: la línea del banco cae 0 a 3 días hábiles después (60/30/8/2 %).
- **Referencias imperfectas**: la descripción del extracto trae la referencia completa (70 %), parcial (20 %) o ninguna (10 %).
- **Comisiones SWIFT**: a veces vienen en una línea aparte (`FEE`) y a veces el banco las **descuenta del monto** (142 casos). Para eso hace falta tolerancia en el matching.
- **Impuesto a los débitos y créditos (Ley 25.413)**: 0,6 % diario en cuentas ARS (`TAX`).
- **Compra/venta de USD** para fondear los payouts en moneda local (`FX`), y comisión de mantenimiento mensual.
- **Partidas en tránsito**: pagos y cobranzas de fines de octubre que el banco registra después del corte.
- **Facturas abiertas al corte** (17 %): disputas, incobrables y clientes morosos alimentan el aging.
- **Perfiles de cobro**: clientes puntuales, demorados (5 a 45 días) y morosos (30 a 120 días).
- **Concentración**: el top 10 de contrapartes tiene ~40 % de las facturas (distribución de Pareto).
- **Tipo de cambio**: random walk diario; el ARS tiene deriva devaluatoria (1.450 → 1.974 por USD en el año, +36 %).
- Los saldos iniciales se calculan para que ninguna cuenta quede en descubierto.

## Errores inyectados (174, uno por fila)

| Categoría | Tipos | Cant. |
|---|---|---|
| duplicados | pago/cobranza repetidos (`DUP_EXACTO`), factura cargada dos veces con otro id (`DUP_LOGICO`), banco reenvía la línea el mes siguiente (`DUP_REENVIO`), dos contrapartes con el mismo CUIT/CNPJ (`TAX_ID_DUPLICADO`) | 36 |
| nulos | contraparte, monto, vencimiento, moneda, importe del extracto, cotización, tax_id | 28 |
| fechas_imposibles | fecha inexistente (`2026-02-30`), posterior al corte, vencimiento antes de la emisión | 19 |
| montos_negativos | pagos, cobranzas y facturas con signo negativo | 17 |
| monedas_inconsistentes | moneda distinta a la de la factura/cuenta, código no ISO (`US$`, `DOLARES`) | 17 |
| pagos_sin_factura | pago o cobranza que apunta a una factura inexistente | 15 |
| extractos_sin_match | movimientos del banco que nadie cargó en el ERP | 15 |
| formato_invalido | monto con formato regional (`1.234.567,89`), email sin `@` | 9 |
| pagos_sin_extracto | pago en el ERP que el banco nunca debitó | 8 |
| integridad_referencial | pago a una contraparte que no está en el maestro | 5 |
| completitud | día hábil sin cotización | 3 |
| valores_fuera_de_rango | cotización 10x (error de tipeo de la coma) | 2 |

Cada error del JSON trae `tabla`, `clave` (ej.: `payment_id`), `campo`, `valor_original`,
`valor_inyectado` y `ubicaciones` (archivo + número de línea). Ejemplo:

```json
{"id": "E0166", "categoria": "duplicados", "tipo": "TAX_ID_DUPLICADO", "tabla": "counterparties",
 "clave": {"counterparty_id": "CP0066"}, "campo": "tax_id",
 "valor_original": "78-4664338", "valor_inyectado": "20-2947320",
 "ubicaciones": [{"archivo": "maestros/counterparties_2025-11-01.csv", "linea": 67}, ...]}
```

## Anomalías de negocio (para la Fase 6, no son errores de calidad)

Los datos son válidos, pero un tesorero los querría ver:

- **5 pagos atípicos**: factura y pago 8 a 12 veces más grandes que lo habitual del proveedor.
- **3 posibles dobles pagos**: misma factura pagada dos veces, 1 o 2 días hábiles después, con el mismo monto.

## Cómo se garantiza que la lista de errores es exacta

`python/tests/test_generar_datos.py` (50 tests, 4 combinaciones seed/escala) verifica que:

1. cada error está en el archivo y la línea que dice, con el valor que dice;
2. **toda fila que no está en el manifiesto cumple todas las reglas** (montos positivos, fechas
   válidas, la factura existe, monedas consistentes, nunca se paga de más, etc.);
3. las únicas transferencias del extracto sin pago/cobranza son las inyectadas;
4. saldo inicial + movimientos = saldo final, mes a mes y cuenta por cuenta;
5. los cambios SCD2 se ven en el segundo snapshot;
6. dos corridas dan archivos idénticos, y re-ejecutar no deja meses "viejos" ni borra archivos ajenos.

Con (1) y (2), en la Fase 5 se puede medir con precisión: lo que un control marque fuera del
manifiesto es falso positivo, y lo del manifiesto que no marque es falso negativo.

## Decisiones

- **Archivos mensuales** en vez de uno anual: así llegan los extractos en la vida real, y habilita
  la carga incremental de la Fase 4. También permite el duplicado típico "el banco reenvía la línea en el extracto siguiente".
- **Columnas en inglés en las fuentes** (simulan exportaciones de sistemas); el DW de la Fase 3 va en español.
- **Pagos referencian `invoice_id`** (el número de documento interno del ERP, como el BELNR de SAP). El
  `invoice_number` del proveedor es único por proveedor, no globalmente: la clave natural es (contraparte, número).
- **El extracto trae `account_number`, no el id interno**: el ETL tiene que mapearlo a la cuenta, como cuando se importa un MT940.
- **Errores en dos momentos**: los que cambian *lo que pasó en el banco* (pago rechazado, movimiento no registrado) se
  inyectan antes de calcular saldos; los que cambian *cómo viene escrito el dato* (nulos, formatos, duplicados) se inyectan después.
  Por eso los saldos del banco siguen siendo la verdad y sirven como total de control.
- **Limitaciones conocidas**: no hay feriados, no hay notas de crédito, y el impuesto Ley 25.413 se aplica como 0,6 % plano
  (sin la alícuota reducida ni el cómputo a cuenta de Ganancias).
