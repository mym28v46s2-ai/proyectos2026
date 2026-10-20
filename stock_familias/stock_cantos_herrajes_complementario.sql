-- =============================================================================
-- Stock por material, centro y almacén para nivel_2_familia:
-- 'Term. Cantos', 'Herrajes', 'Complementario'.
-- Fuente de stock: MARD.LABST (stock libre utilización, agregado, no por lote).
-- Jerarquía Gescorp vía CABN/AUSP/CAWN/CAWNT (KLART='001'), mismo patrón que
-- Ventas_Nac / fillrate_etapa2.
-- =============================================================================

WITH

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
)

SELECT
  mf.nivel_2_familia,
  mf.nivel_3_subfamilia,
  mard.MATNR                                                             AS Material,
  makt.MAKTX                                                             AS descripcion_material,
  mard.WERKS                                                             AS Centro,
  mard.LGORT                                                             AS Almacen,
  -- Almacenes de daño (sección 3.4 del mapa); se marcan en vez de excluirlos.
  IF(mard.LGORT IN ('V111', 'V112'), 'S', 'N')                           AS Almacen_Dano,
  mard.LABST                                                             AS Stock_Libre,
  mara.MEINS                                                             AS UM_Base
FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mard` AS mard
INNER JOIN materiales_familia AS mf
  ON mf.Material = mard.MATNR
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.mara` AS mara
  ON mara.MATNR = mard.MATNR
LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.makt` AS makt
  ON  makt.MATNR = mard.MATNR
  AND makt.SPRAS = 'S'
WHERE mard.LABST > 0
ORDER BY mf.nivel_2_familia, Material, Centro, Almacen;
