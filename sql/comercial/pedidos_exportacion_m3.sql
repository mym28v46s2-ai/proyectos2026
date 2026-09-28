-- =============================================================================
-- Tabla_Pedidos_Exportacion + m3 por posición del pedido de venta
--
-- Grano del resultado: 1 fila por posición de VBAP (Documento_de_ventas =
-- VBAK/VBAP.VBELN). Las columnas de Tabla_Pedidos_Exportacion (incluida
-- Ctd_Ped_m3, que es a nivel pedido) se repiten en cada posición.
--
-- Cta_ped_m3_b = m3 de la posición (redondeado a 3 decimales), calculado desde
-- SAP para TODOS los pedidos (no solo los que traen Ctd_Ped_m3 en 0), para poder
-- contrastar SUM(Cta_ped_m3_b) por pedido contra Ctd_Ped_m3 donde este sí viene.
--
-- Conversión a M3 (MAPA_DATOS_BIGQUERY.md, sección 3.2):
--   qty_base = KWMENG × UMREZ / UMREN        (MARM de la unidad de venta VRKME)
--   qty_m3   = qty_base × m3 por unidad base, en cascada:
--              MARM MEINH='M3' -> MARM 'DM3'/'CDM'/'L' (÷1000) -> MARM 'CM3'
--              (÷1 000 000) -> MARA.VOLUM/VOLEH
--
-- Supuestos a validar:
--   - Tabla_Pedidos_Exportacion tiene 1 fila por pedido. Si tiene 1 fila por
--     posición, agregar su columna de posición al join final con POSNR; si no,
--     las filas se multiplican (posiciones de la tabla × posiciones de VBAP).
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

-- Pedidos de la tabla, para acotar la lectura de VBAP
pedidos_vbeln AS (
  SELECT DISTINCT vbeln_join AS vbeln
  FROM pedidos
),

posiciones AS (
  SELECT
    s.vbeln,
    p.POSNR                         AS posnr,
    p.MATNR                         AS matnr,
    p.VRKME                         AS vrkme,
    SAFE_CAST(p.KWMENG AS FLOAT64)  AS kwmeng,
    p.ABGRU                         AS abgru
  FROM `aecorsoft.sap_sd.vbap` AS p
  JOIN pedidos_vbeln AS s
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
    p.matnr,
    p.kwmeng,
    p.vrkme,
    p.abgru,
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
)

SELECT
  p.* EXCEPT (vbeln_join),
  pm.posnr                 AS Posicion,
  pm.matnr                 AS Material,
  pm.kwmeng                AS Cantidad_pedido,
  pm.vrkme                 AS Unidad_venta,
  pm.abgru                 AS Motivo_rechazo,
  ROUND(pm.qty_m3, 3)      AS Cta_ped_m3_b,
  CASE
    WHEN pm.vbeln IS NULL           THEN 'SIN_POSICIONES_VBAP'
    WHEN pm.qty_m3 IS NULL          THEN 'SIN_CONVERSION'
    ELSE pm.metodo_conversion_m3
  END                      AS metodo_conversion_m3
FROM pedidos AS p
LEFT JOIN posiciones_m3 AS pm
  ON pm.vbeln = p.vbeln_join
-- WHERE p.vbeln_join = '1100165556'   -- validar un pedido puntual
ORDER BY p.vbeln_join, pm.posnr
;
