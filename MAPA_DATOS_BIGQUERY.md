---
tags: [bigquery, sap, contexto-claude, cadena-suministros]
updated: 2026-09-28
---

# Mapa de datos BigQuery — Cadena de Suministros

> [!info] Cómo usar esta nota
> Está pensada como **contexto de arranque para Claude** (u otra persona nueva en el
> repo) antes de escribir SQL contra `aecorsoft`. Resume qué dataset/tabla usar, y sobre
> todo los **casos particulares por campo** que ya costaron tiempo de diagnóstico en los
> distintos subproyectos de `PYTHON/`. No reemplaza los `CLAUDE.md` de cada carpeta —
> es el mapa de arriba; el detalle completo (CTEs, decisiones, pendientes) vive en el
> `CLAUDE.md` de cada subproyecto, enlazado en la sección 6.
>
> Generada el 2026-08-20 a partir de los `CLAUDE.md` existentes en 11 subproyectos.
> **No está verificada contra el catálogo real de BigQuery en el momento de generarla** —
> son observaciones acumuladas sesión a sesión. Antes de confiar en un dato de aquí para
> algo crítico, contrastar con `INFORMATION_SCHEMA` o con el `CLAUDE.md` fuente (fecha de
> confirmación incluida donde se conoce).

## 1. Datasets del proyecto `aecorsoft`

| Dataset | Contenido | Notas |
|---|---|---|
| `cdc_produccion_pp_cp50_01_new` | Maestro de materiales y stock: `mara`, `makt`, `marc`, `marm`, `mard`, `mcha`, `mseg_full`, `mkpf`, `cabn`, `ausp`, `cawn`, `cawnt`. También `mchb` (asumida, aún sin confirmar) | El nombre "cp50_01" no es intuitivo — es el dataset "grande" de datos de producción/materiales |
| `sap_sd` | Ventas y distribución: `vbak`, `vbap`, `vbep`, `vbuk`, `vbpa`, `vbfa`, `vbrk`, `vbrp`, `kna1`, `likp`, `lips`(⚠ ver abajo), `vttk`, `vttp`, `tvgrt`, `tvtwt`, `tspat`, `tvlst`, `t005t`, `vfkp`, `ZCL_SD_DUS1` (custom), `zsd_t_export` (custom, nombre no confirmado al 100%) | Dataset más usado en todo el repo |
| `sap_mm` | Gestión de materiales: `mch1`, `mbew`, `t001k`, `lfa1`, `ekko`, `ekpo`, `ekbe`, y **`lips`** (⚠ SD por naturaleza, pero vive aquí, no en `sap_sd`) | Ver advertencia de "un dataset = un módulo" más abajo |
| `sap_co` | Controlling: `ckmlhd` (poblada), `ckmlcr` (**confirmada en esquema, vacía en datos — gap de replicación**) | Bloquea cualquier valorización Material Ledger hasta que se resuelva |
| `sap_fi` | Finanzas / custom: `zconfol` (tabla custom de folio fiscal, NO estándar SAP) | Multi-país (Chile + México mezclados, ver sección 4) |
| `Comercial` | Tablas comerciales ya preparadas (no réplicas SAP crudas): `Tabla_Pedidos_Exportacion` (1 fila por posición de pedido de venta de exportación; columnas usadas: `Documento_de_ventas`, `Posicion_Ped_Venta`, `Credito`, `Ctd_Ped_m3`) | Visto en `comercial_exportaciones` (2026-10-01). Esquema completo no verificado con `INFORMATION_SCHEMA` |
| `Procesos_CDS` | **Tablas de salida propias del repo** (no réplicas SAP) — resultado de los `CREATE OR REPLACE TABLE/VIEW` de los distintos proyectos | Ver catálogo completo en sección 5 |

> [!warning] "Un dataset = un módulo SAP" es una trampa
> El patrón no es consistente. Confirmado con casos reales:
> - Tablas MM están repartidas entre `cdc_produccion_pp_cp50_01_new` y `sap_mm`.
> - `lips` (documento de entrega, SD) vive en `sap_mm`, no en `sap_sd`.
> - `VFKK` (relacionada con `VFKP`, que sí está en `sap_sd`) **no está replicada** en absoluto.
>
> No asumir el dataset por analogía con una tabla "hermana" — verificar con
> `INFORMATION_SCHEMA.TABLES` o preguntar antes de escribir la query.

## 2. Catálogo de tablas por área de negocio

### 2.1 Maestro de materiales

| Tabla | Dataset | Campos clave usados | Uso |
|---|---|---|---|
| `mara` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `MEINS`, `VOLUM`, `VOLEH`, `MTART`, `BRGEW` | Datos generales, volumen y tipo de material |
| `makt` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `MAKTX`, `SPRAS` | Descripción (usar `SPRAS='S'` para español) |
| `marc` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `WERKS`, `PRENO`, `MAABC` | Material×Centro. `PRENO` (centro `TCDS`) = punto de pedido / horizonte de producción; `PRENO='D'` también se usa como marca de **obsolescencia**. `MAABC` = indicador ABC de MRP |
| `marm` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `MEINH`, `UMREZ`, `UMREN`, `HOEHE`, `MEABM` | Conversión de unidades y espesor |
| `mard` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `WERKS`, `LGORT`, `LABST` | Stock por planta/almacén, **agregado** (no por lote) |
| `mchb` | `cdc_produccion_pp_cp50_01_new` (asumido) | `CLABS`, `CUMLM`, `CINSM`, `CEINM`, `CSPEM`, `CRETM` | Stock **por lote**. No confirmada en BQ todavía |
| `mcha` | `cdc_produccion_pp_cp50_01_new` | `MATNR`, `WERKS`, `CHARG`, `ERSDA` | Fecha de creación de lote a nivel **planta** — fuente más precisa |
| `mch1` | `sap_mm` | `MATNR`, `CHARG`, `ERSDA` | Fecha de creación de lote a nivel **cliente/mandante** — fallback si no está en `mcha` |
| `mseg_full` / `mkpf` | `cdc_produccion_pp_cp50_01_new` | `BUDAT`, `BWART`, `SHKZG` | Movimientos de material — backfill de stock y proxy de fecha de creación de lote |
| `cabn`/`ausp`/`cawn`/`cawnt` | `cdc_produccion_pp_cp50_01_new` | `KLART='001'` | Sistema de clasificación SAP — fuente de la **jerarquía Gescorp** (ver sección 3.3) |
| `mbew` | `sap_mm` | `STPRS`, `SALK3` | Valorización — **solo período vigente, sin historial**. No sirve para reconstruir meses pasados |

### 2.2 Ventas y distribución (SD)

| Tabla | Dataset | Campos clave usados | Uso |
|---|---|---|---|
| `vbak` | `sap_sd` | `VBELN`, `AUART`, `VKORG`, `ERDAT`, `GWLDT`, `BSTNK`, `VDATU`, `LIFSK`, `SPART`, `VTWEG`, `VKGRP` | Cabecera de pedido de venta |
| `vbap` | `sap_sd` | `VBELN`, `POSNR`, `MATNR`, `KWMENG`, `VRKME`, `NETWR`, `ABGRU` | Posición de pedido |
| `vbep` | `sap_sd` | `VBELN`, `POSNR`, `ETENR`, `EDATU` | Líneas de programación — `ETENR` más bajo = "1era Fecha" (equiv. `RV45A-ETDAT`) |
| `vbuk` | `sap_sd` | `VBELN`, `CMGST`, `WBSTK` | Estado de cabecera: status de crédito y estado de movimiento de mercancía |
| `vbpa` | `sap_sd` | `VBELN`, `POSNR`, `PARVW`, `KUNNR` | Interlocutores. `PARVW='WE'`=destinatario mercadería, `'RE'`=responsable de factura (siempre a nivel cabecera, `POSNR='000000'`) |
| `vbfa` | `sap_sd` | `VBELV`, `VBELN`, `POSNN`, `VBTYP_N` | Flujo de documentos — el campo clave para casi todo el repo. Ver dominio de `VBTYP_N` en sección 3.1 |
| `likp` | `sap_sd` | `VBELN`, `WADAT_IST` | Cabecera de entrega — fecha real de salida de mercancía. **Ver advertencia de confiabilidad en 3.1** |
| `lips` | `sap_mm` (⚠) | `VBELN`, `POSNR`, `LFIMG` | Posición de entrega — cantidad despachada |
| `vttk`/`vttp` | `sap_sd` | `TKNUM`, `VBELN` | Cabecera/posición de transporte — vincula entrega↔transporte |
| `vbrk` | `sap_sd` | `VBELN`, `FKDAT`, `FKART`, `XBLNR` | Cabecera de factura |
| `vbrp` | `sap_sd` | `VBELN`, `AUBEL`, `VGBEL` | Posición de factura — `AUBEL`=pedido de origen, `VGBEL`=documento anterior inmediato |
| `kna1` | `sap_sd` | `KUNNR`, `NAME1`, `REGIO` | Maestro de clientes |
| `tvgrt`/`tvtwt`/`tspat`/`tvlst` | `sap_sd` | texto + `SPRAS` | Tablas de texto: grupo vendedores / canal / sector / bloqueo de entrega |
| `t005t` | `sap_sd` | `LAND1`, `SPRAS`, `LANDX` | Texto de país |
| `vfkp` | `sap_sd` | `FKNUM`, `FKPOS`, `FKPTY`, `EBELN`, `EBELP`, `LBLNI`, `TDLNR`, `NETWR`, `WAERS`, `STBER`/`STABR`/`STFRE` | Posiciones de gastos de transporte (`FKPTY='ZE18'`=consolidador) |

### 2.3 Compras / MM (orden de servicio)

| Tabla | Dataset | Uso |
|---|---|---|
| `ekko`/`ekpo` | `sap_mm` | Orden de compra de servicio (`BSART='ZSE'`) generada al transferir `VFKP` |
| `ekbe` | `sap_mm` | Historial de servicio (HES) — cobertura parcial (~22%), no usada como fuente final |
| `lfa1` | `sap_mm` | Maestro de proveedores (`LIFNR`→`NAME1`) |

### 2.4 Controlling / Material Ledger

| Tabla | Dataset | Uso |
|---|---|---|
| `ckmlhd` | `sap_co` | Cabecera Material Ledger: `MATNR`+`BWKEY`(centro)→`KALNR` |
| `ckmlcr` | `sap_co` | Valor por período/moneda (`CURTP=30`=moneda de grupo/USD). **Vacía en BQ** — usar `SE16N` en SAP mientras tanto |
| `t001k` | `sap_mm` | `BWKEY`(área de valoración)→`BUKRS`(sociedad) |

### 2.5 Custom / no estándar

| Tabla | Dataset | Uso |
|---|---|---|
| `zconfol` | `sap_fi` | Folio fiscal (Chile: `NFOLIO`; México: `UUID`/timbrado). Ver sección 4 |
| `ZCL_SD_DUS1` | `sap_sd` | Reporte Z ventas↔transporte, 1 fila = posición dentro de un `TKNUM` |
| `zsd_t_export` | `sap_sd` (nombre no confirmado al 100%) | Reporte Z ventas↔producción, incluye posiciones sin transporte asignado |

### 2.6 No disponibles en BigQuery (confirmado, no perder tiempo buscando)

| Tabla | Motivo | Alternativa usada |
|---|---|---|
| `VFKK` | No replicada | Se omite `clase_gasto`/`FKART` en vez de inventar un valor |
| `ESSR` | No replicada | — |
| `TVAG`/`TVAGT` (texto de `ABGRU`) | No replicada | `Motivo_Rechazo` queda sin descripción, código crudo |
| `CDHDR`/`CDPOS` (historial de cambios) | No replicada — confirmado que **sí existe en SAP** (`RVSCD100`), solo falta el gap de replicación BASIS/BI | Extracción manual vía `SE16N` en SAP, procesada en Python (ver `log_fillrate_etapa4`) |
| `VBSTT` | No existe | `CMGST` traducido con `CASE` manual (A/B/D) |

## 3. Reglas transversales — aplican en más de un proyecto

### 3.1 `VBFA.VBTYP_N` — el campo que conecta todo el flujo de documentos

| Valor | Significado | Usado en |
|---|---|---|
| `'J'` | Entrega asociada a la posición | `fillrate_etapa2` (excluir demanda con transporte), `ventas_cl`/`gv_rechazos_cl` (`Fecha_Envio`) |
| `'M'` | Factura asociada a la posición | `ventas_cl` (`Facturado`) |
| `'O'` | Agrupa **dos conceptos distintos** — desambiguar por `VBRK.FKART`: `'ZNC'`=nota de crédito pura, `'ZDEV'`/`'ZDV1'`=devolución física | `ventas_cl` — se separaron en dos flags/CTEs independientes a propósito |
| `'N'` | Anulación (`FKART` `S1`/`ZCAR`) | visto, no implementado (<0.3% volumen) |
| `'P'` | Nota de débito (`FKART='ZND'`) | visto, no implementado |

> [!warning] `LIKP.WADAT_IST` no es confiable por sí solo
> Puede traer la fecha **planificada** aunque el movimiento de mercancía (PGI) real no se
> haya hecho. Condicionar siempre a `VBUK.WBSTK='C'` (movimiento completo) antes de
> exponerla como "fecha real de salida". Confirmado en `control_embarques` y reutilizado
> en `gv_rechazos_cl`.

### 3.2 Conversión a M3 — misma fórmula en todo el repo

```
qty_base = qty_altUM × MARM.UMREZ / MARM.UMREN          -- unidad alterna → base
qty_m3   = qty_base  × MARM.UMREN / MARM.UMREZ (registro con MEINH='M3')  -- base → M3
```

Si no hay registro `MARM` con `MEINH='M3'`, cascada de fallback (orden confirmado en
`prov_inventarios`): `MARM MEINH IN ('DM3','CDM','L')` → `MARM MEINH='CM3'` → `MARA.VOLUM/VOLEH`.

> [!warning] El código SAP de dm³ **no es único** en el repo
> `CDM` aparece en `MARA.VOLEH` (`fillrate_etapa2`, `fillrate_analityc2026.sql`), mientras
> que `DM3` aparece en `MARM`/`VEKP` (`log_fillrate_lotesabajo`, `plan_planmolduras`).
> Tratar `CDM`/`DM3`/`L` como sinónimos (÷1000) y `CM3` como cm³ (÷1 000 000). Auditar con
> una columna `metodo_conversion_m3` (patrón usado en `prov_inventarios`).

> [!bug] Bug conocido, aún sin corregir (2026-08-11)
> `volumen_solicitado_m3` en la base de causa raíz (`fillrate_etapa2`/`etapa3`/`etapa5`)
> tiene una razón m³/unidad **~1000x inflada** en la mayoría de las filas de casi todos
> los materiales — confirmado contra entregas reales SAP (pedido `23307055`/pos.`10`: razón
> real 0,069 m³/unidad, no la que trae el campo). Detalle en la nota de memoria local
> `project_fillrate_etapa5_repaqueteo` (ver sección 8). **No usar `volumen_solicitado_m3`
> crudo para análisis de precisión sin revisar este bug primero.**

### 3.3 Jerarquía de clasificación "Gescorp" (CABN/AUSP/CAWN/CAWNT)

Sistema de clasificación SAP estándar (`KLART='001'`) reutilizado en casi todos los
proyectos para obtener familia/subfamilia/marca de un material:

| Nivel | Campo Gescorp | Columna típica |
|---|---|---|
| 2 | `RG_FAMILIA` | `nivel_2_familia` |
| 3 | `RG_SUBFAMILIA` | `nivel_3_subfamilia` |
| 4 | `RG_MARCA` | `nivel_4_marca` |
| 6 | `RG_NIVELRG` | `nivel_6_nivelrg` |

Patrón de CTEs: `cabn_sku` → `pivot_clasificacion` → `descripciones_sku`. Cae al código
crudo (`cod_nivel_*`) si no hay descripción traducida. Origen confirmado en
`fillrate_etapa2/llenado_capacidad.sql`; reutilizado literal en `prov_inventarios`,
`ventas_cl`, `ventas_stocks_ventas`, `log_asignacion_optima`.

### 3.4 Centros (`WERKS`) y almacenes (`LGORT`)

| Centro | Rol | Almacenes de daño (`V111`/`V112` + extras) |
|---|---|---|
| `TCDS` | Logística / crossdocking RM — cuenta como despacho normal en fill rate | `V111`, `V112` |
| `TCDC` | Logística | `V111`, `V112` |
| `TCD2` | Logística (⚠ **excluido** en `ventas_stocks_ventas` — no debe considerarse, quedó por copia de otro script) | `V111`, `V112` |
| `TCD4` | Logística | `V111`, `V112` |
| `TCP1` | Producción (⚠ **excluido** en `ventas_stocks_ventas` de zona traspaso/operaciones) | `A035`, `PAS2`, `PM31`, `V111`, `V112` |
| `TCP5` | Producción | `A035`, `V111`, `V112` |
| `TCP7` | Producción — caso especial: `LGORT IN ('V001','V004')` cuenta como **logística**, `LGORT LIKE 'PPT%'/'PAP%'` cuenta como **producción** | `A035`, `PLV1`, `V111`, `V112` |

Patrones de `LGORT` recurrentes:
- `PPT%` = zona de traspaso (producción casi terminada, previo a logística)
- `PAP%` = operaciones / producción casi terminada
- Fuera de esos dos patrones y sin ser `V111`/`V112`, el residual **se ignora** (no se
  inventa un 4º cubo — decisión explícita en `fillrate_etapa2`/`fillrate_etapa3`)
- `V00E` visto en `TCDS` con stock real (material `MUESTRARIORP`) — **no mapeado a
  ninguna whitelist todavía**, pendiente decidir si es almacén válido o cuarentena/error
  de maestro (ver `ventas_stocks_ventas`)

> [!note] "Disponible" no siempre significa lo mismo
> `fillrate_etapa2` considera disponible la suma de zona de traspaso + operaciones +
> logística. `fillrate_etapa3` (causa raíz) es **más estricto**: solo el cubo
> `distribucion` (logística) cuenta como disponible real — zona de traspaso/producción
> cuentan aparte como sub-causa `ESTADO_NO_DISPONIBLE`. Son dos criterios **a propósito
> distintos**, no un bug — confirmar cuál aplica según la pregunta de negocio antes de
> reutilizar un query de otro proyecto.

### 3.5 Clientes "fillrate" (4 KUNNR)

Grupo de 4 clientes sujetos a control de fill rate, usado como filtro/segmento en
`fillrate_2026`, `fillrate_etapa2`, `ventas_cl`:

```
3000337000, 3002650000, 3000061000, 3000006000
```
(SODIMAC, IMPERIAL, CONSTRUMART, EASY RETAIL — metas de fill rate distintas por cliente,
ver `fillrate_etapa3/CLAUDE.md`)

### 3.6 Vigencia del pedido y `GWLDT` corrupto

Regla repetida en `fillrate_etapa2`, `fillrate_etapa3`, `ventas_cl`:

- Si hay `GWLDT` (fecha de garantía SAP) → usarla, con **corrección de typo de año
  2027→2026**.
- `GWLDT_Ajustado` solo se acepta si `>= Fecha_Creacion` **y**
  `DATE_DIFF(GWLDT_Ajustado, Fecha_Creacion, DAY) <= 360`; si no cumple, cae al fallback.
- Fallback siempre: `ERDAT + 60 días`.

> [!bug] `GWLDT` corrupto — casos reales encontrados
> Pedido creado 2018-02-01 con `GWLDT=2108-02-28`; otros con años 2048 y 2201. Sin el
> guardrail de plausibilidad, estos pedidos aparecían como "vigentes" años después de
> creados.

### 3.7 Moneda CLP — factor x100

`NETWR`/`MWSBP` (y cualquier campo monetario en CLP) vienen con **2 decimales de más**
en SAP (comportamiento estándar para monedas sin decimales). Multiplicar por 100 para
obtener el valor real. Verificado exacto en `log_gastotrans` (`2864.88 × 100 = 286488`
CLP) y aplicado igual en `ventas_cl` (`VBAP.NETWR`).

### 3.8 Dominios de campo confirmados (no adivinar)

| Campo | Tabla | Valores confirmados | Fuente |
|---|---|---|---|
| `VBUK.CMGST` (status crédito) | `vbuk` | `A`=OK, `B`=Bloqueado, `D`=Liberado, `''`(blanco)=no documentado (~237 casos) | `ventas_cl`, `log_fillrate_etapa4` |
| `VBAK.LIFSK` (bloqueo entrega) | `vbak` | `'08'`=Kanban (bloqueo comercial), `'10'`=Aprobar descuento manual | `log_fillrate_etapa4` |
| `MARC.PRENO` | `marc` | `P`=a pedido (+20d horizonte), `S`=a stock (0d), `D`=obsoleto (0d, también usado como flag de Obsolescencia en `prov_inventarios`), `NULL`=tratar como `P` (conservador) | `fillrate_etapa2`, `prov_inventarios` — **dominio real aún no validado al 100% en BQ, puede haber códigos fuera de estos 4** |
| `VBTYP_N` | `vbfa` | ver tabla 3.1 | — |
| `TIPDOC` (`zconfol`) | `sap_fi.zconfol` | `'GDE'`=guía de despacho (mayoritario), `'FAE'`=factura, + códigos mexicanos `FMXM`/`FMXD`/`FMXT` mezclados (34 códigos en total) | `gv_rechazos_cl` |

## 4. `zconfol` — tabla multi-país, ojo al filtrar

`aecorsoft.sap_fi.zconfol` es una tabla **custom**, no estándar SAP, que mezcla folio
fiscal de **Chile** (`NFOLIO`, terminología DTE) y **México** (`UUID`/`FECHA_TIMBRADO`,
terminología CFDI/timbrado SAT) en el mismo esquema. Para proyectos `CL11`/`CL19`
interesa `NFOLIO`, nunca `UUID`. Join típico:

- Guía de despacho: `ZCONFOL.NSAP = Entrega` AND `TIPDOC='GDE'`
- Factura: `ZCONFOL.NSAP = Factura` AND `TIPDOC='FAE'` (confirmado vía `VBRK.XBLNR = 'FE:' + ZCONFOL.NFOLIO`)

## 5. Tablas de salida propias — dataset `Procesos_CDS`

Tablas generadas por los propios scripts del repo (no réplicas SAP), consumidas por
Looker Studio / Tableau o por otros scripts del repo:

| Tabla | Generada por | Grano | Consumida por |
|---|---|---|---|
| `stock_diario_backfill` | `fillrate_2026/inventario.sql` | `(matnr, werks, lgort, fecha)`, roll-backward desde `mard` | `fillrate_etapa3` (causa raíz) |
| `materiales_interes` | `fillrate_2026/materiales_interes.sql` | 1 columna (`matnr`), universo dinámico de pedidos ZPN | Acota `inventario.sql` y el cruce de causa raíz |
| `prov_inventarios_monitor_dano` | `prov_inventarios/sql/vistas/monitor_lotes_dano.sql` | 1 fila por lote en almacén de daño | Looker Studio |
| `prov_inventarios_monitor_obsoletos` | `prov_inventarios/sql/vistas/monitor_lotes_obsoletos.sql` | 1 fila por lote con `MARC.PRENO='D'` (whitelist de 37 `MTART`) | Looker Studio |
| `bloqueo_liberacion_credito_kanban` | (planeada, aún no subida) `log_fillrate_etapa4` — reconstruida desde `CDHDR`/`CDPOS` vía `SE16N` manual | `(ID_Documento, Campo, Fecha_Inicio, Fecha_Fin, ...)` | `fillrate_causa_raiz_bloqueo_comercial.sql` |

> [!bug] Riesgo de tabla desactualizada
> En `fillrate_etapa3` se detectó que `stock_diario_backfill` desplegada en BQ **no
> coincidía** con la versión vigente de `inventario.sql` (faltaban las columnas `_m3`).
> Antes de confiar en cualquier tabla de `Procesos_CDS`, verificar columnas vía
> `INFORMATION_SCHEMA.COLUMNS` — puede no reflejar la última versión del script que
> supuestamente la genera.

## 6. Índice de proyectos → qué dataset/tabla usa cada uno

| Proyecto | Pregunta de negocio | Tablas SAP clave | Salida | `CLAUDE.md` |
|---|---|---|---|---|
| `fillrate_2026` | Fill rate histórico ZPN/CL11, backfill de stock diario | `vbak`/`vbap`, `mard`, `mseg_full`/`mkpf` | `Procesos_CDS.stock_diario_backfill`, `materiales_interes` | — (sin `CLAUDE.md` propio; lógica base para etapa2/3) |
| `comercial_exportaciones` | Pedidos de exportación con m3 recalculado desde `VBAP` cuando la posición está bloqueada por crédito (`Credito='B'`) | `Comercial.Tabla_Pedidos_Exportacion`, `vbap`, `marm`/`mara` | `pedidos_exportacion_m3_bloqueo.sql` (columnas `Cta_ped_m3_b`, `origen_m3_b`) | — (sin `CLAUDE.md` propio) |
| `fillrate_etapa2` | Monitor forward-looking de cobertura stock vs. demanda, por Material | `vbak`/`vbap`, `mara`/`marm`/`mard`/`marc` | `llenado_capacidad.sql`, `detalle_pedidos_clientes.sql` (fuente Looker) | `fillrate_etapa2/CLAUDE.md` |
| `fillrate_etapa3` | Causa raíz backward-looking de líneas incumplidas | + `stock_diario_backfill` | `fillrate_analityc2026_causa_raiz.sql` | `fillrate_etapa3/CLAUDE.md` |
| `log_fillrate_etapa4` | ¿Cuánto del incumplimiento es bloqueo comercial/crédito, no falta de stock? | `CDHDR`/`CDPOS` (vía SE16N manual, no BQ) | `fillrate_causa_raiz_bloqueo_comercial.sql` | `log_fillrate_etapa4/CLAUDE.md` |
| `log_fillrate_etapa5` | Efecto del repaqueteo sobre fill rate | Excel exportado (fuente SAP no reconstruida aún) | análisis Python | `log_fillrate_etapa5/CLAUDE.md` |
| `prov_inventarios` | Provisión de deterioro (Daños/Obsoletos) vs. stock real por lote | `mchb`/`mcha`/`mch1`, `ckmlhd`/`ckmlcr` | `Procesos_CDS.prov_inventarios_monitor_dano/obsoletos` | `prov_inventarios/CLAUDE.md` |
| `ventas_cl` | Detalle de ventas + ciclo completo (vigencia, crédito, despacho, factura, NC/devolución) | `vbak`/`vbap`/`vbep`/`vbuk`/`vbpa`/`vbfa`/`vbrk`, `lips`, `mard` | `consulta_ventas_zpn_cl11.sql` | `ventas_cl/CLAUDE.md` |
| `ventas_stocks_ventas` | Stock por Material×Ubicación para Tableau (sin demanda) | `mara`/`mard`/`marc`/`marm` | `stock_ventas.sql` | `ventas_stocks_ventas/CLAUDE.md` |
| `gv_rechazos_cl` | Facturas rechazadas por cliente (folio fiscal, transporte) | `vbrp`/`vbrk`/`vbak`/`vbpa`, `vttp`/`vttk`, `zconfol` | `monitor_rechazos.sql` | `gv_rechazos_cl/CLAUDE.md` |
| `control_embarques` | Control de embarques + "potencial de transporte marítimo" | `ZCL_SD_DUS1`, `zsd_t_export` | placeholder | `control_embarques/CLAUDE.md` |
| `log_gastotrans` | Gasto de transporte por consolidador, HES a facturar | `vfkp`, `lfa1`, `ekko`/`ekpo` | `v_gasto_consolidador_ze18` | `log_gastotrans/CLAUDE.md` |
| `plan_fillrate_carolayn` | Por definir | — | — | `plan_fillrate_carolayn/CLAUDE.md` |
| `log_asignacion_optima` | Trazabilidad SAP, asignación óptima | `vttp`/`vttk` | dashboard HTML | sin `CLAUDE.md` propio |
| `log_lotes_antiguos` | Antigüedad de lote (Excel/pandas) | `mchb` (Excel) | `lotes_antiguedad.xlsx` | origen de `prov_inventarios/lotes_almacenes_dano.sql` |
| `log_fillrate_lotesabajo` | Fill rate desde exports Excel (`vbak`/`vbap`/`mara`/`marm`/`likp`/`lips`/`vttp`/`vttk`/`vekp`/`vepo`) | (Excel, no BQ directo) | — | sin `CLAUDE.md` propio |
| `plan_planmolduras` | Decisión de producción por línea (30 líneas activas, ver nota de memoria `project_lineas_activas`) | `mara` (Excel) | `decisiones_produccion.xlsx` | sin `CLAUDE.md` propio |
| `comex_facturacion` | Tiempo embarque→factura | `likp`/`vbfa`/`vbrk` (Excel) | `resultado_tiempo_embarque_factura.xlsx` | sin `CLAUDE.md` propio |
| `papeles_hugo` | Exploratorio — origen de `sap_sd.t005t` | `t005t` | — | sin `CLAUDE.md` propio |

## 7. Huecos de replicación conocidos (no perder tiempo re-descubriéndolos)

| Gap | Estado | Workaround activo |
|---|---|---|
| `sap_co.ckmlcr` vacía | Confirmada en esquema, 0 filas en BQ | Consultar `SE16N` en SAP directo mientras no se resuelva |
| `CDHDR`/`CDPOS` no replicadas | Confirmado (búsqueda en 20 datasets de `aecorsoft`, `region-us`) | Extracción manual vía `SE16N` + Python (`log_fillrate_etapa4/analisis/`) |
| `VFKK` no replicada | Confirmado | Se omite `clase_gasto`, no se inventa valor |
| `TVAG`/`TVAGT` no replicadas | Confirmado | `Motivo_Rechazo` sin descripción, código crudo |
| `mchb` sin confirmar | Asumida por patrón (mismo dataset que `mara`/`marm`/`mard`) | Verificar antes de correr `lotes_almacenes_dano.sql` |
| `zsd_t_export` nombre sin confirmar 100% | Usado en queries de `control_embarques` | Confirmar contra catálogo real de `sap_sd` |

## 8. Notas de memoria local de Claude relacionadas

> [!note] No incluidas en este repositorio
> Estas notas viven en la memoria local de Claude de la máquina donde se generó el
> mapa, no en el repo. En una sesión nueva (p. ej. Claude Code en la web) no están
> disponibles: si su contenido es necesario, copiarlo a este archivo o al `CLAUDE.md`
> del subproyecto correspondiente.

- `reference_bq_datasets_sap` — mapa base dataset↔tabla (fuente de la sección 1)
- `project_lineas_activas` — líneas de producción activas (`plan_planmolduras`)
- `project_fillrate_etapa5_repaqueteo` — bug de `volumen_solicitado_m3` y análisis de repaqueteo
- `project_log_fillrate_etapa4_tableros_anexo` — tableros ejecutivos de cumplimiento

---

> [!todo] Mantenimiento de esta nota
> Cada vez que un `CLAUDE.md` de subproyecto confirme una tabla nueva, un dominio de
> campo nuevo, o corrija algo de aquí, actualizar la sección correspondiente. Esta nota
> es un resumen — si hay conflicto entre esta nota y un `CLAUDE.md` de proyecto, **gana
> el `CLAUDE.md`** (más detallado y con fecha de confirmación).
