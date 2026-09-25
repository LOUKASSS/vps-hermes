# Environnement — VPS Hermes (référence)

Fichier géré par `/srv/command-center/agent.sh` (écrasé à chaque sync). La méthode de travail est
dans ta SOUL ; ici, les faits.

Conteneur `hermes-agent`, utilisateur `hermes` (uid 1000). Pas de root, pas de sudo, pas de Docker.
Persistant : `/opt/data` (ton HERMES_HOME, hôte `/srv/hermes/data`) et `/srv/workspace`. Le reste
est perdu à la mise à jour de l'image (dimanche 03:30).

Binaire : `hermes` (sur le PATH). Ne jamais éditer `/opt/data/.env`, `config.yaml`, `auth.json`
sans demande explicite. Un seul agent, une SOUL, des skills — pas de profiles.

## Le VPS en un coup d'œil (`/srv`)

| Dossier hôte | Rôle | Toi |
|---|---|---|
| `/srv/workspace` | **tous les projets**, partagé par toi, Orca, herdr et les sessions SSH | lecture/écriture, **même chemin** que l'hôte |
| `/srv/hermes` | tes données (`data/` = `/opt/data`), Postgres, Obsidian Sync | via `/opt/data` seulement |
| `/srv/command-center` | scripts de déploiement et d'admin, compose, secrets `.env` | invisible — l'opérateur lance `sudo command-center …` |
| `/srv/orca` | HOME d'Orca (sessions Claude/Codex/Grok de l'opérateur, desktop + mobile) | invisible |
| `/srv/helios` | déploiement Helios (`.env`, tinyauth) ; le code est dans `projects/helios` | invisible |
| `/srv/discord-backup` | bot de sauvegarde Discord (archives chiffrées, secrets via Bitwarden) — service système, hors de ta portée | invisible |

`/workspace` est un alias de `/srv/workspace` (anciens chemins, kanban). Écris les nouveaux
chemins en `/srv/workspace/…` : ils sont valides tels quels sur l'hôte, dans Orca et dans herdr.

## Arborescence `/srv/workspace`

| Chemin | Usage |
|---|---|
| `projects/<repo>/` | Un clone git par dépôt (dont `helios`, `indo-vacation`, `hermes-agent`). Contexte : `AGENTS.md` du repo (ne pas écraser). |
| `worktrees/hermes/<repo>-<sujet>/` | Tes worktrees git. Orca et herdr ont `worktrees/orca/` et `worktrees/herdr/`. |
| `scratch/` | Jetable, sans secrets. `scratch/briefs/` : briefs pour une session Orca/herdr de l'opérateur. |
| `db/migrations/` | SQL Postgres versionné. Appliquer, ne pas bricoler à la main. |
| `vault/` | Vault Obsidian (Sync). Règles : `vault/AGENTS.md` + skill `obsidian`. Ne pas toucher `vault/.obsidian/`. |
| `helios/` | Watchlist du dashboard Helios : `data/watchlist/` (à toi) + `tools/watchlist.py` (copie gérée par le déploiement — ne pas éditer). Skill `watchlist`. |
| `AGENTS.md`, `HERMES.md` | Règles du workspace (gérées par le command center). |

`/opt/data/projects/<repo>` sont des liens vers `projects/<repo>` (anciens chemins).

## Outils disponibles ici

| Outil | Usage |
|---|---|
| `claude` (Claude Code), `codex`, `grok` | CLIs de code, HOME `/opt/data/home`. Non interactif : `claude -p "…"`, `codex exec "…"`, lancés dans le worktree. |
| `gh`, `git` | PRs, issues, clones (HTTPS via `gh`). |
| `psql` (`PG*`, `DATABASE_URL`) | Postgres `hermes-postgres:5432`, base `hermes`. |
| `python3`, `uv`, `node`, `jq`, `tmux` | Scripts ; venv dans le projet, jamais global. |
| `delegate_task`, Cron, Kanban | Sous-tâches, récurrence, travail durable. |

## Interdit

- `sudo`, `apt`, Docker, exposer un port, stocker hors `/opt/data` et `/srv/workspace`.
- Déployer : tu prépares (commit, PR, commande exacte), l'opérateur lance `sudo command-center …`.
- Supprimer des données dans le workspace, `vault/` ou Postgres sans confirmation explicite.
- Secrets dans le vault, les commits, MEMORY.md ou les handoffs.
- Mélanger les contextes de dépôts ; coller l'historique health/markets dans MEMORY.md ou un board Kanban.

## Git

Identité globale : `LOUKASSS` / `loukass7@pm.me`. HTTPS via `gh`. Branche, commit, PR : skill
`github`. Une branche + un worktree par tâche ; jamais de travail direct sur `main`/`master`.

## Postgres et privé

Schémas `health` et `markets`. Migrations dans `db/migrations/`. Tables avec PK + `created_at`.
`markets.trades.mode` = `paper` uniquement.

| Données | Où |
|---|---|
| Santé | Postgres `health` + `/opt/data/private/health.sqlite3` |
| Marchés | Postgres `markets` + `/opt/data/private/markets.sqlite3` |
| Veille sujets | `/opt/data/private/watch-topics.json` |

## Déploiement (côté opérateur, pour info)

| Cible | Commande que tu donnes à l'opérateur |
|---|---|
| Helios (après merge dans `projects/helios`) | `sudo command-center helios deploy` |
| Bot de sauvegarde Discord (après merge dans le dépôt) | `sudo command-center discord-backup deploy` |
| Toi-même (image, compose) | `sudo command-center deploy hermes` |
| Tes skills / SOUL / MCP (repo command-center) | `sudo command-center hermes sync` |
| Tout voir | `sudo command-center status` |

## Vault

Handoff via le skill `obsidian` : lire `vault/AGENTS.md` et le protocole `07 ⚙️ Protocoles/`,
modèle `08 🧰 Templates/Handoff agent.md`. Inbox : `/srv/workspace/vault/00 📥 Inbox/Agents/default/YYYY-MM-DD--<id>.md`.
Audit vault avant clôture. Pas de handoff pour une simple réponse. Pas de secrets, ni données santé ou marchés dans le vault.
