-- =============================================================================
-- dus_materiales — DUS1 enriquecido con clasificación de materiales (N2..N5)
-- y país de destino (zsd_t_export.bezei, cruzado por pedido: dus1.pedido = export.vbeln)
--
-- Salida: `aecorsoft.Procesos_CDS.dus_materiales` (particionada por etd_fecha,
-- cluster por matnr). Se actualiza diariamente.
--
-- Grano del resultado: el mismo de `sap_sd.zsd_t_dus1` (1 fila por fila DUS1),
-- con ventana de etd: mes anterior, mes actual y mes próximo (hora Chile).
-- =============================================================================

CREATE OR REPLACE TABLE `aecorsoft.Procesos_CDS.dus_materiales`
PARTITION BY etd_fecha
CLUSTER BY matnr
OPTIONS (
  description = 'DUS1 con datos de materiales (N2-N5) y país de destino. Ventana: mes anterior, actual y próximo según etd. Se actualiza diariamente.'
)
AS
WITH materiales AS (
  SELECT
    MATNR,
    N2,
    N3,
    N4,
    N5
  FROM `aecorsoft.sap_mm.ZRC_MM_REPORTE_MATERIALES`
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY MATNR
    ORDER BY
      -- Usa LAEDA; si está vacía o en ceros, usa ERSDA
      COALESCE(
        NULLIF(NULLIF(TRIM(CAST(LAEDA AS STRING)), ''), '00000000'),
        CAST(ERSDA AS STRING)
      ) DESC,
      CAST(ERSDA AS STRING) DESC   -- desempate por fecha de creación
  ) = 1
),

dus AS (
  SELECT
    *,
    -- Convierte etd a DATE, venga como DATE, 'YYYY-MM-DD' o 'YYYYMMDD'
    COALESCE(
      SAFE_CAST(CAST(etd AS STRING) AS DATE),
      SAFE.PARSE_DATE('%Y%m%d', CAST(etd AS STRING))
    ) AS etd_fecha
  FROM `aecorsoft.sap_sd.zsd_t_dus1`
),

-- País de destino por pedido desde zsd_t_export. Se deja 1 fila por pedido
-- (el bezei no vacío más frecuente) para no duplicar filas de DUS1.
-- El pedido está en export.vbeln y en dus1.pedido (no en dus1.vbeln); se
-- normalizan ceros a la izquierda y espacios en ambos lados.
pais_destino AS (
  SELECT
    LTRIM(TRIM(exp.vbeln), '0') AS pedido_norm,
    NULLIF(TRIM(exp.bezei), '') AS Pais_Destino
  FROM `aecorsoft.sap_sd.zsd_t_export` AS exp
  GROUP BY 1, 2
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY pedido_norm
    ORDER BY Pais_Destino IS NULL, COUNT(*) DESC, Pais_Destino
  ) = 1
)

SELECT
  d.*,
  m.N2,
  m.N3,
  m.N4,
  m.N5,
  p.Pais_Destino,
  CURRENT_TIMESTAMP() AS fecha_actualizacion
FROM dus AS d
LEFT JOIN materiales AS m
  ON d.matnr = m.MATNR
LEFT JOIN pais_destino AS p
  ON LTRIM(TRIM(d.pedido), '0') = p.pedido_norm
WHERE d.etd_fecha >= DATE_TRUNC(DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 1 MONTH), MONTH)  -- 1° del mes anterior
  AND d.etd_fecha <  DATE_TRUNC(DATE_ADD(CURRENT_DATE('America/Santiago'), INTERVAL 2 MONTH), MONTH); -- 1° del mes subsiguiente (excluido)
