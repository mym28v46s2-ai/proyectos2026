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
-- estado_posicion: etapa de la posición. Las etapas son secuenciales; si una
-- posición cumple varias, gana la más avanzada (se evalúa de atrás hacia
-- adelante):
--   Rechazado        -> motivo de rechazo en SAP (VBAP.ABGRU no vacío) con
--                       el crédito NO bloqueado (Credito <> 'B'): decisión
--                       comercial de no suministrar. Prioridad máxima.
--   5. Enviado          -> Salmer = 'S' (salida de mercancía contabilizada;
--                          es lo que define el envío, con o sin Booking)
--   4. Envio programado -> Booking no vacío y Salmer <> 'S' (Booking = solo
--                          agendamiento de nave)
--                          Envíos terrestres (Nombre_de_Nave = 'Camion',
--                          p. ej. Chile -> Argentina) no llevan Booking: pasan
--                          directo a Enviado con Salmer = 'S', sin etapa de
--                          programado (confirmado por usuario 2026-10-08).
--   Bloqueo crédito  -> Credito = 'B' y aún no enviado/programado. El bloqueo
--                       de crédito en SAP pone ABGRU en las posiciones hasta
--                       que se gestione el desbloqueo: ese ABGRU NO es un
--                       rechazo real, y Ctd_Ped_m3 viene en 0 (ver
--                       Cta_ped_m3_b), por lo que no se evalúan las etapas
--                       de producción.
--   3. Producido        -> Vol_Producir_M3 = 0 o Estado_Pos IN ('CUMP','SOBR')
--   2. En producción    -> Estado_Pos = 'PEND' y Ctd_Ped_m3 > Vol_Producir_M3
--   1. Recibido         -> Estado_Pos = 'PEND' y Ctd_Ped_m3 <= Vol_Producir_M3
--                          (Fabricado = Ctd_Ped_m3 - Vol_Producir_M3 <= 0: nada
--                          fabricado; el negativo se trata como 0, igual que
--                          en Looker)
--   Sin estado          -> no cumple ninguna (p. ej. Vol_Producir_M3 NULL o
--                          Estado_Pos fuera de PEND/CUMP/SOBR)
-- Las posiciones Rechazado conservan su volumen (Cta_ped_m3_b); solo cambia
-- el estado.
--
-- estado_pedido (repetido en cada fila del pedido). Se consideran solo las
-- posiciones "válidas": se excluyen Rechazado y Sin estado.
--   Rechazado                              -> todas las posiciones rechazadas
--                                             (solo ocurre con crédito A/D)
--   Sin estado                             -> ninguna posición válida
--   Bloqueo crédito                        -> hay posiciones en Bloqueo crédito.
--                                             Un pedido liberado no se vuelve a
--                                             bloquear (confirmado por usuario
--                                             2026-10-08), así que un pedido
--                                             bloqueado no tiene envíos previos.
--   Enviado                  -> todas Enviado
--   Parcialmente enviado     -> alguna Enviado
--   Envio programado         -> todas Envio programado (o más avanzadas)
--   Parcialmente programado  -> alguna Envio programado
--   Producido                -> todas Producido (o más avanzadas)
--   Parcialmente producido   -> alguna Producido
--   En producción            -> alguna En producción, ninguna producida
--   Recibido                 -> todas Recibido
-- n_envios_pedido: envíos distintos con Salmer = 'S'. Un envío = Booking; si
--   no hay Booking (camión) = Nombre_de_Nave + Inic_pl_transporte.
-- Ultimo_inicio_viaje_pedido: fecha de inicio (Inic_pl_transporte) del último
--   viaje del pedido, repetida en todas sus filas. NULL si ningún viaje tiene
--   fecha.
-- pct_m3_enviado_pedido: m3 Enviado / m3 de posiciones válidas (sobre
--   Cta_ped_m3_b, fracción 0-1 para formato % en Looker).
--
-- Motivo_Rechazo_VBAP: código crudo de VBAP.ABGRU (TVAG/TVAGT no están
-- replicadas, sin descripción; ver sección 2.6 del mapa).
-- Los volúmenes se comparan redondeados a 3 decimales para evitar diferencias
-- de punto flotante. Usa Ctd_Ped_m3 original (no Cta_ped_m3_b).
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
    COALESCE(UPPER(TRIM(CAST(t.Credito AS STRING))) = 'B', FALSE)  AS es_bloqueo_credito,
    -- campos normalizados para estado_posicion
    UPPER(TRIM(CAST(t.Estado_Pos AS STRING)))                      AS estado_pos_norm,
    UPPER(TRIM(CAST(t.Salmer AS STRING)))                          AS salmer_norm,
    COALESCE(TRIM(CAST(t.Booking AS STRING)), '') <> ''            AS tiene_booking,
    ROUND(SAFE_CAST(t.Ctd_Ped_m3      AS FLOAT64), 3)              AS ctd_ped_m3_norm,
    ROUND(SAFE_CAST(t.Vol_Producir_M3 AS FLOAT64), 3)              AS vol_producir_m3_norm,
    -- identifica un envío: Booking, o nave + inicio de viaje si no hay Booking
    COALESCE(
      NULLIF(TRIM(CAST(t.Booking AS STRING)), ''),
      CONCAT('SIN_BOOKING|', COALESCE(TRIM(CAST(t.Nombre_de_Nave AS STRING)), ''),
             '|', COALESCE(CAST(t.Inic_pl_transporte AS STRING), ''))
    )                                                              AS envio_key
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

-- Posiciones rechazadas en SAP (VBAP.ABGRU), para todos los pedidos del período
posiciones_rechazadas AS (
  SELECT
    LPAD(CAST(v.VBELN AS STRING), 10, '0')  AS vbeln,
    LPAD(CAST(v.POSNR AS STRING),  6, '0')  AS posnr,
    TRIM(CAST(v.ABGRU AS STRING))           AS motivo_rechazo
  FROM `aecorsoft.sap_sd.vbap` AS v
  WHERE LPAD(CAST(v.VBELN AS STRING), 10, '0') IN (SELECT DISTINCT vbeln_join FROM pedidos)
    AND COALESCE(TRIM(CAST(v.ABGRU AS STRING)), '') <> ''
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
),

detalle_posicion AS (
  SELECT
    p.* EXCEPT (posnr_join, es_bloqueo_credito,
               estado_pos_norm, salmer_norm, tiene_booking,
               ctd_ped_m3_norm, vol_producir_m3_norm),
    ROUND(IF(p.es_bloqueo_credito, pm.qty_m3, p.Ctd_Ped_m3), 3) AS Cta_ped_m3_b,
    CASE
      WHEN NOT p.es_bloqueo_credito  THEN 'ORIGINAL'
      WHEN pm.vbeln IS NULL          THEN 'SIN_POSICION_VBAP'
      WHEN pm.qty_m3 IS NULL         THEN 'SIN_CONVERSION'
      ELSE pm.metodo_conversion_m3
    END                                                        AS origen_m3_b,
    r.motivo_rechazo                                           AS Motivo_Rechazo_VBAP,
    CASE
      WHEN r.motivo_rechazo IS NOT NULL
        AND NOT p.es_bloqueo_credito                         THEN 'Rechazado'
      WHEN p.salmer_norm = 'S'                               THEN 'Enviado'
      WHEN p.tiene_booking                                   THEN 'Envio programado'
      WHEN p.es_bloqueo_credito                              THEN 'Bloqueo crédito'
      WHEN p.vol_producir_m3_norm = 0
        OR p.estado_pos_norm IN ('CUMP', 'SOBR')             THEN 'Producido'
      WHEN p.estado_pos_norm = 'PEND'
        AND p.ctd_ped_m3_norm > p.vol_producir_m3_norm       THEN 'En producción'
      WHEN p.estado_pos_norm = 'PEND'
        AND p.ctd_ped_m3_norm <= p.vol_producir_m3_norm      THEN 'Recibido'
      ELSE 'Sin estado'
    END                                                        AS estado_posicion
  FROM pedidos AS p
  LEFT JOIN posiciones_m3 AS pm
    ON  pm.vbeln = p.vbeln_join
    AND pm.posnr = p.posnr_join
    AND p.es_bloqueo_credito
  LEFT JOIN posiciones_rechazadas AS r
    ON  r.vbeln = p.vbeln_join
    AND r.posnr = p.posnr_join
),

resumen_pedido AS (
  SELECT
    vbeln_join,
    COUNT(*)                                                         AS n_posiciones,
    COUNTIF(estado_posicion = 'Rechazado')                           AS n_rechazadas,
    COUNTIF(estado_posicion NOT IN ('Rechazado', 'Sin estado'))      AS n_validas,
    COUNTIF(estado_posicion = 'Bloqueo crédito')                     AS n_bloqueo,
    COUNTIF(estado_posicion = 'Enviado')                             AS n_enviadas,
    COUNTIF(estado_posicion = 'Envio programado')                    AS n_programadas,
    -- etapa 1..5 de las posiciones válidas sin bloqueo
    MIN(etapa)                                                       AS etapa_min,
    MAX(etapa)                                                       AS etapa_max,
    COUNT(DISTINCT IF(estado_posicion = 'Enviado', envio_key, NULL)) AS n_envios,
    SAFE_DIVIDE(
      SUM(IF(estado_posicion = 'Enviado', COALESCE(Cta_ped_m3_b, 0), 0)),
      SUM(IF(estado_posicion NOT IN ('Rechazado', 'Sin estado'), COALESCE(Cta_ped_m3_b, 0), 0))
    )                                                                AS pct_m3_enviado
  FROM (
    SELECT
      d.*,
      CASE d.estado_posicion
        WHEN 'Recibido'         THEN 1
        WHEN 'En producción'    THEN 2
        WHEN 'Producido'        THEN 3
        WHEN 'Envio programado' THEN 4
        WHEN 'Enviado'          THEN 5
      END AS etapa
    FROM detalle_posicion AS d
  )
  GROUP BY vbeln_join
)

SELECT
  d.* EXCEPT (vbeln_join, envio_key),
  CASE
    WHEN rp.n_validas = 0 AND rp.n_rechazadas = rp.n_posiciones THEN 'Rechazado'
    WHEN rp.n_validas = 0                                       THEN 'Sin estado'
    WHEN rp.n_bloqueo > 0                                       THEN 'Bloqueo crédito'
    WHEN rp.etapa_min = 5                                       THEN 'Enviado'
    WHEN rp.n_enviadas > 0                                      THEN 'Parcialmente enviado'
    WHEN rp.etapa_min = 4                                       THEN 'Envio programado'
    WHEN rp.n_programadas > 0                                   THEN 'Parcialmente programado'
    WHEN rp.etapa_min = 3                                       THEN 'Producido'
    WHEN rp.etapa_max >= 3                                      THEN 'Parcialmente producido'
    WHEN rp.etapa_max = 2                                       THEN 'En producción'
    ELSE 'Recibido'
  END                                                           AS estado_pedido,
  rp.n_envios                                                   AS n_envios_pedido,
  ROUND(rp.pct_m3_enviado, 4)                                   AS pct_m3_enviado_pedido,
  MAX(COALESCE(
        SAFE_CAST(d.Inic_pl_transporte AS DATE),
        SAFE.PARSE_DATE('%Y%m%d', CAST(d.Inic_pl_transporte AS STRING))
      )) OVER (PARTITION BY d.vbeln_join)                       AS Ultimo_inicio_viaje_pedido
FROM detalle_posicion AS d
LEFT JOIN resumen_pedido AS rp
  ON rp.vbeln_join = d.vbeln_join
--WHERE d.vbeln_join = '1100167396'   -- validar un pedido puntual
