-- =============================================================================
-- Lectura de `aecorsoft.Comercial.Tabla_Pedidos_Exportacion`
--
-- Dataset `Comercial` aún no documentado en MAPA_DATOS_BIGQUERY.md: el esquema
-- de esta tabla no está confirmado. Correr primero los pasos 1 y 2 y, con las
-- columnas reales, reemplazar el SELECT * del paso 3 por las columnas necesarias.
--
-- Dialecto: BigQuery Standard SQL. Cada paso se puede ejecutar por separado
-- (seleccionar el bloque en la consola y "Ejecutar selección").
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Paso 1: esquema de la tabla (columnas, tipo, nullable, partición)
-- Costo: mínimo, solo lee metadatos.
-- -----------------------------------------------------------------------------
SELECT
  ordinal_position,
  column_name,
  data_type,
  is_nullable,
  is_partitioning_column,
  clustering_ordinal_position
FROM `aecorsoft.Comercial.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'Tabla_Pedidos_Exportacion'
ORDER BY ordinal_position;


-- -----------------------------------------------------------------------------
-- Paso 2: metadatos de la tabla (tipo, filas, tamaño, última actualización)
-- Si table_type = 'VIEW', row_count y size_bytes vienen en 0/NULL: la vista
-- no almacena datos, lee de sus tablas de origen.
-- -----------------------------------------------------------------------------
SELECT
  t.table_name,
  t.table_type,
  s.row_count,
  ROUND(s.size_bytes / POW(1024, 2), 2)                    AS tamano_mb,
  TIMESTAMP_MILLIS(s.last_modified_time)                   AS ultima_modificacion
FROM `aecorsoft.Comercial.INFORMATION_SCHEMA.TABLES` AS t
LEFT JOIN `aecorsoft.Comercial.__TABLES__`             AS s
  ON s.table_id = t.table_name
WHERE t.table_name = 'Tabla_Pedidos_Exportacion';


-- -----------------------------------------------------------------------------
-- Paso 3: muestra de datos
-- Ojo: en BigQuery LIMIT NO reduce el costo, se cobra por las columnas leídas
-- de toda la tabla. Para revisar sin costo, usar la pestaña "Vista previa" de
-- la consola. Una vez conocido el esquema, listar solo las columnas necesarias
-- y, si la tabla está particionada (ver paso 1), filtrar por esa columna.
-- -----------------------------------------------------------------------------
SELECT *
FROM `aecorsoft.Comercial.Tabla_Pedidos_Exportacion`
LIMIT 100;


-- -----------------------------------------------------------------------------
-- Paso 4: un pedido puntual — Documento_de_ventas = 1100165556
-- El tipo de Documento_de_ventas no está confirmado (STRING o INT64): el CAST
-- a STRING hace que el filtro funcione en ambos casos. Si es STRING y viene con
-- ceros a la izquierda (formato SAP VBELN), no afecta: el valor ya tiene los
-- 10 dígitos. Una vez confirmado el tipo en el paso 1, se puede quitar el CAST.
-- -----------------------------------------------------------------------------
SELECT *
FROM `aecorsoft.Comercial.Tabla_Pedidos_Exportacion`
WHERE CAST(Documento_de_ventas AS STRING) = '1100165556';
