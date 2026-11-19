# tesoreria-dw — Data warehouse de tesorería en SQL Server

## Qué es este proyecto
Proyecto de portfolio de Nacho (ex tesorero, Buenos Aires) para demostrar competencias de
analista/desarrollador de datos con SQL Server. Simula la operatoria de tesorería de una
fintech de pagos transfronterizos: pagos a proveedores, cobranzas, movimientos bancarios
y conciliación. **Todos los datos son sintéticos. Nunca usar datos reales de ningún empleador.**

Objetivo: que un reclutador abra el repo y vea, en 5 minutos, T-SQL avanzado, modelado
dimensional, ETL con control de calidad, seguridad, Git prolijo y uso de IA documentado.

## Stack
- SQL Server 2022 en Docker (`docker-compose.yml`), cliente: Azure Data Studio / VS Code (mssql) / sqlcmd
- Python 3.11+ (pandas, pyodbc, faker, pytest) para generar datos y cargar
- Power BI Desktop (opcional, solo el .pbix o capturas en `docs/img/`)
- Git + GitHub (usuario: zenekax), commits convencionales en español o inglés (elegir uno y mantenerlo)

## Estructura objetivo
```
tesoreria-dw/
├── CLAUDE.md
├── README.md                 # lo escribe Claude al final de cada fase
├── docker-compose.yml
├── .env.example              # nunca commitear .env
├── docs/
│   ├── REQUISITOS.md         # mapeo requisito del puesto -> entregable
│   ├── modelo.md             # diagrama (mermaid) y decisiones de modelado
│   ├── calidad-de-datos.md   # reglas de validación y resultados
│   ├── seguridad.md          # roles, RLS, masking
│   └── uso-de-ia.md          # cómo se usó IA, qué se verificó a mano
├── sql/
│   ├── 00_setup/             # crear DB, schemas (stg, dw, audit, sec)
│   ├── 01_staging/           # tablas stg.*
│   ├── 02_dw/                # dimensiones y hechos (dw.*)
│   ├── 03_etl/               # stored procedures de carga (usp_load_*)
│   ├── 04_quality/           # chequeos y tabla audit.dq_resultados
│   ├── 05_security/          # roles, permisos, RLS, dynamic data masking
│   ├── 06_queries/           # consultas analíticas (window functions, CTEs)
│   └── 07_performance/       # índices, planes de ejecución antes/después
├── python/
│   ├── generar_datos.py      # datos sintéticos reproducibles (seed fija)
│   ├── cargar_staging.py
│   └── tests/
└── data/                     # CSV generados (en .gitignore si pesan)
```

## Reglas de trabajo
1. **Una fase a la vez.** Al terminar cada fase: probar, commit, actualizar README y avisar qué falta. No avanzar sin que Nacho diga OK.
2. **Todo es idempotente y reproducible**: scripts re-ejecutables, `seed` fija, `CREATE OR ALTER`.
3. **T-SQL**: nombres en snake_case, schemas `stg`, `dw`, `audit`, `sec`. Claves surrogate `INT IDENTITY` en dimensiones. Comentar el *porqué*, no el qué.
4. **Calidad de datos**: cada regla se registra en `audit.dq_resultados` (regla, tabla, filas evaluadas, filas con error, fecha, severidad). Las filas rechazadas van a una tabla de cuarentena, no se borran.
5. **Seguridad**: credenciales solo en `.env` (ignorado por Git). Principio de mínimo privilegio. Nada de `sa` en scripts de aplicación.
6. **Git**: ramas `feat/...`, commits chicos, PRs aunque sea contra main propio. Nunca commitear `.env`, `.bak` ni datos pesados.
7. **Performance**: toda optimización se documenta con evidencia (plan de ejecución, `SET STATISTICS IO`, métricas antes/después).
8. **Honestidad sobre IA**: en `docs/uso-de-ia.md` registrar qué generó la IA y qué verificó Nacho. Nacho debe poder explicar cada script en una entrevista; si algo es complejo, explicarlo en comentarios o en `docs/`.
9. Responder siempre en español rioplatense neutro, directo.

## Perfil de Nacho (para ajustar el nivel de las explicaciones)
Sabe: SAP (F110, FBL5N, F-30), Excel avanzado, Power BI, Python básico/intermedio, APIs bancarias (Interbanking), lógica de conciliación y cobranzas.
Está aprendiendo: T-SQL avanzado, modelado dimensional, ETL en SQL Server, Azure/Fabric.
Explicar T-SQL y modelado con analogías de tesorería (ej.: staging = extracto bancario crudo; DW = libro conciliado).
