# Tablero de tesorería en Power BI (Fase 9)

Guía paso a paso para armar un tablero de **flujo de caja, aging y conciliación** sobre las vistas `rpt.*`.
Las vistas están en `sql/08_reporting/01_vistas_rpt.sql`.

## 0. Antes de empezar: Power BI Desktop no existe para Mac

Power BI Desktop es solo para Windows. Hay tres caminos:

| Opción | Cómo | Comentario |
|---|---|---|
| **A. Máquina virtual Windows en el Mac** (Parallels, UTM o VMware Fusion) | Windows 11 ARM ejecuta Power BI Desktop (x64 emulado) | La más práctica si no hay otra PC |
| **B. Una PC con Windows en la misma red** | Power BI se conecta al SQL Server del Mac por IP | Hay que dejar el puerto 1433 accesible en la red local |
| **C. Sin Windows** | Las capturas se reemplazan por gráficos de VS Code (extensión `mssql`) o Excel | El repo igual muestra las vistas y las consultas |

En las opciones A y B, Power BI se conecta al Mac **por IP**. La IP del Mac se averigua con:

```bash
ipconfig getifaddr en0
```

En una VM de Parallels, el Mac suele verse como `10.211.55.2`. El contenedor publica el puerto 1433 en todas las
interfaces (`docker-compose.yml`), así que alcanza con usar `IP_DEL_MAC,1433`.

## 1. Conectar

1. **Obtener datos → SQL Server**.
2. Servidor: `IP_DEL_MAC,1433` (con coma, no dos puntos). Base de datos: `TesoreriaDW`.
3. Modo: **Importar** (el volumen es chico; con DirectQuery cada clic consultaría la base).
4. Credenciales: pestaña **Base de datos**, usuario `tdw_powerbi` y la clave de `MSSQL_BI_PASSWORD` del `.env`.
   - Es un usuario de **solo lectura** (`rol_lectura_analistas`): ve todas las monedas pero con CBU y CUIT
     enmascarados. Nunca conectar Power BI con `sa`.
5. Si aparece un error de certificado: **Archivo → Opciones → Configuración de origen de datos → Editar permisos** y
   destildar *Cifrar conexiones*. El contenedor usa un certificado autofirmado; en producción no se haría esto.
6. En el navegador, elegir las **12 vistas del schema `rpt`**:
   `dim_fecha`, `dim_moneda`, `dim_cuenta`, `dim_contraparte`, `fact_movimientos`, `fact_pagos`, `fact_cobranzas`,
   `fact_facturas`, `fact_conciliacion`, `v_flujo_caja_diario`, `v_aging_cobranzas`, `v_evolucion_cartera`.

## 2. Transformar (Power Query): dos ajustes

1. `dim_fecha`: filtrar `fecha_key > 0`. Las filas -1 ("Desconocida") y -2 ("Todavía no ocurrió") no tienen fecha, y
   Power BI necesita una tabla de fechas sin vacíos para marcarla como tabla de fechas.
2. Revisar los tipos de las columnas: `fecha`, `cierre`, `vencimiento` y `fecha_corte` como **Fecha**, y los montos como **Número decimal fijo**.

## 3. Modelo (vista de modelo)

Relaciones de **muchos a uno**, con filtro en una sola dirección (de la dimensión al hecho):

| Desde (muchos) | Hacia (uno) |
|---|---|
| `fact_movimientos[fecha_key]`, `fact_pagos[fecha_key]`, `fact_cobranzas[fecha_key]`, `fact_conciliacion[fecha_key]`, `v_flujo_caja_diario[fecha_key]`, `v_evolucion_cartera[fecha_key]` | `dim_fecha[fecha_key]` |
| `fact_facturas[fecha_emision_key]` | `dim_fecha[fecha_key]` (activa) |
| `[moneda_key]` de todas las fact_* y v_* | `dim_moneda[moneda_key]` |
| `[banco_cuenta_key]` de movimientos, pagos, cobranzas y conciliación | `dim_cuenta[banco_cuenta_key]` |
| `[contraparte_key]` de pagos, cobranzas, facturas, conciliación y aging | `dim_contraparte[contraparte_key]` |

- **Marcar `dim_fecha` como tabla de fechas** (columna `fecha`).
- En `v_aging_cobranzas`, columna `tramo` → **Ordenar por columna** → `orden_tramo` (si no, "+90" queda primero).
- En `dim_fecha`, `nombre_mes` → ordenar por `mes`.
- Ocultar las columnas `*_key` en la vista de informe: el usuario no las necesita ver.

## 4. Medidas DAX (crear una tabla vacía "Medidas" para tenerlas juntas)

```dax
Ingresos = SUM ( v_flujo_caja_diario[ingresos] )
Egresos = SUM ( v_flujo_caja_diario[egresos] )
Neto = [Ingresos] - [Egresos]

-- Saldo al último día del período filtrado (el saldo no se suma en el tiempo: se toma el del último día)
Saldo de caja =
VAR ultimo = MAX ( dim_fecha[fecha] )
RETURN CALCULATE ( SUM ( v_flujo_caja_diario[saldo_cierre] ), dim_fecha[fecha] = ultimo )

Cartera USD = SUM ( v_aging_cobranzas[saldo_usd_cierre] )
Cartera vencida USD = CALCULATE ( [Cartera USD], v_aging_cobranzas[dias_vencido] > 0 )
% Cartera vencida = DIVIDE ( [Cartera vencida USD], [Cartera USD] )
DSO (días) = AVERAGE ( v_evolucion_cartera[dso_dias] )

Partidas = COUNTROWS ( fact_conciliacion )
Partidas conciliadas = CALCULATE ( [Partidas], fact_conciliacion[esta_conciliada] = TRUE () )
% Conciliado = DIVIDE ( [Partidas conciliadas], [Partidas] )
Partidas pendientes = [Partidas] - [Partidas conciliadas]
Monto pendiente = CALCULATE ( SUM ( fact_conciliacion[monto_banco] ) + SUM ( fact_conciliacion[monto_libro] ),
                              fact_conciliacion[esta_conciliada] = FALSE () )
```

> Saldos en distintas monedas **no se suman**: en la página de flujo de caja, poné un segmentador de moneda con
> "selección única". Para una vista consolidada, usá los montos en USD (`monto_usd`).

## 5. Páginas del tablero

**Página 1. Flujo de caja**
- Segmentadores: moneda (selección única) y rango de fechas.
- Tarjetas: `Saldo de caja`, `Ingresos`, `Egresos`, `Neto`.
- Gráfico de líneas: `v_flujo_caja_diario[fecha]` × `Saldo de caja` (se ve el "serrucho" de los pagos y las compras de USD).
- Columnas agrupadas: `dim_fecha[anio_mes]` × `Ingresos` y `Egresos`.

**Página 2. Cuentas a cobrar (aging)**
- Tarjetas: `Cartera USD`, `% Cartera vencida`, `DSO (días)` del último cierre.
- Barras: `v_aging_cobranzas[tramo]` × `Cartera USD`.
- Matriz: filas `dim_contraparte[razon_social]`, columnas `tramo`, valores `Cartera USD` (top 15 por total).
- Líneas: `v_evolucion_cartera[cierre]` × `DSO (días)` y `vencida_30_usd`.

**Página 3. Conciliación bancaria**
- Tarjetas: `% Conciliado`, `Partidas pendientes`, `Monto pendiente`.
- Matriz: filas `dim_cuenta[cuenta]`, columnas `fact_conciliacion[estado_descripcion]`, valores `Partidas`.
- Anillo: `metodo_match` (referencia vs. monto y fecha).
- Tabla de pendientes: `partida`, `estado_descripcion`, `dim_fecha[fecha]`, `monto_libro`, `monto_banco`, filtrada a `esta_conciliada = Falso`, ordenada por fecha.

## 6. Comprobar la seguridad (opcional, para la demo)

La seguridad la aplica la base, no Power BI. Para mostrarlo, en VS Code (extensión `mssql`) o `sqlcmd`, corré
`sql/05_security/04_pruebas_permisos.sql`: con `EXECUTE AS` se ve que `analista_br` solo ve BRL y que los CBU salen
enmascarados. Si querés probarlo en Power BI, se puede crear un login para un analista con una sola moneda (mismo
patrón que `tdw_powerbi` en `sql/05_security/01_roles_y_permisos.sql`): el mismo `.pbix` le muestra solo sus filas.

## 7. Capturas para el README

Ver [docs/img/README.md](img/README.md).
