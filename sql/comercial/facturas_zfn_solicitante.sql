-- =============================================================================
-- Facturas clase ZFN emitidas a un solicitante, desde enero 2024 a la fecha
--
-- Grano del resultado: 1 fila por factura (cabecera VBRK).
--
-- Parámetros: editar la CTE `parametros` (sin DECLARE, para poder guardar la
-- query como vista o usarla como fuente de Looker Studio).
--
-- Supuestos a validar:
--   - "Solicitante" = VBRK.KUNAG (interlocutor AG). KUNAG, KUNRG, FKSTO,
--     MWSBK y WAERK no están aún en MAPA_DATOS_BIGQUERY.md: confirmar con
--     `aecorsoft.sap_sd.INFORMATION_SCHEMA.COLUMNS` (table_name = 'vbrk').
--   - Se excluyen facturas anuladas (FKSTO = 'X'); ver `incluir_anuladas`.
--   - El tipo de las claves (VBELN, KUNAG, NSAP) no está confirmado (STRING o
--     INT64): se normalizan con CAST + LPAD al formato SAP de 10 dígitos.
--   - FKDAT puede venir como DATE o como STRING 'YYYYMMDD': se aceptan ambos.
--   - Montos en CLP x100 (MAPA_DATOS_BIGQUERY.md, sección 3.7).
--   - Folio fiscal: zconfol con TIPDOC = 'FAE' (sección 4 del mapa).
-- =============================================================================

WITH
parametros AS (
  SELECT
    '3000910000'      AS solicitante,
    'ZFN'             AS clase_factura,
    DATE '2024-01-01' AS fecha_desde,
    FALSE             AS incluir_anuladas
),

facturas_base AS (
  SELECT
    LPAD(CAST(k.VBELN AS STRING), 10, '0')              AS factura,
    k.FKART                                             AS clase_factura,
    COALESCE(
      SAFE_CAST(CAST(k.FKDAT AS STRING) AS DATE),
      SAFE.PARSE_DATE('%Y%m%d', CAST(k.FKDAT AS STRING))
    )                                                   AS fecha_factura,
    k.VKORG                                             AS organizacion_ventas,
    LPAD(CAST(k.KUNAG AS STRING), 10, '0')              AS solicitante,
    LPAD(CAST(k.KUNRG AS STRING), 10, '0')              AS responsable_pago,
    k.XBLNR                                             AS referencia,
    k.WAERK                                             AS moneda,
    SAFE_CAST(k.NETWR AS FLOAT64)                       AS netwr,
    SAFE_CAST(k.MWSBK AS FLOAT64)                       AS mwsbk,
    COALESCE(UPPER(TRIM(CAST(k.FKSTO AS STRING))) = 'X', FALSE) AS anulada
  FROM `aecorsoft.sap_sd.vbrk` AS k
  CROSS JOIN parametros AS prm
  WHERE k.FKART = prm.clase_factura
    AND LPAD(CAST(k.KUNAG AS STRING), 10, '0') = prm.solicitante
),

facturas AS (
  SELECT f.*
  FROM facturas_base AS f
  CROSS JOIN parametros AS prm
  WHERE f.fecha_factura BETWEEN prm.fecha_desde AND CURRENT_DATE()
    AND (prm.incluir_anuladas OR NOT f.anulada)
),

-- Pedido(s) de origen: una factura puede agrupar varios pedidos
pedidos_origen AS (
  SELECT
    LPAD(CAST(p.VBELN AS STRING), 10, '0')              AS factura,
    STRING_AGG(DISTINCT CAST(p.AUBEL AS STRING), ', ' ORDER BY CAST(p.AUBEL AS STRING)) AS pedidos_origen
  FROM `aecorsoft.sap_sd.vbrp` AS p
  WHERE LPAD(CAST(p.VBELN AS STRING), 10, '0') IN (SELECT factura FROM facturas)
  GROUP BY factura
),

folio_factura AS (
  SELECT
    LPAD(CAST(z.NSAP AS STRING), 10, '0')               AS factura,
    ANY_VALUE(z.NFOLIO)                                 AS folio_fiscal
  FROM `aecorsoft.sap_fi.zconfol` AS z
  WHERE z.TIPDOC = 'FAE'
    AND LPAD(CAST(z.NSAP AS STRING), 10, '0') IN (SELECT factura FROM facturas)
  GROUP BY factura
),

clientes AS (
  SELECT
    LPAD(CAST(c.KUNNR AS STRING), 10, '0')              AS kunnr,
    ANY_VALUE(c.NAME1)                                  AS nombre
  FROM `aecorsoft.sap_sd.kna1` AS c
  WHERE LPAD(CAST(c.KUNNR AS STRING), 10, '0') IN (SELECT solicitante FROM parametros)
  GROUP BY kunnr
)

SELECT
  f.factura,
  f.clase_factura,
  f.fecha_factura,
  f.organizacion_ventas,
  f.solicitante,
  c.nombre                                              AS nombre_solicitante,
  f.responsable_pago,
  po.pedidos_origen,
  f.referencia,
  ff.folio_fiscal,
  f.moneda,
  ROUND(f.netwr * IF(f.moneda = 'CLP', 100, 1), 2)             AS valor_neto,
  ROUND(f.mwsbk * IF(f.moneda = 'CLP', 100, 1), 2)             AS impuesto,
  ROUND((f.netwr + f.mwsbk) * IF(f.moneda = 'CLP', 100, 1), 2) AS valor_total,
  f.anulada
FROM facturas AS f
LEFT JOIN clientes       AS c  ON c.kunnr    = f.solicitante
LEFT JOIN pedidos_origen AS po ON po.factura = f.factura
LEFT JOIN folio_factura  AS ff ON ff.factura = f.factura
ORDER BY f.fecha_factura, f.factura;
