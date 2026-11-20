# 10 preguntas de entrevista que este proyecto permite responder

Respuestas modelo breves. La idea es contarlas con tus palabras y con un ejemplo concreto del proyecto.

### 1. ¿Cómo decidís el grano de una tabla de hechos?

"El grano es qué representa una fila, y lo defino antes que cualquier columna. En la conciliación dudé entre una fila
por factura y una por partida. Elegí **partida**, como la planilla de conciliación bancaria: cada pago, cada cobranza y
cada movimiento del banco sin pareja tiene su fila, y si matchean comparten la misma. Con una fila por factura, los
pagos parciales se resumían y los movimientos del banco sin factura no tenían dónde ir. Y es un *accumulating
snapshot*: la fila se completa a medida que pasan los hitos (factura, vencimiento, libro, banco, conciliación)."

### 2. ¿Cómo implementaste un SCD tipo 2?

"En contrapartes: riesgo, plazo, segmento y estado guardan historia, con `vigente_desde/hasta`; email y razón social
se corrigen en todas las versiones (tipo 1). Para detectar cambios uso **dos hashes persistidos**, uno para cada tipo,
y no comparo columna por columna. Un **índice único filtrado** (`WHERE es_vigente = 1`) garantiza una sola versión
vigente. Los snapshots se aplican en orden de fecha, y cada hecho busca la versión vigente en su propia fecha: un
pago de marzo sigue viendo el riesgo que tenía el cliente en marzo."

### 3. ¿MERGE o INSERT/UPDATE?

"Los dos, según el caso. MERGE con `HOLDLOCK` para un upsert simple (las cuentas bancarias): es claro y `OUTPUT
$action` da los conteos. Para el SCD2 y los hechos, UPDATE + INSERT explícitos: son varias operaciones distintas,
separadas se prueban y se cuentan una por una, y MERGE tuvo bugs conocidos y problemas de concurrencia sin
`HOLDLOCK`. Para detectar cambios uso `WHERE EXISTS (SELECT origen EXCEPT SELECT destino)`, que trata NULL = NULL."

### 4. ¿Cómo garantizás que un proceso de carga sea idempotente y reproducible?

"Staging se carga por archivo con su hash: si no cambió, se omite; si cambió, se reemplaza entero en una transacción.
El ETL hace upsert y no escribe si no hay cambios. Los datos se generan con seed fija. Y lo **pruebo**: corro todo dos
veces, borro el contenedor y reconstruyo, y comparo la huella del contenido. También probé que cargar 'hasta marzo y
después incremental' da exactamente lo mismo que cargar todo de una."

### 5. ¿Cómo sabés que tus controles de calidad funcionan?

"Inyecté 174 errores con un manifiesto exacto (archivo, línea, campo y valor), y un test verifica dos cosas: que cada
error esté donde dice, y que **toda fila fuera del manifiesto esté limpia**. Eso me permite medir recall (174/174) y
precisión (97,8%), con cada falso positivo explicado. Lo que falla una regla ERROR va a cuarentena, no se borra, y se
libera al corregir y recargar. Además, totales de control: el saldo del banco difiere del DW exactamente en la plata
de las líneas en cuarentena."

### 6. ¿Qué problema encontraste con la carga incremental?

"Uso una marca de agua (última fecha cargada) menos una ventana de reproceso de 7 días para los movimientos que el
banco informa tarde. La primera prueba mostró que un pago con fecha futura, que era un error de tipeo, **empujaba la
marca de agua** y la corrida siguiente se salteaba fines de octubre. La solución fue que las fechas futuras no cuenten
para la marca. Y una lección operativa: el incremental no repara huecos viejos; para eso está la carga completa."

### 7. Contame una optimización.

"La evolución mensual de la cartera hacía 1,3 millones de lecturas a escala 20. Agregué un índice cubriente y uno
filtrado: el plan pasó de *Scan* a *Seek*, pero la mejora fue **1,1x**, porque la consulta tenía una subconsulta
correlacionada que buscaba una vez por factura y por mes. Un primer intento de reescritura fue **peor**: una unión por
desigualdad terminaba en un *spool*. La versión buena calcula lo cobrado por factura y mes, y lo acumula con
`SUM() OVER`: **3.638 lecturas, 358 veces menos**, con un test que verifica que da lo mismo. Además, el plan en
paralelo usaba 5 veces más CPU para casi el mismo tiempo, así que dejé `MAXDOP 1`."

### 8. ¿Cuándo usás un índice columnstore o uno filtrado?

"**Columnstore** para agregaciones sobre muchas filas y pocas columnas (el flujo de caja suma montos por fecha):
compresión por columna y *batch mode*, 28 veces menos lecturas. Lo hice no agrupado para mantener la PK y el UNIQUE que
usa la carga. **Filtrado** cuando la consulta mira un subconjunto chico y estable (partidas pendientes, el 1% de la
tabla). Con un detalle clave: el optimizador lo usa solo si la condición coincide con el filtro. Con `LIKE
'PENDIENTE%'` no lo usaba; con `IN (...)`, sí."

### 9. ¿Cómo resolviste la seguridad?

"Roles con permisos **a nivel de schema** y DENY explícito (los analistas no ven staging ni auditoría). **Row-Level
Security** con una función inline `SCHEMABINDING`: cada analista ve solo sus monedas, también en Power BI, porque el
filtro lo pone el motor. **Dynamic Data Masking** de CBU, CUIT y email, sabiendo que no es cifrado. Dos hallazgos: el
ETL necesita `UNMASK`, porque si no copiaba valores enmascarados a tablas temporales; y con permisos mínimos,
`OBJECT_NAME(@@PROCID)` devuelve NULL, porque el usuario no ve la metadata. Todo probado con `EXECUTE AS` y por código
de error."

### 10. ¿Cómo usaste IA en el proyecto?

"Con Claude Code como asistente: yo definí el problema, las fases, los criterios y las decisiones de negocio, y la IA
escribió y ejecutó el código. Lo importante es que **nada se aceptó sin verificación automática**: tests contra
'verdades' generadas, contrapruebas, reconstrucción desde cero y mediciones. Esas verificaciones encontraron una docena
de errores de la IA, todos documentados en `docs/uso-de-ia.md`. Después reconstruí el proyecto yo con una guía, para
poder explicar cada línea."
