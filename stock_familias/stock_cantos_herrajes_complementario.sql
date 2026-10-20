-- =============================================================================
-- Stock por material para nivel_2_familia:
-- 'Term. Cantos', 'Herrajes', 'Complementario'.
-- Lógica de stock: la misma del CTE stock_disponible de Ventas_Nac/ventas_nac.sql
-- (MARD.LABST, segmentado en zona traspaso / operaciones / logística por centro,
-- TCD2 excluido, V111/V112 excluidos de logística). Además de los m3 se exponen
-- las mismas cubetas en unidad base (MARA.MEINS): en herrajes/complementarios es
-- común que MARA.VOLUM venga vacío y el stock en m3 quede en 0.
-- Jerarquía Gescorp vía CABN/AUSP/CAWN/CAWNT (KLART='001'), mismo patrón que
-- Ventas_Nac / fillrate_etapa2.
-- =============================================================================

WITH

-- ============================================================
-- DIMENSIONES FÍSICAS DEL MATERIAL (MARA)
-- Normaliza volumen a M3 desde CDM (dm³) o CM3 (cm³) — copia de
-- Ventas_Nac (CTE 2), sin las columnas de peso.
-- ============================================================
dimensiones AS (
  SELECT
    MATNR,
    MEINS,
    CASE VOLEH
      WHEN 'CDM' THEN COALESCE(VOLUM, 0) / 1000.0
      WHEN 'CM3' THEN COALESCE(VOLUM, 0) / 1000000.0
      ELSE             COALESCE(VOLUM, 0)
    END AS volumen_unidad_m3
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mara`
),

-- ============================================================
-- CLASIFICACIÓN DE MATERIALES (SKU) — jerarquía Gescorp
-- ============================================================
cabn_sku AS (
  SELECT ATINN, ATNAM
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.cabn`
  WHERE ATNAM IN ('RG_FAMILIA', 'RG_SUBFAMILIA')
),

pivot_clasificacion AS (
  SELECT
    ausp.OBJEK                                                           AS material,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_FAMILIA'    THEN ausp.ATWRT END)  AS cod_nivel_2,
    MAX(CASE WHEN cabn_sku.ATNAM = 'RG_SUBFAMILIA' THEN ausp.ATWRT END)  AS cod_nivel_3
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

-- Materiales del universo: nivel 2 en las 3 familias pedidas (cae al código
-- crudo si no hay descripción traducida).
materiales_familia AS (
  SELECT
    cl.material                                                          AS Material,
    COALESCE(d2.descripcion, cl.cod_nivel_2)                             AS nivel_2_familia,
    COALESCE(d3.descripcion, cl.cod_nivel_3)                             AS nivel_3_subfamilia
  FROM pivot_clasificacion AS cl
  LEFT JOIN descripciones_sku AS d2
    ON d2.caracteristica = 'RG_FAMILIA'    AND d2.codigo = cl.cod_nivel_2
  LEFT JOIN descripciones_sku AS d3
    ON d3.caracteristica = 'RG_SUBFAMILIA' AND d3.codigo = cl.cod_nivel_3
  WHERE UPPER(TRIM(COALESCE(d2.descripcion, cl.cod_nivel_2)))
        IN ('TERM. CANTOS', 'HERRAJES', 'COMPLEMENTARIO')
),

-- ============================================================
-- STOCK DISPONIBLE POR MATERIAL (mismo patrón que Ventas_Nac /
-- llenado_capacidad.sql)
-- zonatraspaso/operaciones: TCP1/TCP5/TCP7, LGORT PPT%/PAP%.
-- logística segmentada por centro: tcdc incluye también el caso
-- especial TCP7 con LGORT V001/V004. TCD2 se excluye por completo
-- (error de copia conocido, no representa stock real). V111/V112
-- (almacenes de daño) se excluyen en los 3 centros logísticos.
-- Las columnas *_un repiten las mismas cubetas en unidad base.
-- ============================================================
stock_disponible AS (
  SELECT
    mard.MATNR                                             AS Material,
    -- Unidad base (MARA.MEINS)
    SUM(IF(
      mard.WERKS IN ('TCP1','TCP5','TCP7') AND mard.LGORT LIKE 'PPT%',
      mard.LABST, 0
    ))                                                     AS un_libres_zonatraspaso,
    SUM(IF(
      mard.WERKS IN ('TCP1','TCP5','TCP7') AND mard.LGORT LIKE 'PAP%',
      mard.LABST, 0
    ))                                                     AS un_libres_operaciones,
    SUM(IF(
      mard.WERKS = 'TCDS' AND mard.LGORT NOT IN ('V111','V112'),
      mard.LABST, 0
    ))                                                     AS un_logistica_tcds,
    SUM(IF(
      (mard.WERKS = 'TCDC' AND mard.LGORT NOT IN ('V111','V112'))
        OR (mard.WERKS = 'TCP7' AND mard.LGORT IN ('V001', 'V004')),
      mard.LABST, 0
    ))                                                     AS un_logistica_tcdc,
    SUM(IF(
      mard.WERKS = 'TCD4' AND mard.LGORT NOT IN ('V111','V112'),
      mard.LABST, 0
    ))                                                     AS un_logistica_tcd4,
    -- M3 (copia literal de Ventas_Nac)
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
  INNER JOIN materiales_familia AS mf ON mf.Material = mard.MATNR
  LEFT JOIN dimensiones AS d ON d.MATNR = mard.MATNR
  WHERE mard.WERKS IN ('TCP1','TCP5','TCP7','TCDS','TCDC','TCD4')
  GROUP BY 1
)

SELECT
  mf.nivel_2_familia,
  mf.nivel_3_subfamilia,
  st.Material,
  makt.MAKTX                                                             AS descripcion_material,
  d.MEINS                                                                AS UM_Base,
  d.volumen_unidad_m3,
  -- Sin volumen en MARA -> las columnas m3 quedan en 0; usar las *_un.
  IF(COALESCE(d.volumen_unidad_m3, 0) = 0, 'S', 'N')                     AS Sin_Volumen_MARA,

  -- Unidad base
  st.un_libres_zonatraspaso,
  st.un_libres_operaciones,
  st.un_logistica_tcds,
  st.un_logistica_tcdc,
  st.un_logistica_tcd4,
  st.un_logistica_tcds + st.un_logistica_tcdc + st.un_logistica_tcd4     AS UN_Disponible_Logistica,

  -- M3. M3_Disponible_Logistica = suma de los 3 centros logísticos (no
  -- incluye zonatraspaso/operaciones), igual que en Ventas_Nac.
  st.m3_libres_zonatraspaso,
  st.m3_libres_operaciones,
  st.m3_logistica_tcds,
  st.m3_logistica_tcdc,
  st.m3_logistica_tcd4,
  ROUND(st.m3_logistica_tcds + st.m3_logistica_tcdc + st.m3_logistica_tcd4, 3)
                                                                         AS M3_Disponible_Logistica
FROM stock_disponible AS st
INNER JOIN materiales_familia AS mf
  ON mf.Material = st.Material
LEFT JOIN dimensiones AS d
  ON d.MATNR = st.Material
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.makt` AS makt
  ON  makt.MATNR = st.Material
  AND makt.SPRAS = 'S'
-- Solo materiales con algún stock en las cubetas consideradas.
WHERE st.un_libres_zonatraspaso + st.un_libres_operaciones
    + st.un_logistica_tcds + st.un_logistica_tcdc + st.un_logistica_tcd4 > 0
ORDER BY mf.nivel_2_familia, mf.nivel_3_subfamilia, st.Material;
