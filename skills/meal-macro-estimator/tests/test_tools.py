#!/usr/bin/env python3

import json
import os
import sqlite3
import subprocess
import sys
import unittest
from pathlib import Path


SKILL = Path(__file__).resolve().parent.parent


class ToolTests(unittest.TestCase):
    def run_json(self, script: str, *arguments: str, env=None):
        completed = subprocess.run(
            [sys.executable, str(SKILL / "scripts" / script), *arguments],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        return json.loads(completed.stdout)

    def test_database_is_complete_and_integral(self):
        connection = sqlite3.connect(SKILL / "data" / "ciqual_macros.sqlite")
        try:
            self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            self.assertGreaterEqual(connection.execute("SELECT count(*) FROM foods").fetchone()[0], 3000)
        finally:
            connection.close()

    def test_cooked_rice_lookup_selects_cooked_entry(self):
        items = self.run_json("lookup.py", "riz blanc cuit", "--limit", "3", "--json")
        self.assertEqual(items[0]["source"], "Ciqual")
        self.assertEqual(items[0]["id"], "9104")
        self.assertEqual(items[0]["per_100g"]["kcal"], 145.0)

    def test_lookup_does_not_pad_results_with_unrelated_foods(self):
        items = self.run_json("lookup.py", "nutella", "--limit", "20", "--json")
        self.assertGreaterEqual(len(items), 1)
        self.assertTrue(
            all(
                "nutella" in item["name"].lower() or "tartiner" in item["name"].lower()
                for item in items
            )
        )

    def test_example_compute_totals(self):
        result = self.run_json(
            "compute.py", str(SKILL / "templates" / "compute-input.json"), "--json"
        )
        self.assertAlmostEqual(result["totals"]["kcal"]["central"], 654.5)
        self.assertTrue(result["atwater_ok"])
        self.assertEqual(result["uncertainties"][0]["component"], "Riz blanc cuit")

    def test_usda_demo_key_is_rejected(self):
        environment = os.environ.copy()
        environment["USDA_FDC_API_KEY"] = "DEMO_KEY"
        completed = subprocess.run(
            [sys.executable, str(SKILL / "scripts" / "lookup.py"), "rice", "--usda"],
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("DEMO_KEY est refusée", completed.stderr)


if __name__ == "__main__":
    unittest.main()
