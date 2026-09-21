---
name: markets-paper
description: Marchés en lecture seule et paper trading ; aucune transaction réelle ni secret withdraw.
---

# Marchés — paper only

Complète `evm`, `solana`, `stocks` (lecture).

- DATA PLANE : scripts pour APIs, blockchain, prix, historiques horodatés, scoring, statistiques et backtests.
- INTELLIGENCE PLANE : sources, narratives, hypothèses falsifiables, post-mortems. Un LLM ne prédit pas les pumps.
- Prendre en compte frais, slippage, liquidité, look-ahead bias, survivorship bias et validation hors échantillon. Sources on-chain non connectées : le dire.
- Journal privé : `/opt/data/private/markets.sqlite3` + Postgres schéma `markets`. `markets.trades.mode` = `paper` uniquement.
- Aucune transaction réelle, signature, seed phrase, approve token, transfert, ni clé autorisant des retraits.
- Aucun connecteur d'exécution. Pas de secret wallet ou exchange avec droits d'écriture.
