# proyectos2026 — Cadena de Suministros (SAP → BigQuery)

Repositorio de análisis de cadena de suministros sobre réplicas SAP en BigQuery
(proyecto GCP `aecorsoft`): fill rate, inventarios, ventas, transporte y rechazos.

## Contexto obligatorio

Antes de escribir o modificar SQL, usar el mapa de datos (se importa aquí):

@MAPA_DATOS_BIGQUERY.md

## Reglas al trabajar con SQL

- Dialecto: **BigQuery Standard SQL**. Referenciar tablas siempre con nombre
  completo: `` `aecorsoft.<dataset>.<tabla>` ``.
- **No deducir el dataset por analogía** con una tabla "hermana" (ver sección 1
  del mapa). Si una tabla no está en el mapa, verificar con
  `INFORMATION_SCHEMA.TABLES` o preguntar antes de usarla.
- No hacer joins contra tablas marcadas como **no replicadas** (secciones 2.6 y 7
  del mapa): `VFKK`, `ESSR`, `TVAG`/`TVAGT`, `CDHDR`/`CDPOS`, `VBSTT`.
  Tampoco inventar valores para reemplazarlas.
- Aplicar las reglas transversales de la sección 3 del mapa (conversión a M3,
  `WADAT_IST` + `WBSTK='C'`, guardrail de `GWLDT`, factor x100 en CLP, Gescorp).
- Antes de reutilizar una tabla de `Procesos_CDS`, confirmar sus columnas con
  `INFORMATION_SCHEMA.COLUMNS` (puede estar desactualizada respecto al script).
- Si hay conflicto entre el mapa y el `CLAUDE.md` de un subproyecto, **gana el
  del subproyecto**.

## Convenciones

- Idioma: español en comentarios, nombres de columnas de salida y documentación.
- Nombres de CTE descriptivos en `snake_case`.
- Cuando se confirme una tabla, un dataset o un dominio de campo nuevo,
  actualizar la sección correspondiente de `MAPA_DATOS_BIGQUERY.md`.

## Estado del repositorio

Por ahora el repo solo contiene el mapa de datos. Las carpetas de subproyectos
(`fillrate_etapa2/`, `ventas_cl/`, etc.) y sus `CLAUDE.md` citados en el mapa
**todavía no están subidos**; hasta entonces, esas referencias no se pueden abrir.

## Pendiente de completar

- Cómo se ejecutan las queries (consola BigQuery, `bq` CLI, Python) y con qué
  credenciales / cuenta de servicio.
- Dependencias de Python y cómo correr los scripts de `PYTHON/`.
