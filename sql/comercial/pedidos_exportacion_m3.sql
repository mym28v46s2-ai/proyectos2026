-- =============================================================================
-- Tabla_Pedidos_Exportacion + columna Cta_ped_m3_b
--
-- Cta_ped_m3_b:
--   - Si Ctd_Ped_m3 trae valor (<> 0)  -> se copia tal cual.
--   - Si Ctd_Ped_m3 viene en 0 o NULL  -> suma de las posiciones del pedido de
--     venta (sap_sd.vbap, Documento_de_ventas = VBAK/VBAP.VBELN) convertidas a M3.
--
-- Conversión a M3 (MAPA_DATOS_BIGQUERY.md, sección 3.2):
--   qty_base = KWMENG × UMREZ / UMREN        (MARM de la unidad de venta VRKME)
--   qty_m3   = qty_base × m3 por unidad base, en cascada:
--              MARM MEINH='M3' -> MARM 'DM3'/'CDM'/'L' (÷1000) -> MARM 'CM3'
--              (÷1 000 000) -> MARA.VOLUM/VOLEH
--
-- Supuestos a validar:
--   - Cta_ped_m3_b es a nivel PEDIDO (todas las posiciones de VBAP). Si
--     Tabla_Pedidos_Exportacion tiene una fila por posición, hay que agregar
--     POSNR al join para no repetir el total del pedido en cada fila.
--   - Se incluyen posiciones rechazadas (ABGRU informado). Para excluirlas,
--     descomentar el filtro en el CTE `posiciones`.
--   - Validar contra SAP (VA03) con el pedido 1100165556 antes de usar en
--     reportes: ver bug de volumen ~1000x en la sección 3.2 del mapa.
-- =============================================================================

WITH
pedidos AS (
  SELECT
    t.*,
    LPAD(CAST(t.Documento_de_ventas AS STRING), 10, '0') AS vbeln_join
  FROM `aecorsoft.Comercial.Tabla_Pedidos_Exportacion` AS t
),

-- Solo los pedidos que necesitan recálculo, para acotar la lectura de VBAP
pedidos_sin_m3 AS (
  SELECT DISTINCT vbeln_join AS vbeln
  FROM pedidos
  WHERE COALESCE(Ctd_Ped_m3, 0) = 0
),

posiciones AS (
  SELECT
    s.vbeln,
    p.POSNR                         AS posnr,
    p.MATNR                         AS matnr,
    p.VRKME                         AS vrkme,
    SAFE_CAST(p.KWMENG AS FLOAT64)  AS kwmeng
  FROM `aecorsoft.sap_sd.vbap` AS p
  JOIN pedidos_sin_m3 AS s
    ON LPAD(CAST(p.VBELN AS STRING), 10, '0') = s.vbeln
  -- WHERE COALESCE(p.ABGRU, '') = ''   -- excluir posiciones rechazadas
),

marm AS (
  SELECT
    MATNR                          AS matnr,
    MEINH                          AS meinh,
    SAFE_CAST(UMREZ AS FLOAT64)    AS umrez,
    SAFE_CAST(UMREN AS FLOAT64)    AS umren
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.marm`
  WHERE MATNR IN (SELECT DISTINCT matnr FROM posiciones)
),

-- m3 por 1 unidad base, según cada nivel de la cascada
m3_por_unidad_base AS (
  SELECT
    m.matnr,
    MAX(IF(m.meinh = 'M3',                  SAFE_DIVIDE(m.umren, m.umrez),               NULL)) AS m3_marm_m3,
    MAX(IF(m.meinh IN ('DM3', 'CDM', 'L'),  SAFE_DIVIDE(m.umren, m.umrez) / 1000,        NULL)) AS m3_marm_dm3,
    MAX(IF(m.meinh = 'CM3',                 SAFE_DIVIDE(m.umren, m.umrez) / 1000000,     NULL)) AS m3_marm_cm3
  FROM marm AS m
  GROUP BY m.matnr
),

mara_vol AS (
  SELECT
    MATNR  AS matnr,
    MEINS  AS meins,
    CASE
      WHEN VOLEH = 'M3'                  THEN SAFE_CAST(VOLUM AS FLOAT64)
      WHEN VOLEH IN ('DM3', 'CDM', 'L')  THEN SAFE_CAST(VOLUM AS FLOAT64) / 1000
      WHEN VOLEH = 'CM3'                 THEN SAFE_CAST(VOLUM AS FLOAT64) / 1000000
    END AS m3_mara
  FROM `aecorsoft.cdc_produccion_pp_cp50_01_new.mara`
  WHERE MATNR IN (SELECT DISTINCT matnr FROM posiciones)
),

posiciones_m3 AS (
  SELECT
    p.vbeln,
    p.posnr,
    -- unidad de venta -> unidad base (si VRKME ya es la base y no hay MARM, factor 1)
    p.kwmeng * COALESCE(SAFE_DIVIDE(mv.umrez, mv.umren), IF(p.vrkme = ma.meins, 1, NULL))
      * COALESCE(u.m3_marm_m3, u.m3_marm_dm3, u.m3_marm_cm3, NULLIF(ma.m3_mara, 0)) AS qty_m3,
    CASE
      WHEN u.m3_marm_m3  IS NOT NULL THEN 'MARM_M3'
      WHEN u.m3_marm_dm3 IS NOT NULL THEN 'MARM_DM3'
      WHEN u.m3_marm_cm3 IS NOT NULL THEN 'MARM_CM3'
      WHEN NULLIF(ma.m3_mara, 0) IS NOT NULL THEN 'MARA_VOLUM'
      ELSE 'SIN_CONVERSION'
    END AS metodo_conversion_m3
  FROM posiciones AS p
  LEFT JOIN marm               AS mv ON mv.matnr = p.matnr AND mv.meinh = p.vrkme
  LEFT JOIN m3_por_unidad_base AS u  ON u.matnr  = p.matnr
  LEFT JOIN mara_vol           AS ma ON ma.matnr = p.matnr
),

m3_por_pedido AS (
  SELECT
    vbeln,
    SUM(qty_m3)                AS m3_sap,
    COUNTIF(qty_m3 IS NULL)    AS posiciones_sin_conversion
  FROM posiciones_m3
  GROUP BY vbeln
)

SELECT
  p.* EXCEPT (vbeln_join),
  IF(COALESCE(p.Ctd_Ped_m3, 0) <> 0, p.Ctd_Ped_m3, a.m3_sap) AS Cta_ped_m3_b,
  CASE
    WHEN COALESCE(p.Ctd_Ped_m3, 0) <> 0     THEN 'ORIGINAL'
    WHEN a.vbeln IS NULL                     THEN 'SIN_POSICIONES_VBAP'
    WHEN a.posiciones_sin_conversion > 0     THEN 'SAP_PARCIAL'   -- suma incompleta
    ELSE 'SAP_VBAP'
  END AS origen_m3_b
FROM pedidos AS p
LEFT JOIN m3_por_pedido AS a
  ON a.vbeln = p.vbeln_join
-- WHERE p.vbeln_join = '1100165556'   -- validar un pedido puntual
;
