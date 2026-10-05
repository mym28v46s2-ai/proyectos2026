-- =============================================================================
-- Ventas_Nac — detalle de ventas nacionales ZPN / CL11 con ciclo completo
--
-- Grano del resultado: 1 fila por posición de pedido de venta (VBAK/VBAP),
-- AUART='ZPN', VKORG='CL11', creados desde 2026-01-01 hasta ayer (hora Chile).
--
-- Incluye: vigencia (GWLDT con guardrail), crédito, despacho (LIKP/LIPS),
-- factura, nota de crédito / devolución, jerarquía Gescorp, m3 de venta,
-- stock logístico por centro, demanda abierta por segmento de días,
-- cumplimiento por posición y por cabecera, y posicionamiento de stock por
-- zona logística.
-- =============================================================================

WITH

-- ============================================================
-- CTE 1: PEDIDOS ZPN/CL11 + CLIENTES (WE=destinatario mercadería,
-- RE=responsable de factura), mismas partner functions que
-- fillrate_etapa2/sql/consultas/detalle_pedidos_clientes.sql.
-- GWLDT_Ajustado corrige el typo de año (2027->2026) y limpia valores
-- centinela SAP.
-- ============================================================
pedidos_base AS (
  SELECT
    vbak.VBELN                                              AS ID_Documento,
    vbak.BSTNK                                               AS OC_Cliente,
    vbak.ERDAT                                              AS Fecha_Creacion,
    vbak.GWLDT                                              AS Fecha_Garantia,
    CASE
      WHEN vbak.GWLDT IS NULL
        OR CAST(vbak.GWLDT AS STRING) IN ('0001-01-01', '9999-12-31')
        THEN NULL
      WHEN EXTRACT(YEAR FROM vbak.GWLDT) = 2027
        THEN DATE_SUB(vbak.GWLDT, INTERVAL 1 YEAR)
      ELSE vbak.GWLDT
    END                                                     AS GWLDT_Ajustado,
    vbak.VDATU                                              AS Fecha_Entrega_Preferente,
    vbak.VKGRP                                              AS Grupo_Vendedores,
    vbak.VTWEG                                              AS Canal_Distribucion,
    vbak.SPART                                              AS Sector,
    vbak.LIFSK                                              AS Bloqueo_Entrega,
    vbuk.CMGST                                              AS Status_Credito,
    vbap.POSNR                                              AS Posicion,
    vbap.MATNR                                              AS Material,
    vbap.KWMENG                                             AS Cantidad_Venta,
    vbap.VRKME                                              AS UM_Venta,
    vbap.NETWR                                              AS Valor_Neto_Doc,
    vbap.ABGRU                                              AS Motivo_Rechazo,

    vbpa_we.KUNNR                                           AS Codigo_Destinatario_Mercaderia,
    kna1_we.NAME1                                           AS Nombre_Destinatario_Mercaderia,
    kna1_we.REGIO                                           AS Region,

    vbpa_re.KUNNR                                           AS Codigo_Responsable_Factura,
    kna1_re.NAME1                                           AS Nombre_Responsable_Factura,

    -- Cliente fillrate: mismo grupo de 4 clientes usado más abajo en
    -- Fecha_Vigencia/Categoria_Cumplimiento/Cliente_Fillrate.
    COALESCE(vbpa_re.KUNNR, '') IN (
      '3000337000', '3002650000', '3000061000', '3000006000'
    )                                                        AS Es_Cliente_Fillrate

  FROM `aecorsoft.sap_sd.vbak` AS vbak
  INNER JOIN `aecorsoft.sap_sd.vbap` AS vbap
    ON vbak.VBELN = vbap.VBELN

  LEFT JOIN `aecorsoft.sap_sd.vbpa` AS vbpa_we
    ON  vbak.VBELN    = vbpa_we.VBELN
    AND vbpa_we.PARVW = 'WE'
    AND vbpa_we.POSNR = '000000'

  LEFT JOIN `aecorsoft.sap_sd.vbpa` AS vbpa_re
    ON  vbak.VBELN    = vbpa_re.VBELN
    AND vbpa_re.PARVW = 'RE'
    AND vbpa_re.POSNR = '000000'

  LEFT JOIN `aecorsoft.sap_sd.kna1` AS kna1_we
    ON vbpa_we.KUNNR = kna1_we.KUNNR

  LEFT JOIN `aecorsoft.sap_sd.kna1` AS kna1_re
    ON vbpa_re.KUNNR = kna1_re.KUNNR

  -- VBUK.CMGST = status de crédito, traducido más abajo (A/B/D).
  LEFT JOIN `aecorsoft.sap_sd.vbuk` AS vbuk
    ON vbuk.VBELN = vbak.VBELN

  WHERE
      vbak.AUART = 'ZPN'
    AND vbak.VKORG = 'CL11'
    AND vbak.ERDAT >= '2026-01-01'
    AND vbak.ERDAT < CURRENT_DATE('America/Santiago')          -- excluye hoy: réplica diaria incompleta
    -- Excluye pedidos donde GWLDT = ERDAT (no aplica a pedidos sin GWLDT).
    AND (vbak.GWLDT IS NULL OR vbak.GWLDT != vbak.ERDAT)
),

-- Fecha_Vigencia: NO fillrate -> siempre ERDAT+60. Fillrate -> usa
-- GWLDT_Ajustado si es plausible (>= creación, <= 360 días), si no cae
-- al mismo fallback ERDAT+60 (mismo control que
-- fillrate_etapa2/llenado_capacidad.sql).
pedidos AS (
  SELECT
    *,
    CASE
      WHEN NOT Es_Cliente_Fillrate
        THEN DATE_ADD(Fecha_Creacion, INTERVAL 60 DAY)
      WHEN GWLDT_Ajustado IS NOT NULL
        AND GWLDT_Ajustado >= Fecha_Creacion
        AND DATE_DIFF(GWLDT_Ajustado, Fecha_Creacion, DAY) <= 360
        THEN GWLDT_Ajustado
      ELSE DATE_ADD(Fecha_Creacion, INTERVAL 60 DAY)
    END                                                     AS Fecha_Vigencia,

    -- Fecha preferente "efectiva": VDATU con fallback ERDAT+60.
    COALESCE(Fecha_Entrega_Preferente, DATE_ADD(Fecha_Creacion, INTERVAL 60 DAY))
                                                              AS Fecha_Entrega_Preferente_Efectiva,

    -- Zona logística por región del destinatario (WE), misma
    -- agrupación que fillrate_etapa2/detalle_pedidos_clientes.sql.
    CASE
      WHEN Region IN ('13', 'SA')                                       -- RM (SA: código de ingreso incorrecto, corresponde a RM)
        THEN 'Zona Metropolitana'
      WHEN Region IN ('03', '04')                                       -- Atacama, Coquimbo
        THEN 'Zona Norte Chico'
      WHEN Region IN ('15', '01', '17', '02')                           -- Arica, Tarapacá(x2), Antofagasta
        THEN 'Zona Norte Grande'
      WHEN Region IN ('05', '06', '18')                                 -- Valpo, O'Higgins(x2)
        THEN 'Zona Centro Norte'
      WHEN Region IN ('07', '19', '20', '08', '21')                     -- Maule(x2), Ñuble, Biobío(x2)
        THEN 'Zona Centro Sur'
      WHEN Region IN ('09', '22', '14', '10', '23')                     -- Araucanía(x2), Los Ríos, Los Lagos(x2)
        THEN 'Zona Sur'
      WHEN Region IN ('11', '24', '12', '16')                          -- Aysén(x2), Magallanes(x2)
        THEN 'Zona Austral'
      ELSE 'Región No Configurada'
    END                                                       AS Zona_Logistica
  FROM pedidos_base
),

-- Centro que abastece la zona: Metropolitana/Centro Norte -> TCDS;
-- resto de zonas -> pool combinado TCDC+TCD4. Región no configurada
-- queda NULL (no se mezcla en el grupo por defecto).
pedidos_con_centro AS (
  SELECT
    *,
    CASE
      WHEN Zona_Logistica IN ('Zona Metropolitana', 'Zona Centro Norte') THEN 'TCDS'
      WHEN Zona_Logistica = 'Región No Configurada' THEN NULL
      ELSE 'TCDC_TCD4'
    END                                                       AS Centro_Abastecedor
  FROM pedidos
),


-- ============================================================
-- CTE 2: DIMENSIONES FÍSICAS DEL MATERIAL (MARA)
-- Normaliza volumen a M3 desde CDM (dm³) o CM3 (cm³) — misma
-- lógica que fillrate_etapa2/sql/consultas/llenado_capacidad.sql
-- ============================================================
dimensiones AS (
  SELECT
    MATNR,
    CASE VOLEH
      WHEN 'CDM' THEN COALESCE(VOLUM, 0) / 1000.0
      WHEN 'CM3' THEN COALESCE(VOLUM, 0) / 1000000.0
      ELSE             COALESCE(VOLUM, 0)
    END AS volumen_unidad_m3,
    -- Peso por unidad base (MEINS) normalizado a kg según GEWEI
    -- (BRGEW/NTGEW/GEWEI confirmados en mara por el usuario,
    -- 2026-10-05). Unidad de peso no reconocida -> NULL (no se asume kg).
    BRGEW * CASE GEWEI
      WHEN 'KG' THEN 1
      WHEN 'G'  THEN 0.001
      WHEN 'TO' THEN 1000
      WHEN 'TON' THEN 1000
    END AS peso_bruto_unidad_kg,
    NTGEW * CASE GEWEI
      WHEN 'KG' THEN 1
      WHEN 'G'  THEN 0.001
      WHEN 'TO' THEN 1000
      WHEN 'TON' THEN 1000
    END AS peso_neto_unidad_kg
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mara`
),


-- ============================================================
-- CTE 2B: UNIDADES POR PAQUETE (MARM, MEINH='PAK')
-- UMREZ del registro PAK = piezas por paquete estándar. Base de la
-- metodología de repaqueteo (ver SELECT final).
-- ============================================================
unidades_paquete AS (
  SELECT
    MATNR,
    MAX(UMREZ)                                              AS Unidades_por_Paquete
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.marm`
  WHERE MEINH = 'PAK'
  GROUP BY MATNR
),


-- ============================================================
-- CTE 3: CLASIFICACIÓN DE MATERIALES (SKU) — jerarquía Gescorp
-- vía CABN/AUSP/CAWN/CAWNT, mismo patrón que fillrate_etapa2/
-- sql/consultas/llenado_capacidad.sql
-- ============================================================
cabn_sku AS (
  SELECT ATINN, ATNAM
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.cabn`
  WHERE ATNAM IN ('RG_FAMILIA', 'RG_SUBFAMILIA', 'RG_MARCA', 'RG_NIVELRG')
),
pivot_clasificacion AS (
  SELECT
    ausp.OBJEK                                                              AS material,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_FAMILIA'    THEN ausp.ATWRT END)    AS cod_nivel_2,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_SUBFAMILIA' THEN ausp.ATWRT END)    AS cod_nivel_3,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_MARCA'      THEN ausp.ATWRT END)    AS cod_nivel_4,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_NIVELRG'    THEN ausp.ATWRT END)    AS cod_nivel_6
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.ausp` AS ausp
  INNER JOIN cabn_sku ON ausp.ATINN = cabn_sku.ATINN
  WHERE ausp.KLART = '001'
  GROUP BY ausp.OBJEK
),
descripciones_sku AS (
  SELECT
    cabn_sku.ATNAM  AS caracteristica,
    cawn.atwrt      AS codigo,
    cawnt.atwtb     AS descripcion
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.cawn` AS cawn
  INNER JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.cawnt` AS cawnt
    ON  cawn.atinn = cawnt.atinn
    AND cawn.atzhl = cawnt.atzhl
  INNER JOIN cabn_sku ON cawn.atinn = cabn_sku.ATINN
  WHERE cawnt.spras = 'S'
),


-- ============================================================
-- CTE 4: DESCRIPCIÓN DEL MATERIAL (MAKT)
-- ============================================================
desc_material AS (
  SELECT MATNR, MAKTX AS descripcion_material
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.makt`
  WHERE SPRAS = 'S'
),


-- ============================================================
-- CTE 5: DESCRIPCIÓN DEL GRUPO DE VENDEDORES (TVGRT)
-- ============================================================
desc_grupo_vendedores AS (
  SELECT VKGRP, BEZEI AS descripcion_grupo_vendedores
  FROM `aecorsoft.sap_sd.tvgrt`
  WHERE SPRAS = 'S'
),


-- ============================================================
-- CTE 6: DESCRIPCIÓN DEL CANAL DE DISTRIBUCIÓN (TVTWT)
-- ============================================================
desc_canal AS (
  SELECT VTWEG, VTEXT AS descripcion_canal
  FROM `aecorsoft.sap_sd.tvtwt`
  WHERE SPRAS = 'S'
),


-- ============================================================
-- CTE 7: DESCRIPCIÓN DEL SECTOR / DIVISIÓN (TSPAT)
-- ============================================================
desc_sector AS (
  SELECT SPART, VTEXT AS descripcion_sector
  FROM `aecorsoft.sap_sd.tspat`
  WHERE SPRAS = 'S'
),


-- ============================================================
-- CTE 8: DESCRIPCIÓN DEL BLOQUEO DE ENTREGA (TVLST)
-- LIFSK (VBAK, bloqueo a nivel cabecera) comparte dominio de valores
-- con LIFSP (bloqueo de entrega/posición) — se describe con la misma
-- tabla de texto TVLST, cruzando LIFSK con la clave LIFSP.
-- ============================================================
desc_bloqueo_entrega AS (
  SELECT LIFSP, VTEXT AS descripcion_bloqueo_entrega
  FROM `aecorsoft.sap_sd.tvlst`
  WHERE SPRAS = 'S'
),


-- ============================================================
-- CTE 8B: OC DEL CLIENTE A NIVEL POSICIÓN (VBKD.BSTKD_E)
-- A nivel posición (POSNR real) y a nivel cabecera (POSNR='000000').
-- Fallback aplicado en resultado_base. VBKD.INCO1 (Incoterm) se lee
-- también de la fila de cabecera — 'CCR'/'CIR' identifican pedidos
-- donde el cliente retira la mercadería (agregado 2026-09-14, ver
-- Estado_Envio más abajo).
-- ============================================================
oc_cliente_vbkd_posicion AS (
  SELECT VBELN, POSNR, BSTKD_E
  FROM `aecorsoft.sap_sd.vbkd`
  WHERE POSNR != '000000'
),
oc_cliente_vbkd_cabecera AS (
  SELECT VBELN, BSTKD_E, INCO1
  FROM `aecorsoft.sap_sd.vbkd`
  WHERE POSNR = '000000'
),


-- ============================================================
-- CTE 8C: MAPA DE MOTIVOS DE RECHAZO (VBAP.ABGRU)
-- Sin tabla de texto replicada (TVAG/TVAGT no existen en aecorsoft.sap_sd)
-- — motivos configurados por cliente en SAP (OVAG), mapeo entregado
-- por el usuario. es_cierre marca los códigos que representan cierre
-- automático de SAP (fuente de Pedido_Cerrado/Categoria_Cierre).
-- Códigos '0'/'1' (un solo carácter): riesgo de padding no confirmado
-- en VBAP.ABGRU ('00'/'01'), mismo tipo de problema que MATNR.
-- ============================================================
motivo_rechazo_map AS (
  SELECT codigo, texto, es_cierre
  FROM UNNEST([
    STRUCT('70' AS codigo, 'Cierre'                                AS texto, TRUE  AS es_cierre),
    STRUCT('24' AS codigo, 'Cliente no recibe por contingencia'    AS texto, FALSE AS es_cierre),
    STRUCT('12' AS codigo, 'Precio erróneo'                        AS texto, FALSE AS es_cierre),
    STRUCT('17' AS codigo, 'Eliminado por cliente'                 AS texto, FALSE AS es_cierre),
    STRUCT('ZD' AS codigo, 'Bloqueo posición pedido'                AS texto, FALSE AS es_cierre),
    STRUCT('50' AS codigo, 'Operación por aclarar'                 AS texto, FALSE AS es_cierre),
    STRUCT('22' AS codigo, 'Documento ilegible'                    AS texto, FALSE AS es_cierre),
    STRUCT('20' AS codigo, 'Orden vencida'                         AS texto, TRUE  AS es_cierre),
    STRUCT('13' AS codigo, 'Flete erróneo'                         AS texto, FALSE AS es_cierre),
    STRUCT('55' AS codigo, 'Falta stock'                           AS texto, FALSE AS es_cierre),
    STRUCT('18' AS codigo, 'Embalaje no corresponde'               AS texto, FALSE AS es_cierre),
    STRUCT('57' AS codigo, 'Documento muy antiguo'                 AS texto, TRUE  AS es_cierre),
    STRUCT('15' AS codigo, 'Producto discontinuado'                AS texto, FALSE AS es_cierre),
    STRUCT('23' AS codigo, 'Documento duplicado'                   AS texto, FALSE AS es_cierre),
    STRUCT('11' AS codigo, 'Envío de reemplazo para el cliente'    AS texto, FALSE AS es_cierre),
    STRUCT('19' AS codigo, 'Error en condición de pago'            AS texto, FALSE AS es_cierre),
    STRUCT('0'  AS codigo, 'Asignado internamente por el sistema'  AS texto, FALSE AS es_cierre),
    STRUCT('10' AS codigo, 'Pedido de cliente improcedente'        AS texto, FALSE AS es_cierre),
    STRUCT('14' AS codigo, 'Producto sin stock'                    AS texto, FALSE AS es_cierre),
    STRUCT('ZN' AS codigo, 'Cambio de material por otro'           AS texto, FALSE AS es_cierre),
    STRUCT('ZE' AS codigo, 'Administrativo'                        AS texto, FALSE AS es_cierre),
    STRUCT('26' AS codigo, 'No consolidable'                       AS texto, FALSE AS es_cierre),
    STRUCT('1'  AS codigo, 'Fecha de entrega demasiado tarde'      AS texto, TRUE  AS es_cierre),
    STRUCT('ZH' AS codigo, 'Pedido test'                           AS texto, FALSE AS es_cierre)
  ])
),


-- ============================================================
-- CTE 9: PRIMERA FECHA DE REPARTO POR POSICIÓN (VBEP)
-- Equivalente a RV45A-ETDAT: fecha de la primera línea de
-- programación (ETENR) de cada posición.
-- ============================================================
primera_fecha_reparto AS (
  SELECT
    VBELN,
    POSNR,
    EDATU AS Primera_Fecha
  FROM `aecorsoft.sap_sd.vbep`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY VBELN, POSNR ORDER BY ETENR ASC) = 1
),


-- ============================================================
-- CTE 10: DESPACHO POR POSICIÓN (VBFA -> LIKP + LIPS)
-- VBTYP_N='J' identifica el flujo pedido->entrega.
-- Fecha_Creacion_Entrega = MIN(LIKP.ERDAT): primera entrega creada.
-- Fecha_Envio = MAX(WADAT_IST), fecha real de salida (no la planificada
-- WADAT); NULLIF limpia la fecha centinela 0001-01-01 que SAP usa
-- cuando aún no hay PGI (sin esto, Estado_Envio marcaba 'Despachado'
-- por error). Cantidad_Despachada = SUM(LIPS.LFIMG) vía POSNN, sin
-- conversión de unidad (asume misma UM que VRKME). LIPS vive en
-- sap_mm, no sap_sd. Con entregas parciales, Fecha_Creacion_Entrega y
-- Fecha_Envio pueden no venir del mismo documento LIKP.
-- ============================================================
despacho_posicion AS (
  SELECT
    vbfa.VBELV                                              AS VBELN,
    vbfa.POSNV                                              AS POSNR,
    MIN(likp.ERDAT)                                         AS Fecha_Creacion_Entrega,
    MAX(NULLIF(likp.WADAT_IST, DATE '0001-01-01'))          AS Fecha_Envio,
    SUM(lips.LFIMG)                                         AS Cantidad_Despachada
  FROM `aecorsoft.sap_sd.vbfa` AS vbfa
  INNER JOIN `aecorsoft.sap_sd.likp` AS likp
    ON likp.VBELN = vbfa.VBELN
  LEFT JOIN `aecorsoft.sap_mm.lips` AS lips
    ON  lips.VBELN = vbfa.VBELN
    AND lips.POSNR = vbfa.POSNN
  WHERE vbfa.VBTYP_N = 'J'
  GROUP BY vbfa.VBELV, vbfa.POSNV
),


-- ============================================================
-- CTE 11: FACTURA POR POSICIÓN (VBFA -> VBRK)
-- VBTYP_N='M' identifica el flujo pedido->factura. Con facturas
-- parciales se agrupan todos los números y se toma la fecha más
-- reciente. Tipos_Factura expone FKART crudo (~98 códigos custom, no
-- se puede distinguir factura real de NC/anulación sin confirmación
-- del usuario) — no filtra el flag Facturado.
-- ============================================================
factura_posicion AS (
  SELECT
    vbfa.VBELV                                              AS VBELN,
    vbfa.POSNV                                              AS POSNR,
    STRING_AGG(DISTINCT vbfa.VBELN, ', ')                   AS Numero_Factura,
    STRING_AGG(DISTINCT vbrk.FKART, ', ')                   AS Tipos_Factura,
    MAX(vbrk.FKDAT)                                         AS Fecha_Factura
  FROM `aecorsoft.sap_sd.vbfa` AS vbfa
  INNER JOIN `aecorsoft.sap_sd.vbrk` AS vbrk
    ON vbrk.VBELN = vbfa.VBELN
  WHERE vbfa.VBTYP_N = 'M'
  GROUP BY vbfa.VBELV, vbfa.POSNV
),


-- ============================================================
-- CTE 12: NOTA DE CRÉDITO Y DEVOLUCIÓN POR POSICIÓN (VBFA -> VBRK)
-- VBTYP_N='O' agrupa dos conceptos de negocio distintos, separados en
-- dos CTEs para no mezclar "ajuste de monto" con "mercadería devuelta":
--   FKART='ZNC'              -> nota de crédito pura
--   FKART IN ('ZDEV','ZDV1') -> devolución física
-- ============================================================
nota_credito_posicion AS (
  SELECT
    vbfa.VBELV                                              AS VBELN,
    vbfa.POSNV                                              AS POSNR,
    STRING_AGG(DISTINCT vbfa.VBELN, ', ')                   AS Numero_Nota_Credito,
    MAX(vbrk.FKDAT)                                         AS Fecha_Nota_Credito
  FROM `aecorsoft.sap_sd.vbfa` AS vbfa
  INNER JOIN `aecorsoft.sap_sd.vbrk` AS vbrk
    ON vbrk.VBELN = vbfa.VBELN
  WHERE vbrk.FKART = 'ZNC'
  GROUP BY vbfa.VBELV, vbfa.POSNV
),

devolucion_posicion AS (
  SELECT
    vbfa.VBELV                                              AS VBELN,
    vbfa.POSNV                                              AS POSNR,
    STRING_AGG(DISTINCT vbfa.VBELN, ', ')                   AS Numero_Devolucion,
    MAX(vbrk.FKDAT)                                         AS Fecha_Devolucion
  FROM `aecorsoft.sap_sd.vbfa` AS vbfa
  INNER JOIN `aecorsoft.sap_sd.vbrk` AS vbrk
    ON vbrk.VBELN = vbfa.VBELN
  WHERE vbrk.FKART IN ('ZDEV', 'ZDV1')
  GROUP BY vbfa.VBELV, vbfa.POSNV
),


-- ============================================================
-- CTE: STOCK DISPONIBLE POR MATERIAL (mismo patrón que llenado_capacidad.sql)
-- m3_libres_zonatraspaso/operaciones: TCP1/TCP5/TCP7, LGORT PPT%/PAP%.
-- m3_logistica se segmenta por centro: tcdc incluye también el caso
-- especial TCP7 con LGORT V001/V004. TCD2 se excluye por completo
-- (error de copia conocido, no representa stock real). V111/V112
-- (almacenes de daño) se excluyen en los 3 centros. M3_Disponible_
-- Logistica (en resultado_base) es solo la suma de los 3 centros
-- logísticos — zonatraspaso/operaciones quedan como auditoría.
-- ============================================================
stock_disponible AS (
  SELECT
    mard.MATNR                                             AS Material,
    ROUND(SUM(IF(
      mard.WERKS IN ('TCP1','TCP5','TCP7') AND mard.LGORT LIKE 'PPT%',
      mard.LABST * COALESCE(d.volumen_unidad_m3, 0), 0
    )), 3)                                                 AS m3_libres_zonatraspaso,
    ROUND(SUM(IF(
      mard.WERKS IN ('TCP1','TCP5','TCP7') AND mard.LGORT LIKE 'PAP%',
      mard.LABST * COALESCE(d.volumen_unidad_m3, 0), 0
    )), 3)                                                 AS m3_libres_operaciones,
    ROUND(SUM(IF(
      mard.WERKS = 'TCDS' AND mard.LGORT NOT IN ('V111','V112'),
      mard.LABST * COALESCE(d.volumen_unidad_m3, 0), 0
    )), 3)                                                 AS m3_logistica_tcds,
    ROUND(SUM(IF(
      (mard.WERKS = 'TCDC' AND mard.LGORT NOT IN ('V111','V112'))
        OR (mard.WERKS = 'TCP7' AND mard.LGORT IN ('V001', 'V004')),
      mard.LABST * COALESCE(d.volumen_unidad_m3, 0), 0
    )), 3)                                                 AS m3_logistica_tcdc,
    ROUND(SUM(IF(
      mard.WERKS = 'TCD4' AND mard.LGORT NOT IN ('V111','V112'),
      mard.LABST * COALESCE(d.volumen_unidad_m3, 0), 0
    )), 3)                                                 AS m3_logistica_tcd4
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mard` AS mard
  LEFT JOIN dimensiones AS d ON d.MATNR = mard.MATNR
  WHERE mard.WERKS IN ('TCP1','TCP5','TCP7','TCDS','TCDC','TCD4')
  GROUP BY 1
),


-- ============================================================
-- CTE: DEMANDA ABIERTA POR POSICIÓN, SEGMENTADA POR DÍAS
-- Califica como "abierta" lo mismo que llenado_capacidad.sql: vigente
-- hoy (Fecha_Vigencia >= CURRENT_DATE('America/Santiago')) y sin envío asignado. El
-- segmento (1-6) se mide sobre Fecha_Entrega_Preferente_Efectiva, no
-- Fecha_Vigencia — como la preferente es siempre <= vigencia, un
-- pedido puede seguir "abierto" con su fecha preferente ya vencida
-- (queda en el segmento más urgente, seg1, sin CASE aparte para
-- negativos). Se conserva Posicion porque se une por posición más
-- abajo, no solo por Material (ver demanda_abierta_material).
-- ============================================================
demanda_abierta_linea AS (
  SELECT
    p.ID_Documento,
    p.Posicion,
    p.Material,
    p.Centro_Abastecedor,
    p.Cantidad_Venta
      * COALESCE(mu.UMREZ / NULLIF(mu.UMREN, 0), 1)
      * COALESCE(d.volumen_unidad_m3, 0)                            AS m3_linea,
    CASE
      WHEN DATE_DIFF(p.Fecha_Entrega_Preferente_Efectiva, CURRENT_DATE('America/Santiago'), DAY) <= 7  THEN 1
      WHEN DATE_DIFF(p.Fecha_Entrega_Preferente_Efectiva, CURRENT_DATE('America/Santiago'), DAY) <= 15 THEN 2
      WHEN DATE_DIFF(p.Fecha_Entrega_Preferente_Efectiva, CURRENT_DATE('America/Santiago'), DAY) <= 30 THEN 3
      WHEN DATE_DIFF(p.Fecha_Entrega_Preferente_Efectiva, CURRENT_DATE('America/Santiago'), DAY) <= 45 THEN 4
      WHEN DATE_DIFF(p.Fecha_Entrega_Preferente_Efectiva, CURRENT_DATE('America/Santiago'), DAY) <= 60 THEN 5
      ELSE 6
    END                                                              AS segmento_dias
  FROM pedidos_con_centro AS p
  LEFT JOIN dimensiones AS d
    ON d.MATNR = p.Material
  LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.marm` AS mu
    ON  mu.MATNR = p.Material
    AND mu.MEINH = p.UM_Venta
  LEFT JOIN despacho_posicion AS desp
    ON  desp.VBELN = p.ID_Documento
    AND desp.POSNR = p.Posicion
  WHERE p.Fecha_Vigencia >= CURRENT_DATE('America/Santiago')
    AND desp.Fecha_Envio IS NULL
),

-- docs_demanda_abierta: conteo de documentos por Material.
-- m3_demanda_abierta_material_total: demanda total del material en
-- TODAS las zonas — base de "Cobertura_Red_Total" en
-- Categoria_Posicionamiento_Stock. Los m3 por segmento/posición NO se
-- leen de acá — se unen directo desde demanda_abierta_linea (ver
-- resultado_base) para que cada fila lleve su propio valor.
demanda_abierta_material AS (
  SELECT
    Material,
    COUNT(DISTINCT ID_Documento)                                                  AS docs_demanda_abierta,
    SUM(m3_linea)                                                                 AS m3_demanda_abierta_material_total
  FROM demanda_abierta_linea
  GROUP BY Material
),

-- ============================================================
-- CTE: DEMANDA ABIERTA POR MATERIAL Y CENTRO ABASTECEDOR
-- Demanda abierta (m3) por Material + Centro_Abastecedor, para medir
-- cobertura "donde se necesita" (excluye Centro_Abastecedor NULL).
-- ============================================================
demanda_abierta_centro_zona AS (
  SELECT
    Material,
    Centro_Abastecedor,
    SUM(m3_linea)                                                                 AS m3_demanda_centro_zona
  FROM demanda_abierta_linea
  WHERE Centro_Abastecedor IS NOT NULL
  GROUP BY Material, Centro_Abastecedor
),


-- ============================================================
-- CTE 13: RESULTADO BASE — todas las columnas finales excepto
-- Segmento_Dias_Vigencia (BigQuery no permite referenciar, dentro de
-- un mismo SELECT, un alias definido más arriba en ese mismo SELECT;
-- ese cálculo se separa al SELECT final, que sí puede leer las
-- columnas ya materializadas de este CTE).
-- ============================================================
resultado_base AS (
SELECT
  p.ID_Documento,
  p.OC_Cliente,
  -- OC a nivel posición, con fallback a la fila de cabecera si la
  -- posición no trae valor propio (distinta de OC_Cliente, siempre
  -- cabecera). Ver CTE 8B.
  COALESCE(ocp.BSTKD_E, occ.BSTKD_E)                                AS OC_Cliente_Posicion,
  -- Incoterm a nivel cabecera (VBKD.INCO1, POSNR='000000'). 'CCR'/'CIR'
  -- = cliente retira la mercadería — usado más abajo en Estado_Envio.
  occ.INCO1                                                         AS Incoterm_Cabecera,
  p.Fecha_Creacion,
  p.Fecha_Garantia,
  p.Fecha_Entrega_Preferente,
  p.Fecha_Entrega_Preferente_Efectiva,
  p.Fecha_Vigencia,
  DATE_DIFF(p.Fecha_Vigencia, CURRENT_DATE('America/Santiago'), DAY)                  AS Plazo_Restante,
  -- Días desde Fecha_Entrega_Preferente_Efectiva (positivo si ya
  -- pasó), usado para segmentar 'Atrasado en curso' más abajo.
  DATE_DIFF(CURRENT_DATE('America/Santiago'), p.Fecha_Entrega_Preferente_Efectiva, DAY) AS Dias_Atraso_Preferente,
  pfr.Primera_Fecha                                                 AS `1era Fecha`,
  desp.Fecha_Creacion_Entrega,
  desp.Fecha_Envio,
  desp.Cantidad_Despachada,
  -- Estado_Envio: 'Despachado' (tiene Fecha_Envio, sin importar el
  -- incoterm — si ya hubo salida real, prima ese hecho por sobre quién
  -- retira). 'Cliente retira' (agregado 2026-09-14): sin despacho aún,
  -- pero el incoterm de cabecera (VBKD.INCO1) es 'CCR'/'CIR' — la
  -- responsabilidad de transporte es del cliente, así que no aplica
  -- clasificarlo como 'Planificado'/'No planificado' (esos describen
  -- si la empresa organizó el despacho). 'Planificado' (entrega creada,
  -- aún sin salida real) o 'No planificado' (sin entrega creada) para
  -- el resto.
  CASE
    WHEN desp.Fecha_Envio IS NOT NULL THEN 'Despachado'
    WHEN occ.INCO1 IN ('CCR', 'CIR') THEN 'Cliente retira'
    WHEN desp.Fecha_Creacion_Entrega IS NOT NULL THEN 'Planificado'
    ELSE 'No planificado'
  END                                                                AS Estado_Envio,
  -- Días entre creación de la entrega y salida real; NULL si la
  -- posición no está 'Despachado'.
  DATE_DIFF(desp.Fecha_Envio, desp.Fecha_Creacion_Entrega, DAY)     AS Dias_Creacion_A_Despacho,
  -- Compara despacho real vs. Fecha_Entrega_Preferente_Efectiva, para
  -- todos los clientes (fillrate o no). 'No enviado' si ya pasó la
  -- preferente sin despacho; NULL si aún no pasa (no es incumplimiento
  -- todavía).
  CASE
    WHEN desp.Fecha_Envio IS NULL AND p.Fecha_Entrega_Preferente_Efectiva < CURRENT_DATE('America/Santiago') THEN 'No enviado'
    WHEN desp.Fecha_Envio IS NULL THEN NULL
    WHEN desp.Fecha_Envio <= p.Fecha_Entrega_Preferente_Efectiva THEN 'A tiempo'
    ELSE 'Atrasado'
  END                                                                AS Envio_A_Tiempo,

  -- Categoria_Cumplimiento: cruza envío + factura + cantidad despachada
  -- contra los plazos, con reglas distintas por segmento:
  --   Fillrate — plazo único (Fecha_Vigencia):
  --     'Cumplido'/'Cumple parcial' si envío+factura ocurrieron <= vigencia
  --     'Venta perdida' si la vigencia venció sin completar
  --     'Pendiente' en el resto
  --   No fillrate — dos plazos (preferente y vigencia):
  --     'Cumplido'/'Cumple parcial' si <= preferente
  --     'Cumplido con atraso' si el envío cae entre preferente y vigencia
  --     'Atrasado en curso' si pasó la preferente pero la vigencia sigue abierta
  --     'Venta perdida' si la vigencia venció sin completar
  --     'Pendiente' en el resto
  -- La comparación de cantidad usa solo LIPS.LFIMG vs Cantidad_Venta,
  -- sin conversión de unidad (ver nota en despacho_posicion).
  CASE
    WHEN p.Es_Cliente_Fillrate THEN
      CASE
        WHEN desp.Fecha_Envio IS NOT NULL
          AND fp.Fecha_Factura IS NOT NULL
          AND desp.Fecha_Envio <= p.Fecha_Vigencia
          THEN IF(COALESCE(desp.Cantidad_Despachada, 0) >= p.Cantidad_Venta, 'Cumplido', 'Cumple parcial')
        WHEN CURRENT_DATE('America/Santiago') > p.Fecha_Vigencia THEN 'Venta perdida'
        ELSE 'Pendiente'
      END
    ELSE
      CASE
        WHEN desp.Fecha_Envio IS NOT NULL
          AND fp.Fecha_Factura IS NOT NULL
          AND desp.Fecha_Envio <= p.Fecha_Entrega_Preferente_Efectiva
          THEN IF(COALESCE(desp.Cantidad_Despachada, 0) >= p.Cantidad_Venta, 'Cumplido', 'Cumple parcial')
        WHEN desp.Fecha_Envio IS NOT NULL
          AND fp.Fecha_Factura IS NOT NULL
          AND desp.Fecha_Envio > p.Fecha_Entrega_Preferente_Efectiva
          AND desp.Fecha_Envio <= p.Fecha_Vigencia
          THEN 'Cumplido con atraso'
        WHEN CURRENT_DATE('America/Santiago') > p.Fecha_Vigencia THEN 'Venta perdida'
        -- Espejo de 'Cumplido con atraso': ya pasó la preferente sin
        -- completar envío+factura, pero la vigencia sigue abierta.
        WHEN CURRENT_DATE('America/Santiago') > p.Fecha_Entrega_Preferente_Efectiva THEN 'Atrasado en curso'
        ELSE 'Pendiente'
      END
  END                                                                AS Categoria_Cumplimiento,

  fp.Numero_Factura,
  fp.Tipos_Factura,
  fp.Fecha_Factura,
  IF(fp.Fecha_Factura IS NOT NULL, 'S', 'N')                        AS Facturado,
  nc.Numero_Nota_Credito,
  nc.Fecha_Nota_Credito,
  IF(nc.Fecha_Nota_Credito IS NOT NULL, 'S', 'N')                   AS Tiene_Nota_Credito,
  dv.Numero_Devolucion,
  dv.Fecha_Devolucion,
  IF(dv.Fecha_Devolucion IS NOT NULL, 'S', 'N')                     AS Tiene_Devolucion,
  p.Grupo_Vendedores,
  dgv.descripcion_grupo_vendedores,
  p.Canal_Distribucion,
  dc.descripcion_canal,
  p.Sector,
  ds.descripcion_sector,
  p.Bloqueo_Entrega,
  dbe.descripcion_bloqueo_entrega,
  p.Status_Credito,
  -- CMGST: valores fijos de dominio SAP (confirmado A/B/D contra el
  -- pedido 0023328726), sin tabla de texto.
  CASE p.Status_Credito
    WHEN 'A' THEN 'OK'
    WHEN 'B' THEN 'Bloqueado'
    WHEN 'D' THEN 'Liberado'
    ELSE p.Status_Credito
  END                                                                AS descripcion_status_credito,
  p.Posicion,
  p.Motivo_Rechazo,
  -- Traducción vía motivo_rechazo_map; fallback al código crudo si no
  -- está mapeado.
  COALESCE(mr.texto, p.Motivo_Rechazo)                              AS descripcion_motivo_rechazo,
  -- 'S' si el motivo de rechazo es de tipo cierre (motivo_rechazo_map.es_cierre).
  IF(COALESCE(mr.es_cierre, FALSE), 'S', 'N')                        AS Pedido_Cerrado,
  -- Cruza el cierre automático contra despacho/cantidad — una posición
  -- cerrada puede igual tener despacho parcial/completo previo al
  -- cierre. NULL si no está cerrada.
  CASE
    WHEN COALESCE(mr.es_cierre, FALSE) AND desp.Fecha_Envio IS NULL
      THEN 'Cerrado sin despacho'
    WHEN COALESCE(mr.es_cierre, FALSE)
      AND COALESCE(desp.Cantidad_Despachada, 0) >= p.Cantidad_Venta
      THEN 'Cerrado con despacho completo'
    WHEN COALESCE(mr.es_cierre, FALSE)
      THEN 'Cerrado con despacho parcial'
    ELSE NULL
  END                                                                AS Categoria_Cierre,

  p.Codigo_Destinatario_Mercaderia,
  p.Nombre_Destinatario_Mercaderia,

  p.Codigo_Responsable_Factura,
  p.Nombre_Responsable_Factura,
  -- 'F' si el responsable de factura es uno de los 4 clientes fillrate.
  IF(p.Es_Cliente_Fillrate, 'F', NULL)                              AS Cliente_Fillrate,

  p.Material,
  dm.descripcion_material,
  COALESCE(d2.descripcion, cl.cod_nivel_2)                        AS nivel_2_familia,
  COALESCE(d3.descripcion, cl.cod_nivel_3)                        AS nivel_3_subfamilia,
  COALESCE(d4.descripcion, cl.cod_nivel_4)                        AS nivel_4_marca,
  COALESCE(d6.descripcion, cl.cod_nivel_6)                        AS nivel_6_nivelrg,
  marc.PRENO                                                      AS stock_pedido,
  marc.MAABC                                                      AS tipo_fillrate,

  p.Region,
  -- Ver pedidos_con_centro para el detalle de la agrupación región->
  -- zona y del mapeo zona->centro.
  p.Zona_Logistica,
  p.Centro_Abastecedor,
  -- Clase de camión asignada según el centro abastecedor, con su
  -- capacidad máxima en volumen (m3) y peso (kg):
  --   TCDS      -> clase '21': 17 m3 / 16.000 kg
  --   TCDC_TCD4 -> clase '20': 44 m3 / 28.000 kg
  -- NULL si Centro_Abastecedor es NULL (región no configurada).
  CASE p.Centro_Abastecedor
    WHEN 'TCDS'      THEN '21'
    WHEN 'TCDC_TCD4' THEN '20'
  END                                                               AS Clase_camion,
  CASE p.Centro_Abastecedor
    WHEN 'TCDS'      THEN 17
    WHEN 'TCDC_TCD4' THEN 44
  END                                                               AS max_vol,
  CASE p.Centro_Abastecedor
    WHEN 'TCDS'      THEN 16000
    WHEN 'TCDC_TCD4' THEN 28000
  END                                                               AS max_kg,

  p.Cantidad_Venta,
  p.UM_Venta,
  -- Piezas por paquete estándar (MARM.UMREZ con MEINH='PAK'). Ver CTE 2B.
  up.Unidades_por_Paquete,
  -- M3 = cantidad en UM venta -> UM base (MARM) x volumen unitario
  -- (MARA), misma fórmula que llenado_capacidad.sql.
  ROUND(
    p.Cantidad_Venta
      * COALESCE(mu.UMREZ / NULLIF(mu.UMREN, 0), 1)
      * COALESCE(d.volumen_unidad_m3, 0)
  , 3)                                                             AS M3_Venta,
  -- KG = cantidad en UM venta -> UM base (MARM) x peso por unidad base
  -- (MARA.BRGEW/NTGEW normalizado a kg en dimensiones). NULL si el
  -- material no tiene GEWEI reconocida. KG_Venta (bruto) es el que se
  -- compara contra max_kg del camión.
  ROUND(
    p.Cantidad_Venta
      * COALESCE(mu.UMREZ / NULLIF(mu.UMREN, 0), 1)
      * d.peso_bruto_unidad_kg
  , 3)                                                             AS KG_Venta,
  ROUND(
    p.Cantidad_Venta
      * COALESCE(mu.UMREZ / NULLIF(mu.UMREN, 0), 1)
      * d.peso_neto_unidad_kg
  , 3)                                                             AS KG_Neto_Venta,

  -- CLP es moneda de 0 decimales en SAP pero se almacena con 2
  -- decimales implícitos -> x100 para el valor real.
  ROUND(p.Valor_Neto_Doc * 100, 2)                                 AS Valor_Neto_CLP,

  -- Stock disponible por Material, crudo para auditoría.
  -- M3_Disponible_Logistica = suma de los 3 centros logísticos (no
  -- incluye zonatraspaso/operaciones).
  COALESCE(st.m3_libres_zonatraspaso, 0)                          AS m3_libres_zonatraspaso,
  COALESCE(st.m3_libres_operaciones, 0)                           AS m3_libres_operaciones,
  COALESCE(st.m3_logistica_tcds, 0)                                AS m3_logistica_tcds,
  COALESCE(st.m3_logistica_tcdc, 0)                                AS m3_logistica_tcdc,
  COALESCE(st.m3_logistica_tcd4, 0)                                AS m3_logistica_tcd4,
  ROUND(
    COALESCE(st.m3_logistica_tcds, 0)
    + COALESCE(st.m3_logistica_tcdc, 0)
    + COALESCE(st.m3_logistica_tcd4, 0)
  , 3)                                                              AS M3_Disponible_Logistica,

  -- Demanda abierta a nivel posición (m3 propio de esta fila, 0 si no
  -- califica) — a diferencia de m3_libres_*/m3_logistica_* (atributo
  -- de Material, repetido por fila): se agrega con SUM (no MAX) al
  -- construir una tabla por Material. docs_demanda_abierta sigue
  -- siendo un conteo por Material, se agrega con MAX.
  COALESCE(dam.docs_demanda_abierta, 0)                            AS docs_demanda_abierta,
  ROUND(COALESCE(dal.m3_linea, 0), 3)                              AS m3_demanda_abierta_total,
  ROUND(COALESCE(IF(dal.segmento_dias = 1, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg1,
  ROUND(COALESCE(IF(dal.segmento_dias = 2, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg2,
  ROUND(COALESCE(IF(dal.segmento_dias = 3, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg3,
  ROUND(COALESCE(IF(dal.segmento_dias = 4, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg4,
  ROUND(COALESCE(IF(dal.segmento_dias = 5, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg5,
  ROUND(COALESCE(IF(dal.segmento_dias = 6, dal.m3_linea, 0), 0), 3) AS m3_demanda_seg6,

  -- Cobertura por centro/zona: mide si el stock está "donde se
  -- necesita", no solo si existe en la red. Fuente de
  -- Categoria_Posicionamiento_Stock (calculada en el SELECT final,
  -- necesita estos alias ya materializados).
  --   Stock_Centro_Abastecedor: stock del centro/grupo que abastece
  --     esta zona, para este material.
  --   M3_Demanda_Abierta_Centro_Zona: demanda abierta del mismo
  --     material/grupo (ya agregada, repetida por fila).
  --   M3_Demanda_Abierta_Material_Total: demanda abierta total del
  --     material en TODAS las zonas — "Cobertura_Red_Total".
  CASE p.Centro_Abastecedor
    WHEN 'TCDS'      THEN COALESCE(st.m3_logistica_tcds, 0)
    WHEN 'TCDC_TCD4' THEN COALESCE(st.m3_logistica_tcdc, 0) + COALESCE(st.m3_logistica_tcd4, 0)
    ELSE NULL
  END                                                               AS Stock_Centro_Abastecedor,
  ROUND(COALESCE(dcz.m3_demanda_centro_zona, 0), 3)                AS M3_Demanda_Abierta_Centro_Zona,
  ROUND(COALESCE(dam.m3_demanda_abierta_material_total, 0), 3)     AS M3_Demanda_Abierta_Material_Total

FROM pedidos_con_centro AS p
LEFT JOIN dimensiones AS d
  ON d.MATNR = p.Material
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.marm` AS mu
  ON  mu.MATNR = p.Material
  AND mu.MEINH = p.UM_Venta
LEFT JOIN desc_material AS dm
  ON dm.MATNR = p.Material
LEFT JOIN desc_grupo_vendedores AS dgv
  ON dgv.VKGRP = p.Grupo_Vendedores
LEFT JOIN desc_canal AS dc
  ON dc.VTWEG = p.Canal_Distribucion
LEFT JOIN desc_sector AS ds
  ON ds.SPART = p.Sector
LEFT JOIN desc_bloqueo_entrega AS dbe
  ON dbe.LIFSP = p.Bloqueo_Entrega
LEFT JOIN oc_cliente_vbkd_posicion AS ocp
  ON  ocp.VBELN = p.ID_Documento
  AND ocp.POSNR = p.Posicion
LEFT JOIN oc_cliente_vbkd_cabecera AS occ
  ON occ.VBELN = p.ID_Documento
LEFT JOIN motivo_rechazo_map AS mr
  ON mr.codigo = p.Motivo_Rechazo
LEFT JOIN primera_fecha_reparto AS pfr
  ON  pfr.VBELN = p.ID_Documento
  AND pfr.POSNR = p.Posicion
LEFT JOIN despacho_posicion AS desp
  ON  desp.VBELN = p.ID_Documento
  AND desp.POSNR = p.Posicion
LEFT JOIN factura_posicion AS fp
  ON  fp.VBELN = p.ID_Documento
  AND fp.POSNR = p.Posicion
LEFT JOIN nota_credito_posicion AS nc
  ON  nc.VBELN = p.ID_Documento
  AND nc.POSNR = p.Posicion
LEFT JOIN devolucion_posicion AS dv
  ON  dv.VBELN = p.ID_Documento
  AND dv.POSNR = p.Posicion
LEFT JOIN pivot_clasificacion AS cl
  ON cl.material = p.Material
LEFT JOIN descripciones_sku AS d2
  ON d2.caracteristica = 'RG_FAMILIA'    AND d2.codigo = cl.cod_nivel_2
LEFT JOIN descripciones_sku AS d3
  ON d3.caracteristica = 'RG_SUBFAMILIA' AND d3.codigo = cl.cod_nivel_3
LEFT JOIN descripciones_sku AS d4
  ON d4.caracteristica = 'RG_MARCA'      AND d4.codigo = cl.cod_nivel_4
LEFT JOIN descripciones_sku AS d6
  ON d6.caracteristica = 'RG_NIVELRG'    AND d6.codigo = cl.cod_nivel_6
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.marc` AS marc
  ON  marc.MATNR = p.Material
  AND marc.WERKS = 'TCDS'
LEFT JOIN unidades_paquete AS up
  ON up.MATNR = p.Material
LEFT JOIN stock_disponible AS st
  ON st.Material = p.Material
LEFT JOIN demanda_abierta_material AS dam
  ON dam.Material = p.Material
LEFT JOIN demanda_abierta_centro_zona AS dcz
  ON  dcz.Material           = p.Material
  AND dcz.Centro_Abastecedor = p.Centro_Abastecedor
LEFT JOIN demanda_abierta_linea AS dal
  ON  dal.ID_Documento = p.ID_Documento
  AND dal.Posicion     = p.Posicion
),


-- ============================================================
-- CTE 14: CUMPLIMIENTO A NIVEL CABECERA — versión agregada por pedido
-- de Categoria_Cumplimiento, para un cálculo tipo Looker:
--   Sin nada entregado y aún vigente -> 'Pendiente'
--   Sin nada entregado y ya venció   -> 'Venta perdida'
--   Entregado menos de lo comprometido -> 'Cumple parcial'
--   Alguna posición con atraso        -> 'Cumplido con atraso'
--   Resto                             -> 'Cumplido'
-- Fecha_Vigencia es constante por pedido (se deriva de campos de
-- cabecera) — MAX() es solo para agregar, no cambia el valor.
-- M3_pedido = suma de M3_Venta de todas las posiciones del pedido;
-- max_vol también es constante por pedido (Centro_Abastecedor se
-- deriva de la región del destinatario WE de cabecera).
-- ============================================================
cumplimiento_cabecera AS (
  SELECT
    ID_Documento,
    MAX(Fecha_Vigencia)                                                 AS Fecha_Vigencia_Pedido,
    ROUND(SUM(COALESCE(M3_Venta, 0)), 3)                                AS M3_pedido,
    MAX(max_vol)                                                        AS max_vol_pedido,
    ROUND(SUM(COALESCE(KG_Venta, 0)), 3)                                AS KG_pedido,
    MAX(max_kg)                                                         AS max_kg_pedido,
    SUM(COALESCE(Cantidad_Despachada, 0))                               AS Unidades_Entregadas_Pedido,
    SUM(Cantidad_Venta)                                                 AS Unidades_Comprometidas_Pedido,
    LOGICAL_OR(Categoria_Cumplimiento IN ('Cumplido con atraso', 'Atrasado en curso')) AS Tiene_Atraso_Pedido
  FROM resultado_base
  GROUP BY ID_Documento
),


-- ============================================================
-- CTE 14B: BASE DE REPAQUETEO
-- Universo: tableros (nivel_2_familia 'Aglomerado'/'MDF' y
-- nivel_3_subfamilia 'Recubierto'/'Desnudo') vendidos en piezas
-- (UM_Venta='ST') con paquete estándar en MARM (PAK, ver CTE 2B).
-- Regla (aplicada en el SELECT final): la posición es estándar solo si
-- la cantidad es múltiplo exacto de las piezas por paquete (40 de 20 =
-- 2 paquetes); si no, hay que armar un paquete especial -> repaqueteo
-- (ej. 7 de 20, y también 10 de 20 = medio paquete). El resto se
-- calcula aquí una sola vez; columna auxiliar, se excluye del SELECT
-- final.
-- ============================================================
base_repaqueteo AS (
  SELECT
    *,
    COALESCE(
      UPPER(TRIM(nivel_2_familia))    IN ('AGLOMERADO', 'MDF')
      AND UPPER(TRIM(nivel_3_subfamilia)) IN ('RECUBIERTO', 'DESNUDO')
      AND UM_Venta = 'ST'
      AND Unidades_por_Paquete > 0
      AND Cantidad_Venta > 0,
      FALSE
    )                                                                   AS En_Universo_Repaqueteo,
    MOD(CAST(Cantidad_Venta AS NUMERIC), CAST(NULLIF(Unidades_por_Paquete, 0) AS NUMERIC)) AS Resto_Cantidad_Paquete
  FROM resultado_base
)


-- ============================================================
-- SELECT FINAL: agrega Segmento_Dias_Vigencia sobre resultado_base
-- ============================================================
SELECT
  rb.* EXCEPT (En_Universo_Repaqueteo, Resto_Cantidad_Paquete),
  -- Ver CTE cumplimiento_cabecera.
  CASE
    WHEN cc.Unidades_Entregadas_Pedido = 0 AND cc.Fecha_Vigencia_Pedido >= CURRENT_DATE('America/Santiago')
      THEN 'Pendiente'
    WHEN cc.Unidades_Entregadas_Pedido = 0
      THEN 'Venta perdida'
    WHEN cc.Unidades_Entregadas_Pedido < cc.Unidades_Comprometidas_Pedido
      THEN 'Cumple parcial'
    WHEN cc.Tiene_Atraso_Pedido
      THEN 'Cumplido con atraso'
    ELSE 'Cumplido'
  END                                                                AS Categoria_Cumplimiento_Cabecera,
  -- Ocupación del camión a nivel pedido: M3_pedido / max_vol de la
  -- clase de camión asignada (1 = camión lleno, > 1 = excede la
  -- capacidad). Valor repetido en todas las posiciones del pedido;
  -- NULL si no hay clase de camión (Centro_Abastecedor NULL).
  cc.M3_pedido,
  ROUND(SAFE_DIVIDE(cc.M3_pedido, cc.max_vol_pedido), 4)            AS Ocupacion_Camion,
  -- Igual que Ocupacion_Camion, pero por peso bruto: KG_pedido /
  -- max_kg. Posiciones sin peso (KG_Venta NULL) suman 0.
  cc.KG_pedido,
  ROUND(SAFE_DIVIDE(cc.KG_pedido, cc.max_kg_pedido), 4)             AS Ocupacion_Camion_KG,
  -- Dos escalas espejo según categoría: 'Atrasado en curso' usa escala
  -- negativa sobre Dias_Atraso_Preferente; 'Pendiente' usa escala
  -- positiva sobre Plazo_Restante. Resto queda NULL. Mismos cortes
  -- (7/15/30/45/60) en ambas, en el tramo más cercano a cero.
  CASE
    WHEN Categoria_Cumplimiento = 'Atrasado en curso' THEN
      CASE
        WHEN Dias_Atraso_Preferente <= 7  THEN '-7 a 0 días'
        WHEN Dias_Atraso_Preferente <= 15 THEN '-15 a -7 días'
        WHEN Dias_Atraso_Preferente <= 30 THEN '-30 a -15 días'
        WHEN Dias_Atraso_Preferente <= 45 THEN '-45 a -30 días'
        WHEN Dias_Atraso_Preferente <= 60 THEN '-60 a -45 días'
        ELSE 'Menos de -60 días'
      END
    WHEN Categoria_Cumplimiento = 'Pendiente' THEN
      CASE
        WHEN Plazo_Restante <= 7  THEN '0-7 días'
        WHEN Plazo_Restante <= 15 THEN '7-15 días'
        WHEN Plazo_Restante <= 30 THEN '15-30 días'
        WHEN Plazo_Restante <= 45 THEN '30-45 días'
        WHEN Plazo_Restante <= 60 THEN '45-60 días'
        ELSE 'Más de 60 días'
      END
    ELSE NULL
  END                                                                AS Segmento_Dias_Vigencia,

  -- Orden numérico para ordenar Segmento_Dias_Vigencia de peor a
  -- mejor: 1 = más atrasado, 12 = con más holgura.
  CASE
    WHEN Categoria_Cumplimiento = 'Atrasado en curso' THEN
      CASE
        WHEN Dias_Atraso_Preferente <= 7  THEN 6
        WHEN Dias_Atraso_Preferente <= 15 THEN 5
        WHEN Dias_Atraso_Preferente <= 30 THEN 4
        WHEN Dias_Atraso_Preferente <= 45 THEN 3
        WHEN Dias_Atraso_Preferente <= 60 THEN 2
        ELSE 1
      END
    WHEN Categoria_Cumplimiento = 'Pendiente' THEN
      CASE
        WHEN Plazo_Restante <= 7  THEN 7
        WHEN Plazo_Restante <= 15 THEN 8
        WHEN Plazo_Restante <= 30 THEN 9
        WHEN Plazo_Restante <= 45 THEN 10
        WHEN Plazo_Restante <= 60 THEN 11
        ELSE 12
      END
    ELSE NULL
  END                                                                AS Orden_Segmento_Dias_Vigencia,

  -- Compara M3_Venta de la posición contra el stock de TODA la red
  -- (M3_Disponible_Logistica). COALESCE a 0 para que un material sin
  -- registro en MARD caiga en 'Sin stock' en vez de quedar indefinido.
  CASE
    WHEN COALESCE(M3_Disponible_Logistica, 0) <= 0        THEN 'Sin stock'
    WHEN COALESCE(M3_Disponible_Logistica, 0) < M3_Venta  THEN 'Stock parcial'
    ELSE 'Stock disponible'
  END                                                                AS Categoria_Cobertura_Stock,

  -- A diferencia de Categoria_Cobertura_Stock (compara contra TODA la
  -- red), clasifica si el stock está "donde se necesita": cobertura
  -- del centro que abastece esta zona vs. cobertura de la red
  -- completa, para el mismo material. Umbral 50%, punto de partida a
  -- recalibrar contra atrasos/ventas perdidas reales.
  --   'Posicionado': el centro local cubre >= 50% de su demanda
  --     (incluye el caso sin demanda abierta ahí, ~1.5% de las filas)
  --   'Pendiente posicionar': el centro local cubre < 50%, pero la red
  --     completa sí cubre >= 50% — hay stock, está en el centro
  --     equivocado (problema de distribución, no de abastecimiento)
  --   'Sin stock total': ni el centro local ni la red completa cubren
  --     el 50% — problema de abastecimiento/producción
  CASE
    WHEN COALESCE(M3_Demanda_Abierta_Centro_Zona, 0) = 0
      THEN 'Posicionado'
    WHEN (Stock_Centro_Abastecedor / M3_Demanda_Abierta_Centro_Zona) < 0.5
      AND COALESCE(M3_Demanda_Abierta_Material_Total, 0) > 0
      AND (M3_Disponible_Logistica / M3_Demanda_Abierta_Material_Total) >= 0.5
      THEN 'Pendiente posicionar'
    WHEN (Stock_Centro_Abastecedor / M3_Demanda_Abierta_Centro_Zona) < 0.5
      THEN 'Sin stock total'
    ELSE 'Posicionado'
  END                                                                AS Categoria_Posicionamiento_Stock,

  -- Repaqueteo: ver CTE base_repaqueteo para el universo y la regla.
  IF(rb.En_Universo_Repaqueteo, 'S', 'N')                            AS Aplica_Repaqueteo,
  CASE
    WHEN NOT rb.En_Universo_Repaqueteo THEN NULL
    WHEN rb.Resto_Cantidad_Paquete = 0 THEN 'N'
    ELSE 'S'
  END                                                                AS Es_Repaqueteo,
  -- Versión numérica para medir % de repaqueteo (AVG/SUM por pedido):
  -- 1 = requiere repaqueteo; 0 = no requiere (estándar o fuera del
  -- universo evaluado). El denominador incluye todas las posiciones.
  IF(rb.En_Universo_Repaqueteo AND rb.Resto_Cantidad_Paquete != 0, 1, 0) AS Flag_Repaqueteo,
  IF(
    rb.En_Universo_Repaqueteo AND rb.Resto_Cantidad_Paquete != 0,
    CAST(TRUNC(CAST(rb.Cantidad_Venta AS NUMERIC) / rb.Unidades_por_Paquete) AS INT64),
    NULL
  )                                                                  AS Paquetes_Completos,
  IF(
    rb.En_Universo_Repaqueteo AND rb.Resto_Cantidad_Paquete != 0,
    rb.Resto_Cantidad_Paquete,
    NULL
  )                                                                  AS Piezas_Repaqueteo
FROM base_repaqueteo AS rb
LEFT JOIN cumplimiento_cabecera AS cc
  ON cc.ID_Documento = rb.ID_Documento
