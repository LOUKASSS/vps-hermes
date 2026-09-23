#!/usr/bin/env python3
"""Look up kcal and macros in local Ciqual, Open Food Facts, or USDA FDC."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any


DEFAULT_DATABASE = Path(__file__).resolve().parent.parent / "data" / "ciqual_macros.sqlite"
USER_AGENT = "HermesMealMacroEstimator/0.1 (contact: local-hermes-user)"
COOKED_WORDS = {"cuit", "cuite", "cuits", "cuites", "roti", "rotie", "grille", "grillee"}
RAW_WORDS = {"cru", "crue", "crus", "crues"}
STOPWORDS = {
    "a",
    "au",
    "aux",
    "d",
    "de",
    "des",
    "du",
    "en",
    "et",
    "l",
    "la",
    "le",
    "les",
    "ou",
    "and",
    "of",
    "or",
    "the",
    "with",
}


def normalize(value: str) -> str:
    value = unicodedata.normalize("NFKD", value)
    value = "".join(char for char in value if not unicodedata.combining(char))
    value = re.sub(r"[^a-z0-9]+", " ", value.lower())
    return " ".join(value.split())


def as_number(value: Any) -> float | None:
    try:
        if value is None or value == "":
            return None
        number = float(value)
        return number if number >= 0 else None
    except (TypeError, ValueError):
        return None


def result(
    source: str,
    identifier: str,
    name: str,
    kcal: Any,
    protein: Any,
    carbs: Any,
    fat: Any,
    **extra: Any,
) -> dict[str, Any]:
    return {
        "source": source,
        "id": str(identifier),
        "name": name.strip(),
        "per_100g": {
            "kcal": as_number(kcal),
            "protein_g": as_number(protein),
            "carbs_g": as_number(carbs),
            "fat_g": as_number(fat),
        },
        **extra,
    }


def score_name(query: str, candidate: str, preference: str | None) -> float:
    query_tokens = {token for token in query.split() if token not in STOPWORDS}
    candidate_tokens = {token for token in candidate.split() if token not in STOPWORDS}
    if query_tokens and not query_tokens.intersection(candidate_tokens) and query not in candidate:
        return -1
    overlap = len(query_tokens & candidate_tokens) / max(1, len(query_tokens))
    score = overlap * 60 + SequenceMatcher(None, query, candidate).ratio() * 20
    if candidate == query:
        score += 100
    elif query in candidate:
        score += 35
    if query_tokens and query_tokens.issubset(candidate_tokens):
        score += 30

    if query_tokens & COOKED_WORDS:
        score += 18 if candidate_tokens & COOKED_WORDS else 0
        score -= 30 if candidate_tokens & RAW_WORDS else 0
    if query_tokens & RAW_WORDS:
        score += 18 if candidate_tokens & RAW_WORDS else 0
        score -= 30 if candidate_tokens & COOKED_WORDS else 0
    if preference == "cooked":
        score += 12 if candidate_tokens & COOKED_WORDS else 0
        score -= 12 if candidate_tokens & RAW_WORDS else 0
    elif preference == "raw":
        score += 12 if candidate_tokens & RAW_WORDS else 0
        score -= 12 if candidate_tokens & COOKED_WORDS else 0
    return score


def lookup_ciqual(query: str, database: Path, limit: int, preference: str | None):
    if not database.is_file():
        raise FileNotFoundError(
            f"Base Ciqual absente : {database}. Exécuter scripts/build_ciqual.py."
        )
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        rows = connection.execute(
            """SELECT ciqual_id, name_fr, normalized_name, kcal, protein_g, carbs_g, fat_g
               FROM foods"""
        ).fetchall()
    finally:
        connection.close()

    normalized_query = normalize(query)
    ranked = []
    for row in rows:
        candidate = row["normalized_name"]
        score = score_name(normalized_query, candidate, preference)
        if score <= 0:
            continue
        item = result(
            "Ciqual",
            row["ciqual_id"],
            row["name_fr"],
            row["kcal"],
            row["protein_g"],
            row["carbs_g"],
            row["fat_g"],
            match_score=round(score, 1),
        )
        ranked.append((score, item["per_100g"]["kcal"] is not None, item))
    ranked.sort(key=lambda entry: (entry[0], entry[1]), reverse=True)
    return [entry[2] for entry in ranked[:limit]]


def request_json(url: str, data: bytes | None = None) -> dict[str, Any]:
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response)


def lookup_off(query: str, limit: int):
    params = urllib.parse.urlencode(
        {
            "action": "process",
            "search_terms": query,
            "search_simple": 1,
            "json": 1,
            "page_size": min(limit * 3, 20),
            "fields": "code,product_name,brands,nutriments",
        }
    )
    payload = request_json(f"https://world.openfoodfacts.org/cgi/search.pl?{params}")
    found = []
    for product in payload.get("products", []):
        nutrients = product.get("nutriments") or {}
        kcal = nutrients.get("energy-kcal_100g")
        if kcal is None:
            energy_kj = as_number(nutrients.get("energy-kj_100g"))
            kcal = energy_kj / 4.184 if energy_kj is not None else None
        name = product.get("product_name") or "Produit sans nom"
        brands = product.get("brands") or ""
        if brands and normalize(brands) not in normalize(name):
            name = f"{name} — {brands}"
        found.append(
            result(
                "Open Food Facts",
                product.get("code") or "inconnu",
                name,
                kcal,
                nutrients.get("proteins_100g"),
                nutrients.get("carbohydrates_100g"),
                nutrients.get("fat_100g"),
            )
        )
    found.sort(key=lambda item: item["per_100g"]["kcal"] is not None, reverse=True)
    return found[:limit]


def nutrient_value(food: dict[str, Any], names: set[str], unit: str | None = None):
    for nutrient in food.get("foodNutrients", []):
        name = str(nutrient.get("nutrientName") or nutrient.get("name") or "").lower()
        nutrient_unit = str(nutrient.get("unitName") or nutrient.get("unit") or "").upper()
        if name in names and (unit is None or nutrient_unit == unit):
            return nutrient.get("value", nutrient.get("amount"))
    return None


def lookup_usda(query: str, limit: int):
    api_key = os.environ.get("USDA_FDC_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("USDA_FDC_API_KEY n'est pas définie ; USDA n'a pas été appelée.")
    if api_key.upper() == "DEMO_KEY":
        raise RuntimeError("DEMO_KEY est refusée en production ; fournir USDA_FDC_API_KEY.")
    endpoint = "https://api.nal.usda.gov/fdc/v1/foods/search?" + urllib.parse.urlencode(
        {"api_key": api_key}
    )
    body = json.dumps(
        {
            "query": query,
            "pageSize": limit,
            "dataType": ["Foundation", "SR Legacy"],
        }
    ).encode()
    payload = request_json(endpoint, data=body)
    found = []
    for food in payload.get("foods", []):
        found.append(
            result(
                "USDA FDC",
                food.get("fdcId") or "inconnu",
                food.get("description") or "Food without a name",
                nutrient_value(food, {"energy"}, "KCAL"),
                nutrient_value(food, {"protein"}),
                nutrient_value(food, {"carbohydrate, by difference"}),
                nutrient_value(food, {"total lipid (fat)"}),
            )
        )
    return found


def format_number(value: float | None, suffix: str = "") -> str:
    return "null" if value is None else f"{value:g}{suffix}"


def print_text(items: list[dict[str, Any]]) -> None:
    if not items:
        print("Aucun résultat.")
        return
    for index, item in enumerate(items, 1):
        nutrition = item["per_100g"]
        print(f"[{index}] {item['source']} {item['id']} — {item['name']}")
        print(
            "    pour 100 g : "
            f"{format_number(nutrition['kcal'], ' kcal')} | "
            f"P {format_number(nutrition['protein_g'], ' g')} | "
            f"G {format_number(nutrition['carbs_g'], ' g')} | "
            f"L {format_number(nutrition['fat_g'], ' g')}"
        )
        if "match_score" in item:
            print(f"    score de correspondance : {item['match_score']}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query")
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--prefer", choices=("cooked", "raw"))
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--off", action="store_true", help="Produit emballé via Open Food Facts")
    source.add_argument("--usda", action="store_true", help="USDA, clé réelle obligatoire")
    parser.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    parser.add_argument("--json", action="store_true", help="Sortie JSON structurée")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50:
        parser.error("--limit doit être compris entre 1 et 50")
    return args


def main() -> int:
    args = parse_args()
    try:
        if args.off:
            try:
                items = lookup_off(args.query, args.limit)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                print(
                    f"Avertissement : Open Food Facts indisponible ({error}); repli Ciqual.",
                    file=sys.stderr,
                )
                items = lookup_ciqual(args.query, args.database, args.limit, args.prefer)
            if not items:
                print("Avertissement : aucun résultat OFF ; repli Ciqual.", file=sys.stderr)
                items = lookup_ciqual(args.query, args.database, args.limit, args.prefer)
        elif args.usda:
            items = lookup_usda(args.query, args.limit)
        else:
            items = lookup_ciqual(args.query, args.database, args.limit, args.prefer)
        if args.json:
            print(json.dumps(items, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            print_text(items)
        return 0 if items else 1
    except Exception as error:  # CLI boundary.
        print(f"Erreur : {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
