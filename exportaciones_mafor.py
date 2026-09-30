# -*- coding: utf-8 -*-
"""
Exportaciones de MAFOR (Chile) -- todas las familias de producto, sin el
filtro MDF/PB del pipeline beta, directo de Athena (cl_exp), 2019 a hoy.

Filas incluidas: RUT 96698130 (normalizado: Athena trae 1.069 filas como
"96698130.0", nov-2021 a nov-2022) + filas sin RUT (exportador "OTROS")
cuya marca/variedad es MAFOR -- mismo producto y destino, atribuidas por
marca (columna `atribucion`).

Volumen y precio:
  - `volumen_m3` NO es un dato declarado: Athena lo deriva del peso neto
    con densidad fija (MOLDURAS: exactamente 530 kg/m3 en todas las
    filas; MDF: 560-810 segun espesor). La cantidad declarada viene en ~30
    unidades distintas (LF, PIEZA, CAJA, PAQUETE...) y no sirve para
    sumar volumen.
  - Validacion: para filas en pies lineales con medidas parseables en la
    descripcion (mm x pulgadas), el volumen geometrico calza con el de
    Athena dentro de 4-11% en 2022-2025 (hoja "Validacion m3"); 2019-2020
    +23-25%; 2021 y 2026 tienen cantidades con errores de unidad que
    distorsionan la comparacion -- no el m3 de Athena, que depende solo
    del peso.
  - Precio: FOB/m3 (sobre el m3 de Athena) y FOB/kg (sobre peso neto
    declarado, no depende de ningun supuesto de densidad).

Uso: python estudios_y_experimentos/exportaciones_mafor.py
Salida: salidas/mafor_exportaciones.xlsx
"""
import os
import re
import sys

RUTA_PROYECTO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, RUTA_PROYECTO)
import pipeline_chile_beta as p  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

RUT_MAFOR = "96698130"
RUTA_SALIDA = os.path.join(RUTA_PROYECTO, "salidas", "mafor_exportaciones.xlsx")

CONSULTA = f"""
SELECT * FROM "ecommerce-prd-consumption-db"."srv_sap_marketing_aduanas_cl_exp"
WHERE rut LIKE '{RUT_MAFOR}%' OR upper(importador) LIKE '%MAFOR%'
   OR upper(marca) LIKE '%MAFOR%' OR upper(variedad) LIKE '%MAFOR%'
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


_RX_MEDIDAS = re.compile(r"(\d+(?:[.,]\d+)?)\s*MM\s*X\s*(\d+(?:\s*-\s*\d+/\d+)?|\d+/\d+)")


def volumen_geometrico(df: pd.DataFrame) -> pd.Series:
    """m3 = pies lineales x 0,3048 x espesor(mm) x ancho(pulg) -- solo para
    filas en pies lineales con medidas legibles en la descripcion; el
    resto queda NaN. Es el rectangulo envolvente del perfil (cota
    superior del volumen real)."""
    medidas = df["descripcion"].astype(str).str.upper().str.extract(_RX_MEDIDAS)
    esp_mm = pd.to_numeric(medidas[0].str.replace(",", "."), errors="coerce")
    ancho_in = medidas[1].fillna("").str.replace(" ", "").map(_pulgadas)
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
    # FOB/m3 solo sobre filas con volumen (12 filas OTROS COMPLEMENTO no lo tienen)
    r["fob_m3"] = con_m3.groupby(por)["us_fob"].sum() / r["m3"].replace(0, np.nan)
    r["fob_kg"] = r["fob_usd"] / (r["peso_t"] * 1000)
    return r.reset_index().round({"m3": 1, "peso_t": 1, "fob_usd": 0, "fob_m3": 1, "fob_kg": 3})


def main():
    print("Athena: exportaciones MAFOR (todas las familias)...")
    df = p.athena_client.run_query(CONSULTA)
    for col in ["volumen_m3", "us_fob", "peso_neto", "cantidad"]:
        df[col] = pd.to_numeric(df[col], errors="coerce")
    df["rut_original"] = df["rut"]
    df["rut"] = df["rut"].astype("string").str.replace(r"\.0$", "", regex=True)
    df["atribucion"] = np.where(df["rut"] == RUT_MAFOR, "RUT 96698130", "sin RUT, marca MAFOR")
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
        "Incluye RUT 96698130 (normalizado: 1.069 filas venian como '96698130.0') + filas sin RUT con marca MAFOR (columna 'atribucion').",
        "volumen_m3 NO es declarado: Athena lo deriva del peso neto con densidad fija (MOLDURAS = 530 kg/m3 exacto; MDF 560-810).",
        "La cantidad declarada viene en ~30 unidades distintas (LF, PIEZA, CAJA, PAQUETE...) -- no sirve para sumar volumen.",
        "Validacion (hoja 'Validacion m3'): volumen geometrico (pies lineales x mm x pulgadas) vs. Athena, 4-11% de diferencia en 2022-2025.",
        "2019-2020: +23-25%. 2021 (x3,4) y 2026 (x1,75): cantidades mal declaradas en pies lineales, no afecta al m3 de Athena (depende solo del peso).",
        "fob_m3 = FOB / m3 Athena (hereda el supuesto de 530 kg/m3). fob_kg = FOB / peso neto declarado (sin supuestos).",
        "Si la densidad real de las molduras fuera ~700 kg/m3, el m3 bajaria ~24% y el FOB/m3 subiria ~32% -- FOB/kg no cambia.",
        "12 filas OTROS COMPLEMENTO sin volumen: suman FOB y peso, pero se excluyen del FOB/m3.",
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
