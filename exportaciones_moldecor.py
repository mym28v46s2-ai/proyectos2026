# -*- coding: utf-8 -*-
"""
Exportaciones de MOLDECOR (Chile) -- todas las familias de producto, sin el
filtro MDF/PB del pipeline beta, directo de Athena (cl_exp), 2019 a hoy.
Variante de exportaciones_mafor.py.

Filas incluidas: RUT 76209596 o 78744280 (normalizados, por si Athena los
trae como "xxxxxxxx.0") + filas cuyo importador/marca/variedad contiene
MOLDECOR, atribuidas por nombre/marca (columna `atribucion`).

Volumen y precio:
  - `volumen_m3` NO es un dato declarado: en MAFOR se comprobo que Athena
    lo deriva del peso neto con densidad fija (MOLDURAS 530 kg/m3; MDF
    560-810 segun espesor). Pendiente confirmar que vale igual para
    MOLDECOR. La cantidad declarada viene en unidades heterogeneas (LF,
    PIEZA, CAJA, PAQUETE...) y no sirve para sumar volumen.
  - Validacion: para filas en pies lineales con medidas parseables en la
    descripcion (mm x pulgadas) se compara el volumen geometrico con el
    de Athena (hoja "Validacion m3").
  - Precio: FOB/m3 (sobre el m3 de Athena) y FOB/kg (sobre peso neto
    declarado, no depende de ningun supuesto de densidad).

Uso: python estudios_y_experimentos/exportaciones_moldecor.py
Salida: salidas/moldecor_exportaciones.xlsx
"""
import os
import re
import sys

RUTA_PROYECTO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, RUTA_PROYECTO)
import pipeline_chile_beta as p  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

RUTS_EMPRESA = ["76209596", "78744280"]
NOMBRE_EMPRESA = "MOLDECOR"  # texto buscado en importador
MARCA_EMPRESA = "MOLDECOR"  # texto buscado en marca/variedad
RUTA_SALIDA = os.path.join(RUTA_PROYECTO, "salidas", "moldecor_exportaciones.xlsx")

_FILTRO_RUT = " OR ".join(f"rut LIKE '{r}%'" for r in RUTS_EMPRESA)
CONSULTA = f"""
SELECT * FROM "ecommerce-prd-consumption-db"."srv_sap_marketing_aduanas_cl_exp"
WHERE {_FILTRO_RUT} OR upper(importador) LIKE '%{NOMBRE_EMPRESA}%'
   OR upper(marca) LIKE '%{MARCA_EMPRESA}%' OR upper(variedad) LIKE '%{MARCA_EMPRESA}%'
"""

COLUMNAS_DETALLE = [
    "periodo", "anio", "calmonth", "rut", "rut_original", "atribucion", "importador", "marca",
    "pais_destino", "tipo_familia", "tipo_subfamilia", "partida_arancelaria", "descripcion",
    "cantidad", "unidad_de_medida", "peso_neto", "volumen_m3", "us_fob", "fob_m3", "fob_kg",
    "via_de_transporte", "aduana", "numero_de_aceptacion",
]


def _pulgadas(texto: str) -> float:
    m = re.fullmatch(r"(\d+)(?:-(\d+)/(\d+))?", texto) or re.fullmatch(r"(\d+)/(\d+)", texto)
    if not m:
        return np.nan
    g = m.groups()
    if len(g) == 2:
        return int(g[0]) / int(g[1])
    return int(g[0]) + (int(g[1]) / int(g[2]) if g[1] else 0)


# Fraccion primero: si `\d+` va antes, "3/4" se lee como 3 y "1 1/2" como 1
_RX_MEDIDAS = re.compile(r"(\d+(?:[.,]\d+)?)\s*MM\s*X\s*(\d+\s*[-\s]\s*\d+/\d+|\d+/\d+|\d+)")


def volumen_geometrico(df: pd.DataFrame) -> pd.Series:
    """m3 = pies lineales x 0,3048 x espesor(mm) x ancho(pulg) -- solo para
    filas en pies lineales con medidas legibles en la descripcion; el
    resto queda NaN. Es el rectangulo envolvente del perfil (cota
    superior del volumen real)."""
    medidas = df["descripcion"].astype(str).str.upper().str.extract(_RX_MEDIDAS)
    esp_mm = pd.to_numeric(medidas[0].str.replace(",", "."), errors="coerce")
    # "1 1/2" y "1 - 1/2" se normalizan a "1-1/2"
    ancho_in = medidas[1].fillna("").str.replace(r"\s*-\s*|\s+", "-", regex=True).map(_pulgadas)
    unidad = df["unidad_de_medida"].astype(str).str.upper().str.strip()
    pies_lineales = unidad.isin(["LF", "PLF"]) | unidad.str.contains(r"P[IE]{2}L?\s*LIN|PIE LI", regex=True)
    m3 = df["cantidad"] * 0.3048 * esp_mm / 1000 * ancho_in * 0.0254
    return m3.where(pies_lineales & (m3 > 0))


def resumir(df: pd.DataFrame, por: list[str]) -> pd.DataFrame:
    con_m3 = df[df["volumen_m3"].notna()]
    r = df.groupby(por).agg(
        filas=("rut", "size"), m3=("volumen_m3", "sum"), peso_t=("peso_neto", "sum"), fob_usd=("us_fob", "sum"),
    )
    r["peso_t"] /= 1000
    # FOB/m3 solo sobre filas con volumen (algunas filas no lo traen)
    r["fob_m3"] = con_m3.groupby(por)["us_fob"].sum() / r["m3"].replace(0, np.nan)
    r["fob_kg"] = r["fob_usd"] / (r["peso_t"] * 1000)
    return r.reset_index().round({"m3": 1, "peso_t": 1, "fob_usd": 0, "fob_m3": 1, "fob_kg": 3})


def main():
    print(f"Athena: exportaciones {NOMBRE_EMPRESA} (todas las familias)...")
    df = p.athena_client.run_query(CONSULTA)
    for col in ["volumen_m3", "us_fob", "peso_neto", "cantidad"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df["rut_original"] = df["rut"]
    df["rut"] = df["rut"].astype("string").str.replace(r"\.0$", "", regex=True)
    rut = df["rut"].fillna("").str.strip()
    df["atribucion"] = np.select(
        [rut.isin(RUTS_EMPRESA).to_numpy(dtype=bool), (rut == "").to_numpy(dtype=bool)],
        ["RUT " + rut, f"sin RUT, nombre/marca {NOMBRE_EMPRESA}"],
        default="otro RUT " + rut + f", nombre/marca {NOMBRE_EMPRESA}",
    )
    df["periodo"] = pd.to_datetime(df["calmonth"].astype(str), format="%Y%m")
    df["anio"] = df["periodo"].dt.year
    df["fob_m3"] = df["us_fob"] / df["volumen_m3"]
    df["fob_kg"] = df["us_fob"] / df["peso_neto"]
    df["m3_geometrico"] = volumen_geometrico(df)
    df = df.sort_values(["periodo", "pais_destino"]).reset_index(drop=True)
    print(f"  {len(df)} filas, {df['periodo'].min():%Y-%m} a {df['periodo'].max():%Y-%m}")

    destino_anio = resumir(df, ["pais_destino", "anio"])
    destino_familia_anio = resumir(df, ["pais_destino", "tipo_familia", "anio"])
    mensual = resumir(df, ["calmonth", "pais_destino"])
    total_anio = resumir(df, ["anio"])

    geo = df[df["m3_geometrico"].notna()]
    validacion = geo.groupby("anio").agg(
        filas=("rut", "size"), m3_athena=("volumen_m3", "sum"), m3_geometrico=("m3_geometrico", "sum"),
        peso_t=("peso_neto", "sum"),
    )
    validacion["geo_vs_athena"] = validacion["m3_geometrico"] / validacion["m3_athena"]
    validacion["densidad_implicita_geo_kg_m3"] = validacion["peso_t"] / validacion["m3_geometrico"]
    validacion["peso_t"] /= 1000
    validacion = validacion.reset_index().round(2)

    notas = pd.DataFrame({"nota": [
        f"Fuente: Athena srv_sap_marketing_aduanas_cl_exp, consultado {pd.Timestamp.now():%Y-%m-%d}, sin filtro de familia.",
        f"Incluye RUT {' / '.join(RUTS_EMPRESA)} (normalizados, sin '.0') + filas cuyo importador/marca/variedad contiene {NOMBRE_EMPRESA} (columna 'atribucion').",
        "volumen_m3 NO es declarado: Athena lo deriva del peso neto con densidad fija (confirmado en MAFOR: MOLDURAS 530 kg/m3; MDF 560-810).",
        "La cantidad declarada viene en unidades heterogeneas (LF, PIEZA, CAJA, PAQUETE...) -- no sirve para sumar volumen.",
        "Validacion (hoja 'Validacion m3'): volumen geometrico (pies lineales x mm x pulgadas) vs. m3 de Athena.",
        "fob_m3 = FOB / m3 Athena (hereda el supuesto de densidad fija). fob_kg = FOB / peso neto declarado (sin supuestos).",
        "Filas sin volumen_m3 suman FOB y peso, pero se excluyen del FOB/m3.",
    ]})

    os.makedirs(os.path.dirname(RUTA_SALIDA), exist_ok=True)
    with pd.ExcelWriter(RUTA_SALIDA) as writer:
        destino_anio.to_excel(writer, sheet_name="Destino x año", index=False)
        destino_familia_anio.to_excel(writer, sheet_name="Destino x familia x año", index=False)
        mensual.to_excel(writer, sheet_name="Mensual x destino", index=False)
        total_anio.to_excel(writer, sheet_name="Total x año", index=False)
        validacion.to_excel(writer, sheet_name="Validacion m3", index=False)
        df[COLUMNAS_DETALLE + ["m3_geometrico"]].to_excel(writer, sheet_name="Detalle", index=False)
        notas.to_excel(writer, sheet_name="Notas", index=False)
    print(f"-> {RUTA_SALIDA}")

    pd.set_option("display.width", 200)
    print("\nDestino x año:")
    print(destino_anio.to_string(index=False))
    print("\nValidacion m3:")
    print(validacion.to_string(index=False))


if __name__ == "__main__":
    main()
