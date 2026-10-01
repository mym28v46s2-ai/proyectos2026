-- =============================================================================
-- Tabla_Pedidos_Exportacion + Cta_ped_m3_b
--
-- Grano del resultado: el mismo de Tabla_Pedidos_Exportacion (1 fila por
-- posición del pedido de venta). No se agregan filas.
--
-- Filtro de período: solo posiciones con Fecha_Embarque_Comprometida desde
-- hace 6 meses (fecha de hoy en Chile - 6 meses) en adelante, incluidas las
-- fechas futuras. Las posiciones sin fecha (NULL o no interpretable) quedan
-- fuera.
--
-- Cta_ped_m3_b (redondeado a 3 decimales):
--   - Credito <> 'B'  -> igual a Ctd_Ped_m3.
--   - Credito =  'B'  -> (bloqueo de crédito) cantidad de la posición en
--     sap_sd.vbap (KWMENG, unidad VRKME) convertida a m3. Join por
--     Documento_de_ventas = VBELN y Posicion_Ped_Venta = POSNR.
--
-- Conversión a M3 (MAPA_DATOS_BIGQUERY.md, sección 3.2):
--   qty_base = KWMENG × UMREZ / UMREN        (MARM de la unidad de venta VRKME)
--   qty_m3   = qty_base × m3 por unidad base, en cascada:
--              MARM MEINH='M3' -> MARM 'DM3'/'CDM'/'L' (÷1000) -> MARM 'CM3'
--              (÷1 000 000) -> MARA.VOLUM/VOLEH
--
-- Supuestos a validar:
--   - Validar contra SAP (VA03) un pedido bloqueado antes de usar en
--     reportes: ver bug de volumen ~1000x en la sección 3.2 del mapa.
-- =============================================================================

WITH
parametros AS (
  SELECT DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 6 MONTH) AS fecha_desde
),

pedidos AS (
  SELECT
    t.*,
    LPAD(CAST(t.Documento_de_ventas AS STRING), 10, '0')           AS vbeln_join,
    LPAD(CAST(t.Posicion_Ped_Venta  AS STRING),  6, '0')           AS posnr_join,
    COALESCE(UPPER(TRIM(CAST(t.Credito AS STRING))) = 'B', FALSE)  AS es_bloqueo_credito
  FROM `aecorsoft.Comercial.Tabla_Pedidos_Exportacion` AS t
  -- Acepta DATE/DATETIME/TIMESTAMP, texto 'YYYY-MM-DD' o texto SAP 'YYYYMMDD'
  WHERE COALESCE(
          SAFE_CAST(t.Fecha_Embarque_Comprometida AS DATE),
          SAFE.PARSE_DATE('%Y%m%d', CAST(t.Fecha_Embarque_Comprometida AS STRING))
        ) >= (SELECT fecha_desde FROM parametros)
),

-- Solo los pedidos con alguna posición bloqueada, para acotar la lectura de VBAP
pedidos_bloqueados AS (
  SELECT DISTINCT vbeln_join AS vbeln
  FROM pedidos
  WHERE es_bloqueo_credito
),

posiciones AS (
  SELECT
    s.vbeln,
    LPAD(CAST(p.POSNR AS STRING), 6, '0')  AS posnr,
    p.MATNR                                AS matnr,
    p.VRKME                                AS vrkme,
    SAFE_CAST(p.KWMENG AS FLOAT64)         AS kwmeng
  FROM `aecorsoft.sap_sd.vbap` AS p
  JOIN pedidos_bloqueados AS s
    ON LPAD(CAST(p.VBELN AS STRING), 10, '0') = s.vbeln
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
)

SELECT
  p.* EXCEPT (vbeln_join, posnr_join, es_bloqueo_credito),
  ROUND(IF(p.es_bloqueo_credito, pm.qty_m3, p.Ctd_Ped_m3), 3) AS Cta_ped_m3_b,
  CASE
    WHEN NOT p.es_bloqueo_credito  THEN 'ORIGINAL'
    WHEN pm.vbeln IS NULL          THEN 'SIN_POSICION_VBAP'
    WHEN pm.qty_m3 IS NULL         THEN 'SIN_CONVERSION'
    ELSE pm.metodo_conversion_m3
  END                                                        AS origen_m3_b
FROM pedidos AS p
LEFT JOIN posiciones_m3 AS pm
  ON  pm.vbeln = p.vbeln_join
  AND pm.posnr = p.posnr_join
  AND p.es_bloqueo_credito
--WHERE p.vbeln_join = '1100168067'   -- validar un pedido puntual
