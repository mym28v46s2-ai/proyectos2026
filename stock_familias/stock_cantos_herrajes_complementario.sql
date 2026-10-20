-- =============================================================================
-- Stock por material para materiales de tipo Z903 (MARA.MTART), con niveles
-- de clasificación 2 a 5.
-- Lógica de stock: cubetas logísticas del CTE stock_disponible de
-- Ventas_Nac/ventas_nac.sql (MARD.LABST por centro TCDS/TCDC/TCD4, TCD2
-- excluido, V111/V112 excluidos), administrado en unidad de medida base
-- (UMB, MARA.MEINS), sin conversión a m3.
-- Se excluyen los materiales obsoletos (stock_pedido='D') sin stock logístico.
-- Clasificación: sap_mm.ZRC_MM_REPORTE_MATERIALES (N2..N5), sin respaldo.
-- Materiales que no están en ZRC quedan con niveles NULL. Diagnóstico
-- 2026-10-20: ZRC cubre 990 de 991 Z903 con stock logístico.
-- =============================================================================

WITH

-- ============================================================
-- UNIVERSO DE MATERIALES: tipo de material Z903
-- ============================================================
materiales_z903 AS (
  SELECT
    MATNR                                                  AS Material,
    MEINS
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mara`
  WHERE MTART = 'Z903'
),

-- ============================================================
-- CLASIFICACIÓN — ZRC_MM_REPORTE_MATERIALES
-- ZRC trae ~29 filas repetidas por material. MARA guarda MATNR con
-- ceros a la izquierda: se normalizan ambos lados con LTRIM '0'.
-- Niveles en blanco pasan a NULL.
-- ~5% de los materiales tiene combinaciones N2..N5 distintas entre
-- filas: se toma la combinación más frecuente (no MAX por columna,
-- para no mezclar niveles de filas distintas).
-- ============================================================
clasificacion_zrc AS (
  SELECT
    LTRIM(TRIM(MATNR), '0')                                AS matnr_norm,
    NULLIF(TRIM(N2), '')                                 AS nivel_2,
    NULLIF(TRIM(N3), '')                                 AS nivel_3,
    NULLIF(TRIM(N4), '')                                 AS nivel_4,
    NULLIF(TRIM(N5), '')                                 AS nivel_5
  FROM `aecorsoft.sap_mm.ZRC_MM_REPORTE_MATERIALES`
  WHERE LTRIM(TRIM(MATNR), '0') IN (
    SELECT LTRIM(TRIM(Material), '0') FROM materiales_z903
  )
  GROUP BY 1, 2, 3, 4, 5
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY matnr_norm
    ORDER BY COUNT(*) DESC, nivel_2, nivel_3, nivel_4, nivel_5
  ) = 1
),

-- ============================================================
-- STOCK DISPONIBLE LOGÍSTICO POR MATERIAL (mismo patrón que
-- Ventas_Nac / llenado_capacidad.sql, sin zona traspaso ni operaciones)
-- Logística segmentada por centro: tcdc incluye también el caso
-- especial TCP7 con LGORT V001/V004. TCD2 se excluye por completo
-- (error de copia conocido, no representa stock real). V111/V112
-- (almacenes de daño) se excluyen en los 3 centros logísticos.
-- Cantidades en unidad base (MARA.MEINS).
-- ============================================================
stock_disponible AS (
  SELECT
    mard.MATNR                                             AS Material,
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
  INNER JOIN materiales_z903 AS mz ON mz.Material = mard.MATNR
  WHERE mard.WERKS IN ('TCDS','TCDC','TCD4','TCP7')
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
),

-- ============================================================
-- RESULTADO BASE — un registro por material Z903
-- ============================================================
resultado_base AS (
  SELECT
    zrc.nivel_2                                                          AS Nivel_2,
    zrc.nivel_3                                                          AS Nivel_3,
    zrc.nivel_4                                                          AS Nivel_4,
    zrc.nivel_5                                                          AS Nivel_5,
    mz.Material,
    makt.MAKTX                                                           AS descripcion_material,
    mz.MEINS                                                             AS UM_Base,
    -- Mismo campo que Ventas_Nac: MARC.PRENO del centro TCDS
    -- (P=a pedido, S=a stock, D=obsoleto).
    marc.PRENO                                                           AS stock_pedido,
    -- Cantidad mínima de pedido TCDC (MVKE.AUMNG, CL11 / canal 84), en UMB.
    cmp.AUMNG                                                            AS Cant_Min_Pedido_TCDC,
    COALESCE(st.un_logistica_tcds, 0)                                    AS un_logistica_tcds,
    COALESCE(st.un_logistica_tcdc, 0)                                    AS un_logistica_tcdc,
    COALESCE(st.un_logistica_tcd4, 0)                                    AS un_logistica_tcd4,
    -- Suma de los 3 centros logísticos, mismo criterio de disponible
    -- logístico que Ventas_Nac.
    COALESCE(st.un_logistica_tcds, 0)
      + COALESCE(st.un_logistica_tcdc, 0)
      + COALESCE(st.un_logistica_tcd4, 0)                                AS UN_Disponible_Logistica
  FROM materiales_z903 AS mz
  LEFT JOIN clasificacion_zrc AS zrc
    ON zrc.matnr_norm = LTRIM(TRIM(mz.Material), '0')
  LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.makt` AS makt
    ON  makt.MATNR = mz.Material
    AND makt.SPRAS = 'S'
  LEFT JOIN `aecorsoft.cdc_produccion_pp_cp50_01_new.marc` AS marc
    ON  marc.MATNR = mz.Material
    AND marc.WERKS = 'TCDS'
  LEFT JOIN stock_disponible AS st
    ON st.Material = mz.Material
  LEFT JOIN cantidad_minima_pedido AS cmp
    ON cmp.Material = mz.Material
)

SELECT *
FROM resultado_base
-- Excluye obsoletos (stock_pedido='D') sin stock logístico. Un 'D' con
-- stock se mantiene; stock_pedido NULL se trata como no obsoleto.
WHERE NOT (COALESCE(stock_pedido, '') = 'D' AND UN_Disponible_Logistica = 0)
ORDER BY Nivel_2, Nivel_3, Nivel_4, Nivel_5, Material;
