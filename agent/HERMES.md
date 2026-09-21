# Règles workspace — VPS Hermes

Conteneur `hermes-agent`, utilisateur `hermes` (uid 1000). Pas de root, pas de sudo, pas de daemon Docker. Persistent : `/opt/data` et `/workspace` seulement. Le reste est perdu à la MAJ image (dimanche 03:30).

Binaire Hermes : `/opt/hermes/bin/hermes` (`export PATH="/opt/hermes/bin:$PATH"`). Ne jamais éditer `/opt/data/.env`, `config.yaml`, `auth.json` sans demande explicite.

Un seul agent, une SOUL, des skills. Pas de routage vers des profiles `chief` / `engineer` / `seo` / `researcher` / `health` / `markets`.

Le code déterministe assure collecte, filtrage, calculs, scoring, tests et déduplication. Un LLM interprète un signal utile ; il ne recalcule pas et ne relit pas sans changement.

## Arborescence `/workspace`

| Chemin | Usage |
|---|---|
| `projects/<repo>/` | Un clone git par dépôt. **Ne pas aplatir** vers `/workspace/<repo>`. Contexte projet dans `AGENTS.md` du repo (ne pas écraser). |
| `db/migrations/` | SQL Postgres versionné. Appliquer, ne pas bricoler à la main. |
| `scratch/` | Jetable. Persistant sur disque mais sans valeur. Pas de secrets. |
| `vault/` | Vault Obsidian (Sync). Règles : `vault/AGENTS.md` et skill `obsidian`. Ne pas toucher `vault/.obsidian/`. |
| `helios/` | Watchlist du dashboard Helios : `data/watchlist/` (données, à toi) + `tools/watchlist.py` (CLI, copie gérée par Orca — ne pas éditer). Skill `watchlist`. |

Côté hôte le même arbre est `/srv/hermes/projects`. L'agent voit `/workspace/projects/<repo>` ; Orca ouvre le même chemin. Ne pas inventer `/workspace/<repo>` à la racine.

Données personnelles structurées → Postgres (`psql`, env `PG*` déjà là) et sqlite sous `/opt/data/private/`. Notes → vault. Tâches durables → Kanban (boards métier : sites-seo, outils, veille, markets, health). Code déployable → git distant (`gh`) ; Orca/opérateur déploie, jamais depuis ce conteneur.

## Interdit

- `sudo`, `apt`, Docker daemon, exposer un port, stocker hors `/opt/data` et `/workspace`.
- Supprimer des données dans `/workspace`, `vault/` ou Postgres sans confirmation explicite.
- Secrets dans le vault, les commits, MEMORY.md ou les handoffs.
- Mélanger contextes de dépôts, ni coller l'historique health/markets dans MEMORY.md ou un board Kanban.
- `claude`, `codex`, `grok` dans ce conteneur : ces binaires n'y sont **pas**. Interdit : `claude -p`, `codex exec`, et tout wrapper équivalent.

## Git

Identité globale : `LOUKASSS` / `loukass7@pm.me`. HTTPS via `gh`. Branche, commit, PR : skill `github`. Un worktree ou un dossier `projects/<repo>` par contexte. `gh` est disponible ici (PRs depuis une session Hermes) et sur l'hôte (Orca).

## Postgres et privé

Hôte `hermes-postgres:5432`, base `hermes`, user `hermes`. Schémas `health` et `markets`. Migrations dans `db/migrations/`. Tables avec PK + `created_at`. `markets.trades.mode` = `paper` uniquement.

| Données | Où |
|---|---|
| Santé | Postgres `health` + `/opt/data/private/health.sqlite3` |
| Marchés | Postgres `markets` + `/opt/data/private/markets.sqlite3` |
| Veille sujets | `/opt/data/private/watch-topics.json` |

## Délégation

| Cas | Outil | Retour |
|---|---|---|
| Sous-tâche courte, parallèle, non durable | `delegate_task` (enfant terra par défaut) | résumé enfant ; vérifier les effets de bord |
| Session interactive Claude / Codex / Grok | **Orca sur l'hôte** (binaires absents du conteneur) | brief écrit dans le projet ; l'opérateur ouvre Orca |
| Recurrence / hors process | Cron natif (`--paused` tant que la source n'est pas réelle) | livraison Cron, pas un spawn |

`delegate_task` = sous-problème temporaire, pas un profile fantôme. Gros chantier coding : Orca, pas un CLI dans ce terminal.

## Vault

Handoff via le skill `obsidian` : lire `vault/AGENTS.md` et le protocole `07 ⚙️ Protocoles/`, modèle `08 🧰 Templates/Handoff agent.md`. Inbox unique : `/workspace/vault/00 📥 Inbox/Agents/default/YYYY-MM-DD--<id>.md`. Audit vault avant clôture. Pas de handoff pour une simple réponse conversationnelle. Pas de secrets, ni données santé ou marchés dans le vault.
