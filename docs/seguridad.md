# Seguridad (Fase 8)

Scripts en `sql/05_security/` (se despliegan con `scripts/run_sql.sh`), tests en `python/tests/test_seguridad.py`.

## Modelo de amenazas (en 10 líneas)

1. **Qué se protege:** números de cuenta (CBU/CLABE), CUIT/CNPJ y emails de contrapartes, y los montos por mesa/país.
2. **Analista curioso o con credencial robada:** lee solo `dw` y `rpt`; no entra a staging (datos crudos sin enmascarar) ni a auditoría.
3. **Analista de otra mesa:** RLS le filtra las filas de las monedas que no le corresponden, en cualquier consulta y en Power BI.
4. **Captura de pantalla o export de un reporte:** CBU, CUIT y email salen enmascarados (Dynamic Data Masking).
5. **Inferencia por diccionario:** las huellas SCD (hash de email + CUIT) no las puede leer un analista (DENY por columna).
6. **Proceso de carga comprometido:** `rol_etl` solo ejecuta el orquestador; no crea ni borra tablas, no lee el DW directo ni borra la bitácora.
7. **Auditor que modifica evidencia:** `rol_auditoria` lee todo y no escribe nada (DENY explícito de INSERT/UPDATE/DELETE/EXECUTE).
8. **Escalada de privilegios:** nadie salvo dbo puede tocar `sec.usuario_moneda` (darse más monedas) ni la política de RLS.
9. **Secretos en el repo:** las claves viven en `.env` (ignorado por Git) y se pasan a los scripts como variables; `sa` solo despliega.
10. **Fuera de alcance (riesgo aceptado):** un DBA con `sysadmin`, el acceso físico al contenedor y el cifrado en reposo (TDE / Always Encrypted).

## Roles

| Rol | Puede | No puede | Miembros |
|---|---|---|---|
| `rol_lectura_analistas` | `SELECT` en `dw` y `rpt`; ejecutar el reporte mensual | leer `stg`, `audit`, `sec`; leer los hashes SCD; escribir | `analista_ar`, `analista_br` (demo, sin login), `tdw_powerbi` (login) |
| `rol_auditoria` | `SELECT` en todo (`dw`, `rpt`, `stg`, `audit`, `sec`), ver datos sin enmascarar | escribir o ejecutar procedimientos (DENY explícito) | `auditor_demo` (demo) |
| `rol_etl` | `EXECUTE dw.usp_run_etl`; escribir en `stg`; ver datos sin enmascarar | crear/borrar tablas, leer `dw` directo, borrar la bitácora | `tdw_etl` (login) |

- **Permisos a roles, nunca a personas**, y **a nivel de schema** (cubren las tablas que se creen después).
- **DENY explícito** donde importa: un DENY le gana a cualquier GRANT, así un error al agregar a alguien a otro rol no abre staging.
- El ETL accede a las tablas a través de los procedimientos por **ownership chaining** (mismo dueño, `dbo`).

## Row-Level Security (RLS)

- `sec.usuario_moneda`: qué monedas ve cada usuario (`'*'` = todas). `analista_ar` → ARS y USD; `analista_br` → BRL; `tdw_powerbi` → todas.
- `sec.fn_rls_moneda_key` / `sec.fn_rls_moneda_iso`: funciones inline `WITH SCHEMABINDING` que devuelven una fila si el usuario puede ver la fila.
- `sec.pol_rls_moneda`: política con **filtro** sobre los 6 hechos que tienen moneda y sobre `dim_banco_cuenta`.
- Ven todo, sin filtro: `db_owner`, `rol_etl` (la carga tiene que ver todo) y `rol_auditoria`.
- El filtro lo aplica el motor en **todas** las consultas, también a través de vistas y de Power BI: no depende de que el analista o el reporte se acuerden de filtrar.

## Dynamic Data Masking

| Columna | Máscara | Ejemplo para un analista |
|---|---|---|
| `dim_banco_cuenta.numero_cuenta` | `partial(0, "XXXX...", 4)` | `XXXX...7809` |
| `dim_contraparte.email` | `email()` | `cXXX@XXXX.com` |
| `dim_contraparte.tax_id` | `partial(0, "XX-XXXXXX", 3)` | `XX-XXXXXX6-1` |

- `UNMASK` lo tienen auditoría y **el ETL**. Sin ese permiso, la carga copiaba a sus tablas temporales los valores enmascarados y los cruces contra staging fallaban: el masking se aplica a todo lo que lee un usuario, también dentro de los procedimientos.
- En una base nueva las columnas **nacen enmascaradas** (en el `CREATE TABLE`). Para bases anteriores hay una migración: `email` y `tax_id` alimentan la columna calculada `hash_tipo1`, así que hay que sacar el índice y el hash, enmascarar y volver a crearlos en una transacción.
- **Límite:** el masking **no es cifrado**. Un analista puede inferir el dato con filtros (`WHERE numero_cuenta = '...'` devuelve la fila); un test lo documenta. Es una capa para pantallas y exportaciones; la protección fuerte son los permisos y, para datos críticos, Always Encrypted.

## Cómo se prueba

- `sql/05_security/04_pruebas_permisos.sql`: con `EXECUTE AS USER` se "suplanta" a cada usuario y se muestra qué monedas ve, cómo ve una cuenta y un email, y si puede leer staging o borrar en el DW. Corre en cada despliegue.
- `python/tests/test_seguridad.py` (31 tests): RLS exacto por usuario en cada hecho (cantidad de filas igual a la que ve `sa` filtrando esas monedas), que filtrar por otra moneda no la saltea, masking para analista vs. auditor, que el masking no rompe filtros, 13 prohibiciones verificadas por código de error (229 objeto, 230 columna), el login de Power BI y que el ETL funciona con todo activo.
