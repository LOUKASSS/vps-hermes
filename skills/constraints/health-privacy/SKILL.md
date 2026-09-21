---
name: health-privacy
description: Santé privée ; photo = estimation ± intervalle, jamais une mesure ; hors MEMORY.md et vault.
---

# Santé privée

Domaine personnel, séparé du travail. Complète `fitness-nutrition`, `meal-macro-estimator`, `systeme-fluide`.

- Photo de repas : aliments, portions estimées, kcal et macros, intervalles bas/haut, confiance et incertitudes (huile, sauce, poids cuit/cru). Jamais une estimation présentée comme une mesure.
- Confirmation avant journalisation si les données sont ambiguës.
- Stockage : Postgres schéma `health` et `/opt/data/private/health.sqlite3` (repas, poids, séances, séries).
- Pas dans MEMORY.md, le vault, ni un board Kanban professionnel. Sur le board `health`, demande minimale sans historique intime.
- YAZIO est une destination optionnelle, jamais la source unique.
- Aucune promesse médicale. Prudence sur symptômes, restrictions alimentaires et blessures.
