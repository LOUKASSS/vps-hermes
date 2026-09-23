#!/usr/bin/env python3
"""Build the local meal-macro Ciqual SQLite database from ANSES 2020 XML."""

from __future__ import annotations

import argparse
import hashlib
import io
import os
import re
import sqlite3
import tempfile
import unicodedata
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO
from xml.etree import ElementTree as ET
from zipfile import ZipFile


SOURCE_URL = "https://zenodo.org/records/4770600/files/XML_2020_07_07.zip?download=1"
SOURCE_SHA256 = "e6374c1cd241da825503c7d4f797d36e6c0f0cd4faa5e4db6f1f175a9d7b85da"
SOURCE_CITATION = "Anses. 2020. Ciqual French food composition table."
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "data" / "ciqual_macros.sqlite"
USER_AGENT = "HermesMealMacroEstimator/0.1 (+local Ciqual builder)"

NUTRIENT_CODES = {
    "kcal": "328",
    "protein_primary": "25000",
    "protein_fallback": "25003",
    "carbs_g": "31000",
    "fat_g": "40000",
}


def clean(value: str | None) -> str:
    return (value or "").strip()


def normalize(value: str) -> str:
    value = unicodedata.normalize("NFKD", value)
    value = "".join(char for char in value if not unicodedata.combining(char))
    value = re.sub(r"[^a-z0-9]+", " ", value.lower())
    return " ".join(value.split())


def numeric(value: str | None) -> float | None:
    """Parse Ciqual French decimals, including censored values such as '< 0,1'."""
    raw = clean(value).replace("\u00a0", " ").replace(",", ".")
    if not raw or raw in {"-", "."} or raw.lower() in {"traces", "trace"}:
        return None
    match = re.search(r"[-+]?\d+(?:\.\d+)?", raw)
    return float(match.group(0)) if match else None


def download(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def iter_records(stream: BinaryIO, tag: str):
    for _event, element in ET.iterparse(stream, events=("end",)):
        if element.tag == tag:
            yield element
            element.clear()


def sanitized_xml(archive: ZipFile, name: str) -> BinaryIO:
    """Escape bare '<' and '&' characters present in ANSES text/value nodes."""
    raw = archive.read(name)
    raw = re.sub(br"<(?![!?/]?[A-Za-z_])", b"&lt;", raw)
    raw = re.sub(br"&(?!#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z]+;)", b"&amp;", raw)
    return io.BytesIO(raw)


def extract(zip_path: Path):
    foods: dict[str, dict[str, str]] = {}
    nutrients: dict[str, dict[str, float]] = {}
    wanted = set(NUTRIENT_CODES.values())

    with ZipFile(zip_path) as archive:
        required = {"alim_2020_07_07.xml", "compo_2020_07_07.xml"}
        missing = required.difference(archive.namelist())
        if missing:
            raise RuntimeError(f"Archive Ciqual invalide, fichiers absents : {sorted(missing)}")

        with sanitized_xml(archive, "alim_2020_07_07.xml") as stream:
            for element in iter_records(stream, "ALIM"):
                code = clean(element.findtext("alim_code"))
                if not code:
                    continue
                foods[code] = {
                    "name_fr": clean(element.findtext("alim_nom_fr")),
                    "name_index_fr": clean(element.findtext("ALIM_NOM_INDEX_FR")),
                    "name_en": clean(element.findtext("alim_nom_eng")),
                    "group_code": clean(element.findtext("alim_grp_code")),
                    "subgroup_code": clean(element.findtext("alim_ssgrp_code")),
                    "subsubgroup_code": clean(element.findtext("alim_ssssgrp_code")),
                }

        with sanitized_xml(archive, "compo_2020_07_07.xml") as stream:
            for element in iter_records(stream, "COMPO"):
                nutrient_code = clean(element.findtext("const_code"))
                if nutrient_code not in wanted:
                    continue
                food_code = clean(element.findtext("alim_code"))
                value = numeric(element.findtext("teneur"))
                if food_code and value is not None:
                    nutrients.setdefault(food_code, {})[nutrient_code] = value

    if len(foods) < 3000:
        raise RuntimeError(f"Import Ciqual incomplet : seulement {len(foods)} aliments")
    return foods, nutrients


def build_database(output: Path, foods, nutrients, source_digest: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temp_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    os.close(file_descriptor)
    temp_path = Path(temp_name)
    try:
        connection = sqlite3.connect(temp_path)
        with connection:
            connection.executescript(
                """
                PRAGMA journal_mode=DELETE;
                PRAGMA synchronous=FULL;
                CREATE TABLE foods (
                    ciqual_id TEXT PRIMARY KEY,
                    name_fr TEXT NOT NULL,
                    name_index_fr TEXT NOT NULL,
                    name_en TEXT NOT NULL,
                    normalized_name TEXT NOT NULL,
                    group_code TEXT NOT NULL,
                    subgroup_code TEXT NOT NULL,
                    subsubgroup_code TEXT NOT NULL,
                    kcal REAL,
                    protein_g REAL,
                    carbs_g REAL,
                    fat_g REAL
                );
                CREATE INDEX foods_normalized_name_idx ON foods(normalized_name);
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                PRAGMA user_version=1;
                """
            )
            rows = []
            for food_id in sorted(foods, key=lambda item: int(item)):
                food = foods[food_id]
                values = nutrients.get(food_id, {})
                protein = values.get(NUTRIENT_CODES["protein_primary"])
                if protein is None:
                    protein = values.get(NUTRIENT_CODES["protein_fallback"])
                searchable = " ".join(
                    filter(None, [food["name_fr"], food["name_index_fr"], food["name_en"]])
                )
                rows.append(
                    (
                        food_id,
                        food["name_fr"],
                        food["name_index_fr"],
                        food["name_en"],
                        normalize(searchable),
                        food["group_code"],
                        food["subgroup_code"],
                        food["subsubgroup_code"],
                        values.get(NUTRIENT_CODES["kcal"]),
                        protein,
                        values.get(NUTRIENT_CODES["carbs_g"]),
                        values.get(NUTRIENT_CODES["fat_g"]),
                    )
                )
            connection.executemany(
                """INSERT INTO foods VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", rows
            )
            metadata = {
                "source": SOURCE_CITATION,
                "source_url": SOURCE_URL,
                "source_sha256": source_digest,
                "source_version": "2020-07-07",
                "license": "Licence Ouverte / Open Licence",
                "built_at_utc": datetime.now(timezone.utc).isoformat(),
                "food_count": str(len(rows)),
            }
            connection.executemany("INSERT INTO metadata VALUES (?, ?)", metadata.items())
        connection.execute("VACUUM")
        connection.close()
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, output)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="Archive XML Ciqual locale ; téléchargement officiel sinon")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--skip-checksum",
        action="store_true",
        help="Accepter une archive différente de la version ANSES épinglée",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    temporary_download: Path | None = None
    try:
        if args.source:
            source = Path(args.source).expanduser().resolve()
            if not source.is_file():
                raise FileNotFoundError(f"Archive introuvable : {source}")
        else:
            descriptor, name = tempfile.mkstemp(prefix="ciqual-2020-", suffix=".zip")
            os.close(descriptor)
            source = temporary_download = Path(name)
            print(f"Téléchargement Ciqual 2020 : {SOURCE_URL}")
            download(SOURCE_URL, source)

        digest = sha256(source)
        if not args.skip_checksum and digest != SOURCE_SHA256:
            raise RuntimeError(
                "Somme SHA-256 Ciqual inattendue. Refuser l'import ; utiliser "
                "--skip-checksum uniquement après vérification manuelle."
            )
        foods, nutrients = extract(source)
        output = args.output.expanduser().resolve()
        build_database(output, foods, nutrients, digest)
        complete = sum(
            1
            for food_id in foods
            if all(
                value is not None
                for value in (
                    nutrients.get(food_id, {}).get(NUTRIENT_CODES["kcal"]),
                    nutrients.get(food_id, {}).get(NUTRIENT_CODES["protein_primary"])
                    if nutrients.get(food_id, {}).get(NUTRIENT_CODES["protein_primary"])
                    is not None
                    else nutrients.get(food_id, {}).get(NUTRIENT_CODES["protein_fallback"]),
                    nutrients.get(food_id, {}).get(NUTRIENT_CODES["carbs_g"]),
                    nutrients.get(food_id, {}).get(NUTRIENT_CODES["fat_g"]),
                )
            )
        )
        print(f"Base créée : {output} ({len(foods)} aliments, {complete} avec macros principales)")
        return 0
    except Exception as error:  # CLI boundary: give a concise, actionable error.
        print(f"Erreur : {error}", file=os.sys.stderr)
        return 1
    finally:
        if temporary_download and temporary_download.exists():
            temporary_download.unlink()


if __name__ == "__main__":
    raise SystemExit(main())
