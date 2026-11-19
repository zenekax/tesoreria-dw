# Mapeo: requisitos del puesto → entregables del proyecto

Fuente: aviso de búsqueda (SQL Server en análisis, desarrollo o integración de datos).

## Requisitos excluyentes

| Requisito del aviso | Dónde se demuestra | Fase |
|---|---|---|
| SQL Server en análisis, desarrollo o integración de datos | Todo el repo (SQL Server 2022 + ETL + análisis) | 0–8 |
| Dominio avanzado de T-SQL | `sql/03_etl`, `sql/06_queries`: CTEs recursivas, window functions, APPLY, PIVOT, SP con TRY/CATCH, SQL dinámico | 4, 6 |
| Modelado relacional | `docs/modelo.md`: staging normalizado + estrella dimensional, SCD2, grano de cada hecho | 3 |
| Optimización de consultas | `sql/07_performance`: planes de ejecución, STATISTICS IO/TIME, índices antes/después | 7 |
| Integración y transformación de datos | `python/cargar_staging.py` + `dw.usp_load_*` + carga incremental | 2, 4 |
| Validación y control de calidad de datos | `sql/04_quality`, `audit.dq_resultados`, cuarentena, tests que detectan errores inyectados | 5 |
| Git y buenas prácticas de versionado | Ramas `feat/*`, commits convencionales, PRs, `.gitignore`, sin secretos | todas |
| Permisos y manejo seguro de información confidencial | `sql/05_security`: roles, GRANT/DENY, RLS, Dynamic Data Masking, `docs/seguridad.md` | 8 |
| IA como apoyo al análisis, desarrollo y documentación | `docs/uso-de-ia.md` + `CLAUDE.md` + historial de trabajo con Claude Code | todas |
| Entender el negocio y comunicar a usuarios no técnicos | Comentarios de negocio en cada consulta, tablero Power BI, README orientado a un lector no técnico | 6, 9, 10 |

## Requisitos valorados

| Requisito | Cómo cubrirlo | Estado |
|---|---|---|
| Power BI | Tablero sobre vistas `rpt.*` (flujo de caja, aging, conciliación) | Fase 9 |
| Python | Generación y carga de datos, tests con pytest | Fases 1, 2, 5 |
| ETL/ELT | Python → staging (EL) y T-SQL (T): es ELT | Fases 2, 4 |
| Azure / Microsoft Fabric / Azure AI Search | **Extensión posterior:** migrar DW a Azure SQL Database o Fabric Warehouse; conectar con el proyecto RAG (Azure AI Search sobre documentación del DW) | Fuera de alcance v1 |
| Dynamics 365 Finance & Operations | Estudiar conceptos y módulos (cuentas por pagar/cobrar, diarios, dimensiones financieras) y mapearlos al modelo; no se implementa | Estudio |
| C# / .NET y herramientas de administración de SQL Server | Alcance mínimo: SSMS/Azure Data Studio, SQL Agent (job simulado), backup/restore documentado. C# opcional | Opcional |
| Formación afín (Sistemas / Datos) | Certificaciones sugeridas: PL-300, DP-900 (verificar vigencia en Microsoft Learn) | Paralelo |
| Inglés técnico | README y `docs/` clave en inglés (versión bilingüe del README) | Fase 10 |

## Definición de "terminado" (v1)
- [ ] Se levanta en 3 comandos desde cero.
- [ ] Los tests detectan el 100% de los errores inyectados.
- [ ] Hay al menos 3 optimizaciones con evidencia antes/después.
- [ ] RLS y masking probados con `EXECUTE AS`.
- [ ] README con diagrama, capturas y resultados.
- [ ] Repo público en GitHub (`zenekax/tesoreria-dw`) y enlazado desde el portfolio y el CV.
