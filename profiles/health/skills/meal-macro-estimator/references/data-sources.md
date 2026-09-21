# Sources nutritionnelles

## ANSES Ciqual 2020 — source prioritaire

- Producteur : Agence nationale de sécurité sanitaire de l'alimentation, de l'environnement et du travail (ANSES).
- Jeu : Table de composition nutritionnelle des aliments Ciqual 2020, version française du 7 juillet 2020.
- Citation demandée : `Anses. 2020. Ciqual French food composition table.`
- Archive XML épinglée : `https://zenodo.org/records/4770600/files/XML_2020_07_07.zip?download=1`
- SHA-256 : `e6374c1cd241da825503c7d4f797d36e6c0f0cd4faa5e4db6f1f175a9d7b85da`
- Licence : Licence Ouverte / Open Licence.
- `scripts/build_ciqual.py` n'importe que l'identité des aliments et les quatre champs nécessaires : énergie UE (code 328), protéines (25000, repli 25003), glucides (31000), lipides (40000).

Ciqual est la base locale par défaut. Respecter l'état et la cuisson de l'aliment. Une valeur manquante reste `null` ; ne jamais la remplacer de mémoire.

## Open Food Facts — produit emballé seulement

- Utiliser `lookup.py --off` pour une marque ou un produit emballé.
- Lecture gratuite sans clé, avec un User-Agent explicite.
- Les données sont contributives et peuvent être incomplètes ; garder le produit exact et son code-barres dans la source.
- Licence base : Open Database License (ODbL). Contenu individuel : Database Contents License.
- En cas de réponse 503, absence de résultat ou donnée incomplète, revenir à Ciqual ; ne pas inventer.

## USDA FoodData Central — repli explicite

- Utiliser seulement avec `lookup.py --usda` et une vraie variable `USDA_FDC_API_KEY`.
- `DEMO_KEY` est volontairement refusée.
- Limiter les recherches aux jeux Foundation et SR Legacy pour les aliments génériques.
- Les données FoodData Central sont dans le domaine public / CC0 ; conserver l'identifiant FDC.

## Unités

Toutes les valeurs retournées par `lookup.py` sont normalisées par 100 g. Pour une portion en ml, `compute.py` exige `density_g_per_ml`; ne jamais supposer une densité silencieusement dans le calcul final.
