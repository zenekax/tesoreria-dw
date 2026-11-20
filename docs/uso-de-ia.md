# Uso de IA en este proyecto

Registro honesto de cómo se usó la IA: qué hizo la herramienta, qué hizo Ignacio y qué se verificó.

## Herramienta y forma de trabajo

- **Claude Code** (modelo Claude Opus), trabajando sobre el repositorio local con acceso a la terminal y a Docker.
- Ignacio escribió la consigna completa (`PROMPT_INICIAL.md`) y las reglas del proyecto (`CLAUDE.md`): fases, criterios
  de calidad no negociables, convenciones de T-SQL y la regla "si algo no pudo probarse, decirlo".
- Se trabajó **fase por fase**. Al cierre de cada una: tests, commit en una rama `feat/fase-N-...` y un resumen.

## Qué hizo la IA

- **Escribió todo el código**: el generador de datos, el cargador, los scripts T-SQL (DDL, procedimientos, reglas
  de calidad, consultas, seguridad, vistas), los tests y la documentación.
- **Ejecutó y verificó**: corrió cada script dos veces seguidas, reconstruyó el entorno desde cero varias veces, midió
  la performance y escribió tests que comparan contra la "verdad" generada.
- **Propuso decisiones de diseño** y las justificó en los comentarios y en `docs/`.

## Qué hizo Ignacio

- Definió el problema de negocio, el alcance, las fases y los criterios de calidad.
- Tomó las decisiones que no eran obvias. Por ejemplo, el **grano de `fact_conciliacion`** (una fila por partida,
  como la planilla de conciliación, en lugar de una por factura).
- Instaló lo que requería aceptar licencias o cambiar la configuración del sistema (driver ODBC de Microsoft, `brew trust`).
- A mitad del proyecto pidió aprender haciendo. Entre el modo guiado y terminar el proyecto para después reconstruirlo,
  **eligió terminar y replicar**: por eso existe [`docs/guia-replica.md`](guia-replica.md).

## Qué se verificó y cómo

| Qué | Cómo |
|---|---|
| Que los datos de prueba sean exactamente los que se dice | Tests: cada error inyectado está en su archivo y línea, y toda fila fuera del manifiesto está limpia |
| Que la calidad detecte todo | Recall 174/174 contra el manifiesto, en 2 datasets y a escala 20; falsos positivos explicados uno por uno |
| Que la conciliación sea correcta | Precisión y recall 100% contra la conciliación "perfecta" del generador |
| Que las restricciones funcionen | Tests con **control positivo**: la fila válida entra y la misma fila con un campo roto falla con el código de error esperado |
| Que los tests prueben lo que dicen | Contrapruebas: se sacaron reglas del DDL y fallaron exactamente los tests correspondientes |
| Reproducibilidad | Borrar contenedor, volumen y datos, reconstruir y comparar la huella del contenido (staging y DW idénticos) |
| "3 comandos" | `scripts/levantar.sh` corrido desde un clon limpio del repo, dos veces, con la suite completa |
| Performance | Lecturas lógicas, CPU y planes reales antes/después, con mediana de 5 corridas |

## Errores de la IA que se encontraron en el camino

Los encontraron los tests o las verificaciones, no una revisión a ojo. Por eso las verificaciones automáticas son parte central del proyecto:

- El "reenvío del banco en el extracto del mes siguiente" a veces caía en el mismo mes (día 28 + 3 hábiles = 31).
- Un fixture de test salteaba **cualquier** error como "SQL Server no disponible" y escondía un bug de código.
- Tests de permisos que aceptaban cualquier error: una sentencia mal escrita también los hacía pasar.
- El *pooling* de ODBC hacía que una conexión heredara una transacción abierta de otra.
- `OBJECT_NAME(@@PROCID)` devolvía NULL con el usuario de mínimo privilegio (con `sa` no se notaba).
- Una fecha futura (dato erróneo) "envenenaba" la marca de agua de la carga incremental.
- Conflicto de *collation* entre `tempdb` y la base en las tablas temporales.
- Reglas de calidad que **culpaban a un comprobante por el error de otro** (5 falsos positivos).
- A escala 20, las reglas ERP vs. banco **perdían detecciones** (existencia en vez de emparejamiento 1 a 1).
- Identificadores de fila de dos tablas distintas tratados como únicos entre sí, lo que generaba falsos positivos.
- Una reescritura "en conjuntos" que resultó **más lenta** (unión por desigualdad que termina en un *spool*); se descartó midiendo.
- Errores de sintaxis de T-SQL (booleanos comparables, tipos en `STRING_AGG`), detectados al desplegar.

## Qué queda del lado de Ignacio

- **Reconstruir el proyecto con la guía** ([`docs/guia-replica.md`](guia-replica.md)) y poder explicar cada script en
  una entrevista: es la regla 8 del `CLAUDE.md`, y todavía no está cumplida.
- Armar el tablero de Power BI y las capturas (requiere Windows).
- Revisar y publicar el repositorio en GitHub.
