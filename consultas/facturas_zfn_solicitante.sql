-- =============================================================================
-- Facturas clase ZFN emitidas a un solicitante, desde enero 2024 a la fecha
-- Dialecto: BigQuery Standard SQL — proyecto `aecorsoft`
--
-- Grano: 1 fila por factura (cabecera VBRK).
--
-- Supuestos a validar:
--   * "Solicitante" = VBRK.KUNAG (interlocutor AG). Este campo no aparece aún
--     en MAPA_DATOS_BIGQUERY.md; confirmar con INFORMATION_SCHEMA.COLUMNS.
--   * Se excluyen facturas anuladas (VBRK.FKSTO = 'X'). Para incluirlas,
--     cambiar el parámetro incluir_anuladas a TRUE.
--   * FKDAT puede venir como DATE o como STRING 'YYYYMMDD' según la réplica;
--     se normaliza en la CTE facturas_base.
--   * Montos en CLP se multiplican x100 (regla 3.7 del mapa).
-- =============================================================================

DECLARE solicitante      STRING  DEFAULT '3000910000';
DECLARE clase_factura    STRING  DEFAULT 'ZFN';
DECLARE fecha_desde      DATE    DEFAULT DATE '2024-01-01';
DECLARE incluir_anuladas BOOL    DEFAULT FALSE;

WITH facturas_base AS (
  SELECT
    vbrk.VBELN,
    vbrk.FKART,
    vbrk.VKORG,
    vbrk.KUNAG,
    vbrk.KUNRG,
    vbrk.XBLNR,
    vbrk.WAERK,
    vbrk.NETWR,
    vbrk.MWSBK,
    vbrk.FKSTO,
    COALESCE(
      SAFE_CAST(CAST(vbrk.FKDAT AS STRING) AS DATE),
      SAFE.PARSE_DATE('%Y%m%d', CAST(vbrk.FKDAT AS STRING))
    ) AS fecha_factura
  FROM `aecorsoft.sap_sd.vbrk` AS vbrk
  WHERE vbrk.FKART = clase_factura
    AND vbrk.KUNAG = solicitante
    AND (incluir_anuladas OR COALESCE(vbrk.FKSTO, '') <> 'X')
),

-- Pedido(s) de origen de cada factura (una factura puede agrupar varios)
pedidos_origen AS (
  SELECT
    vbrp.VBELN,
    STRING_AGG(DISTINCT vbrp.AUBEL, ', ' ORDER BY vbrp.AUBEL) AS pedidos_origen
  FROM `aecorsoft.sap_sd.vbrp` AS vbrp
  WHERE vbrp.VBELN IN (SELECT VBELN FROM facturas_base)
  GROUP BY vbrp.VBELN
),

-- Folio fiscal chileno de la factura (TIPDOC='FAE', ver sección 4 del mapa)
folio_factura AS (
  SELECT
    z.NSAP,
    ANY_VALUE(z.NFOLIO) AS folio_fiscal
  FROM `aecorsoft.sap_fi.zconfol` AS z
  WHERE z.TIPDOC = 'FAE'
  GROUP BY z.NSAP
)

SELECT
  f.VBELN                                   AS factura,
  f.FKART                                   AS clase_factura,
  f.fecha_factura,
  f.VKORG                                   AS organizacion_ventas,
  f.KUNAG                                   AS solicitante,
  cli.NAME1                                 AS nombre_solicitante,
  f.KUNRG                                   AS responsable_pago,
  p.pedidos_origen,
  f.XBLNR                                   AS referencia,
  ff.folio_fiscal,
  f.WAERK                                   AS moneda,
  f.NETWR * IF(f.WAERK = 'CLP', 100, 1)     AS valor_neto,
  f.MWSBK * IF(f.WAERK = 'CLP', 100, 1)     AS impuesto,
  (f.NETWR + f.MWSBK)
    * IF(f.WAERK = 'CLP', 100, 1)           AS valor_total,
  f.FKSTO = 'X'                             AS anulada
FROM facturas_base AS f
LEFT JOIN `aecorsoft.sap_sd.kna1` AS cli
  ON cli.KUNNR = f.KUNAG
LEFT JOIN pedidos_origen AS p
  ON p.VBELN = f.VBELN
LEFT JOIN folio_factura AS ff
  ON ff.NSAP = f.VBELN
WHERE f.fecha_factura BETWEEN fecha_desde AND CURRENT_DATE()
ORDER BY f.fecha_factura, f.VBELN;
