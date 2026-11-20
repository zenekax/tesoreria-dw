# Capturas para el README (guía)

Guardar las imágenes en esta carpeta con estos nombres exactos: el README final ya los referencia. Formato PNG, de
1600 px de ancho como máximo, sin datos personales ni de ningún empleador (todo es sintético).

| Archivo | Qué mostrar | De dónde |
|---|---|---|
| `01_modelo_powerbi.png` | Vista de modelo con las relaciones de la estrella (dimensiones arriba, hechos abajo) | Power BI → Vista de modelo |
| `02_flujo_caja.png` | Página 1 con una moneda seleccionada (ARS se ve bien: la devaluación hace subir el saldo en pesos) | Power BI |
| `03_aging.png` | Página 2: tramos, matriz por cliente y DSO | Power BI |
| `04_conciliacion.png` | Página 3: % conciliado por cuenta y tabla de pendientes | Power BI |
| `05_seguridad_execute_as.png` | Resultado de `sql/05_security/04_pruebas_permisos.sql` (qué ve cada usuario) | VS Code + extensión `mssql`, o la terminal |
| `06_plan_q2_antes_despues.png` | Los planes de `sql/07_performance/planes/Q2_antes.sqlplan` y `Q2_despues.sqlplan` lado a lado | VS Code (`mssql`) o SSMS: abrir el `.sqlplan` |
| `07_calidad_resultados.png` | `SELECT * FROM audit.dq_resultados` de la última ejecución, filtrado a `filas_con_error > 0` | VS Code + `mssql` |

Consejos:
- En Power BI: **Archivo → Exportar → Exportar a PDF** y recortar, o la herramienta de recortes de Windows.
- Antes de capturar: tema claro, sin la barra de filtros abierta, títulos en castellano.
- Si no hay Windows para Power BI (ver `docs/powerbi.md`, opción C), las capturas 02 a 04 se pueden reemplazar por
  gráficos de VS Code (`mssql` → resultados → *Chart*) sobre las mismas vistas `rpt.*`.
