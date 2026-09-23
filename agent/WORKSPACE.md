# Workspace partagé — `/srv/workspace`

Fichier géré par `/srv/command-center/agent.sh` (écrasé à chaque sync). Lu par Codex / Grok
(`AGENTS.md`) et Claude Code (`CLAUDE.md` → lien vers ce fichier) quand ils démarrent ici,
via Orca, herdr ou une session SSH. Hermes lit `HERMES.md` à la place.

## Un seul endroit pour les projets

Tous les outils travaillent sur **le même arbre, au même chemin absolu** :

| Outil | Où il tourne | Utilisateur / HOME | Voit le workspace à |
|---|---|---|---|
| Hermes Agent | conteneur `hermes-agent` | `hermes` (uid 1000) · `/opt/data/home` | `/srv/workspace` (+ alias `/workspace`) |
| Orca (desktop / mobile) | hôte, `orca.service` | `hermes` · `/srv/orca` | `/srv/workspace` |
| herdr + terminal-code (`tode`) | hôte, `herdr.service` | `hermes` · `/home/hermes` | `/srv/workspace` |
| SSH | hôte | `hermes` · `/home/hermes` | `/srv/workspace` (`ws`) |

Même uid partout : pas d'ACL, pas de `chown` à faire. Un chemin écrit par un outil est valide
pour tous les autres (worktrees git compris). `/workspace` existe aussi sur l'hôte (lien).

## Arborescence

| Chemin | Usage |
|---|---|
| `projects/<repo>/` | Un clone git par dépôt. Contexte projet dans son `AGENTS.md`. |
| `worktrees/{orca,herdr,…}/` | Worktrees git créés par les outils — jamais dans `/tmp` ni un HOME. |
| `scratch/` | Jetable. Pas de secrets. |
| `db/migrations/` | SQL Postgres versionné (schémas `health`, `markets`). |
| `vault/` | Vault Obsidian synchronisé. Règles : `vault/AGENTS.md`. Ne pas toucher `vault/.obsidian/`. |
| `helios/` | Données watchlist écrites par l'agent + `tools/watchlist.py` (servies par Helios). |

## Ce qui n'est PAS ici

| Dossier | Contenu | Qui y touche |
|---|---|---|
| `/srv/command-center` | scripts de déploiement / admin, compose, `.env` (secrets) | l'opérateur (`sudo command-center …`) |
| `/srv/hermes` | données de l'agent Hermes (`data/` = `/opt/data`), Postgres, Obsidian Sync | l'agent (via `/opt/data`) |
| `/srv/orca` | HOME d'Orca | Orca |
| `/srv/helios` | déploiement Helios : `.env`, état tinyauth | `command-center helios deploy` |

## Règles

- Un dépôt = un dossier `projects/<repo>` ; une tâche parallèle = une branche + un worktree dans `worktrees/`.
- Git : identité `LOUKASSS` / `loukass7@pm.me`, HTTPS via `gh`. Branche → commit → PR ; pas de push direct sur `main`/`master` sans demande.
- Secrets : jamais dans le workspace, un commit, le vault ou un handoff. Ils vivent dans les `.env` hors workspace.
- Suppression de données (projets, vault, Postgres) : uniquement sur confirmation explicite.
- Déployer = `sudo command-center deploy <hermes|orca|helios|herdr>` ou `sudo command-center helios deploy`,
  lancé par l'opérateur (ou une session hôte qu'il pilote). Le conteneur Hermes n'a ni Docker ni sudo.
- Le code du workspace est modifiable par l'agent : relire un diff avant de le déployer avec `sudo`.
