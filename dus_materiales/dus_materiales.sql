-- =============================================================================
-- dus_materiales — DUS1 enriquecido con clasificación de materiales (N2..N5)
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
  description = 'DUS1 con datos de materiales (N2-N5). Ventana: mes anterior, actual y próximo según etd. Se actualiza diariamente.'
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
)

SELECT
  d.*,
  m.N2,
  m.N3,
  m.N4,
  m.N5,
  CURRENT_TIMESTAMP() AS fecha_actualizacion
FROM dus AS d
LEFT JOIN materiales AS m
  ON d.matnr = m.MATNR
WHERE d.etd_fecha >= DATE_TRUNC(DATE_SUB(CURRENT_DATE('America/Santiago'), INTERVAL 1 MONTH), MONTH)  -- 1° del mes anterior
  AND d.etd_fecha <  DATE_TRUNC(DATE_ADD(CURRENT_DATE('America/Santiago'), INTERVAL 2 MONTH), MONTH); -- 1° del mes subsiguiente (excluido)
