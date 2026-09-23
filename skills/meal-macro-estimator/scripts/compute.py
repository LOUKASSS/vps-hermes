#!/usr/bin/env python3
"""Scale sourced per-100-g nutrition values across portion ranges."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


NUTRIENTS = ("kcal", "protein_g", "carbs_g", "fat_g")
LABELS = {
    "kcal": "Calories",
    "protein_g": "Protéines",
    "carbs_g": "Glucides",
    "fat_g": "Lipides",
}


class InputError(ValueError):
    pass


def number(value: Any, path: str, *, positive: bool = False) -> float:
    if isinstance(value, bool):
        raise InputError(f"{path} doit être un nombre")
    try:
        parsed = float(value)
    except (TypeError, ValueError) as error:
        raise InputError(f"{path} doit être un nombre") from error
    if not math.isfinite(parsed) or parsed < 0 or (positive and parsed == 0):
        qualifier = "strictement positif" if positive else "positif ou nul"
        raise InputError(f"{path} doit être {qualifier}")
    return parsed


def validate_source(source: Any, path: str) -> dict[str, str]:
    if not isinstance(source, dict):
        raise InputError(f"{path} doit être un objet")
    output = {}
    for key in ("database", "id", "name"):
        value = str(source.get(key, "")).strip()
        if not value:
            raise InputError(f"{path}.{key} est obligatoire")
        output[key] = value
    return output


def validate_portion(component: dict[str, Any], path: str):
    portion = component.get("portion")
    if not isinstance(portion, dict):
        raise InputError(f"{path}.portion doit être un objet")
    unit = str(portion.get("unit", "g")).lower()
    if unit not in {"g", "ml"}:
        raise InputError(f"{path}.portion.unit doit être 'g' ou 'ml'")
    values = {
        key: number(portion.get(key), f"{path}.portion.{key}")
        for key in ("low", "central", "high")
    }
    if not values["low"] <= values["central"] <= values["high"]:
        raise InputError(f"{path}.portion doit respecter low <= central <= high")
    density = 1.0
    if unit == "ml":
        density = number(
            portion.get("density_g_per_ml"),
            f"{path}.portion.density_g_per_ml",
            positive=True,
        )
    grams = {key: value * density for key, value in values.items()}
    return {**values, "unit": unit, "density_g_per_ml": density}, grams


def validate_component(component: Any, index: int):
    path = f"components[{index}]"
    if not isinstance(component, dict):
        raise InputError(f"{path} doit être un objet")
    name = str(component.get("name", "")).strip()
    if not name:
        raise InputError(f"{path}.name est obligatoire")
    source = validate_source(component.get("source"), f"{path}.source")
    per_100g = component.get("per_100g")
    if not isinstance(per_100g, dict):
        raise InputError(f"{path}.per_100g doit être un objet")
    nutrition = {
        nutrient: number(per_100g.get(nutrient), f"{path}.per_100g.{nutrient}")
        for nutrient in NUTRIENTS
    }
    portion, grams = validate_portion(component, path)
    confidence = number(component.get("confidence", 5), f"{path}.confidence")
    if confidence > 10:
        raise InputError(f"{path}.confidence doit être compris entre 0 et 10")
    uncertainty = str(component.get("uncertainty", "portion visuelle")).strip()
    return name, source, nutrition, portion, grams, confidence, uncertainty


def scaled(value: float, grams: dict[str, float]):
    return {key: value * grams[key] / 100 for key in ("low", "central", "high")}


def rounded_range(values: dict[str, float]):
    return {key: round(value, 3) for key, value in values.items()}


def compute(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise InputError("La racine JSON doit être un objet")
    meal_name = str(document.get("meal_name", "Repas restaurant")).strip()
    components = document.get("components")
    if not isinstance(components, list) or not components:
        raise InputError("components doit être une liste non vide")

    totals = {nutrient: {key: 0.0 for key in ("low", "central", "high")} for nutrient in NUTRIENTS}
    output_components = []
    warnings = []
    uncertainties = []

    for index, raw_component in enumerate(components):
        name, source, nutrition, portion, grams, confidence, uncertainty = validate_component(
            raw_component, index
        )
        values = {nutrient: scaled(nutrition[nutrient], grams) for nutrient in NUTRIENTS}
        for nutrient in NUTRIENTS:
            for scenario in ("low", "central", "high"):
                totals[nutrient][scenario] += values[nutrient][scenario]

        atwater = 4 * nutrition["protein_g"] + 4 * nutrition["carbs_g"] + 9 * nutrition["fat_g"]
        declared = nutrition["kcal"]
        atwater_difference_pct = (
            abs(declared - atwater) / declared * 100 if declared > 0 else (0.0 if atwater == 0 else 100.0)
        )
        if atwater_difference_pct > 15:
            warnings.append(
                {
                    "component": name,
                    "message": (
                        f"Écart Atwater {atwater_difference_pct:.1f}% : {declared:g} kcal déclarées "
                        f"contre {atwater:.1f} kcal calculées pour 100 g. Revérifier la source."
                    ),
                }
            )

        impact = values["kcal"]["high"] - values["kcal"]["low"]
        uncertainties.append(
            {
                "component": name,
                "reason": uncertainty or "portion visuelle",
                "range_kcal": round(impact, 3),
                "plus_minus_kcal": round(impact / 2, 3),
            }
        )
        output_components.append(
            {
                "name": name,
                "source": source,
                "portion": portion,
                "effective_grams": rounded_range(grams),
                "per_100g": nutrition,
                "values": {key: rounded_range(value) for key, value in values.items()},
                "confidence": confidence,
                "uncertainty": uncertainty,
                "atwater": {
                    "calculated_kcal_per_100g": round(atwater, 3),
                    "difference_pct": round(atwater_difference_pct, 3),
                    "review_required": atwater_difference_pct > 15,
                },
            }
        )

    uncertainties.sort(key=lambda item: item["range_kcal"], reverse=True)
    for rank, item in enumerate(uncertainties, 1):
        item["rank"] = rank
    return {
        "meal_name": meal_name,
        "components": output_components,
        "totals": {nutrient: rounded_range(values) for nutrient, values in totals.items()},
        "uncertainties": uncertainties,
        "warnings": warnings,
        "atwater_ok": not warnings,
    }


def clean_number(value: float, decimals: int = 1) -> str:
    rounded = round(value, decimals)
    rendered = f"{rounded:.{decimals}f}"
    return rendered.rstrip("0").rstrip(".") if decimals else rendered


def text_output(result: dict[str, Any]) -> str:
    lines = [f"REPAS : {result['meal_name']}", "", "COMPOSANTS CALCULÉS"]
    for index, component in enumerate(result["components"], 1):
        portion = component["portion"]
        central = {key: values["central"] for key, values in component["values"].items()}
        lines.extend(
            [
                f"{index}. {component['name']}",
                (
                    f"   Portion : {clean_number(portion['low'])}–{clean_number(portion['high'])} "
                    f"{portion['unit']} (central {clean_number(portion['central'])} {portion['unit']})"
                ),
                (
                    f"   Central : {clean_number(central['kcal'], 0)} kcal | "
                    f"P {clean_number(central['protein_g'])} g | "
                    f"G {clean_number(central['carbs_g'])} g | "
                    f"L {clean_number(central['fat_g'])} g"
                ),
                (
                    f"   Source : {component['source']['database']} {component['source']['id']} "
                    f"— {component['source']['name']}"
                ),
            ]
        )
    lines.extend(["", "TOTALS"])
    for nutrient in NUTRIENTS:
        values = result["totals"][nutrient]
        decimals = 0 if nutrient == "kcal" else 1
        unit = "kcal" if nutrient == "kcal" else "g"
        lines.append(
            f"{LABELS[nutrient]} : {clean_number(values['low'], decimals)}–"
            f"{clean_number(values['high'], decimals)} {unit} — central "
            f"{clean_number(values['central'], decimals)} {unit}"
        )
    lines.extend(["", "INCERTITUDES PAR IMPACT KCAL"])
    for item in result["uncertainties"]:
        lines.append(
            f"{item['rank']}. {item['component']} — {item['reason']} : "
            f"±{clean_number(item['plus_minus_kcal'], 0)} kcal "
            f"(plage {clean_number(item['range_kcal'], 0)} kcal)"
        )
    if result["warnings"]:
        lines.extend(["", "ALERTES ATWATER"])
        lines.extend(f"- {warning['component']} : {warning['message']}" for warning in result["warnings"])
    else:
        lines.extend(["", "ATWATER : cohérent (écart ≤ 15 % pour chaque composant)"])
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("meal_json", type=Path)
    parser.add_argument("--json", action="store_true", help="Sortie JSON structurée")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        with args.meal_json.open(encoding="utf-8") as stream:
            document = json.load(stream)
        result = compute(document)
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            print(text_output(result))
        return 0
    except (OSError, json.JSONDecodeError, InputError) as error:
        print(f"Erreur : {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
