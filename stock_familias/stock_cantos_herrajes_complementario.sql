-- =============================================================================
-- Stock por material para nivel_2_familia:
-- 'Term. Cantos', 'Herrajes', 'Complementario'.
-- Lógica de stock: la misma del CTE stock_disponible de Ventas_Nac/ventas_nac.sql
-- (MARD.LABST, segmentado en zona traspaso / operaciones / logística por centro,
-- TCD2 excluido, V111/V112 excluidos de logística), administrado en unidad de
-- medida base (UMB, MARA.MEINS), sin conversión a m3.
-- Jerarquía Gescorp vía CABN/AUSP/CAWN/CAWNT (KLART='001'), mismo patrón que
-- Ventas_Nac / fillrate_etapa2.
-- =============================================================================

WITH

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
-- Cantidades en unidad base (MARA.MEINS).
-- ============================================================
stock_disponible AS (
  SELECT
    mard.MATNR                                             AS Material,
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
    ))                                                     AS un_logistica_tcd4
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mard` AS mard
  INNER JOIN materiales_familia AS mf ON mf.Material = mard.MATNR
  WHERE mard.WERKS IN ('TCP1','TCP5','TCP7','TCDS','TCDC','TCD4')
  GROUP BY 1
),

-- ============================================================
-- CANTIDAD MÍNIMA DE PEDIDO (MVKE.AUMNG), en UMB.
-- MVKE no tiene centro (clave MATNR + VKORG + VTWEG): se toma el
-- área de ventas CL11 / canal 84, que es la que abastece TCDC.
-- Dataset sap_sd confirmado por el usuario (2026-10-20).
-- MAX por si la réplica trae duplicados de la clave.
-- ============================================================
cantidad_minima_pedido AS (
  SELECT
    MATNR                                                  AS Material,
    MAX(AUMNG)                                             AS AUMNG
  FROM `aecorsoft.sap_sd.mvke`
  WHERE VKORG = 'CL11'
    AND VTWEG = '84'
  GROUP BY MATNR
)

SELECT
  mf.nivel_2_familia,
  mf.nivel_3_subfamilia,
  st.Material,
  makt.MAKTX                                                             AS descripcion_material,
  mara.MEINS                                                             AS UM_Base,
  -- Cantidad mínima de pedido TCDC (MVKE.AUMNG, CL11 / canal 84), en UMB.
  cmp.AUMNG                                                              AS Cant_Min_Pedido_TCDC,

  st.un_libres_zonatraspaso,
  st.un_libres_operaciones,
  st.un_logistica_tcds,
  st.un_logistica_tcdc,
  st.un_logistica_tcd4,
  -- Suma de los 3 centros logísticos (no incluye zonatraspaso/operaciones),
  -- mismo criterio de disponible logístico que Ventas_Nac.
  st.un_logistica_tcds + st.un_logistica_tcdc + st.un_logistica_tcd4     AS UN_Disponible_Logistica
FROM stock_disponible AS st
INNER JOIN materiales_familia AS mf
  ON mf.Material = st.Material
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.mara` AS mara
  ON mara.MATNR = st.Material
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.makt` AS makt
  ON  makt.MATNR = st.Material
  AND makt.SPRAS = 'S'
LEFT JOIN cantidad_minima_pedido AS cmp
  ON cmp.Material = st.Material
-- Solo materiales con algún stock en las cubetas consideradas.
WHERE st.un_libres_zonatraspaso + st.un_libres_operaciones
    + st.un_logistica_tcds + st.un_logistica_tcdc + st.un_logistica_tcd4 > 0
ORDER BY mf.nivel_2_familia, mf.nivel_3_subfamilia, st.Material;
