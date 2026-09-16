# Hermes Agent — VPS stack

Hermes Agent + [Hermes Workspace](https://github.com/outsourc-e/hermes-workspace) behind Traefik
(HTTPS via Cloudflare DNS-01), with `claude` / `codex` / `grok` CLIs authenticated through your
subscriptions (no API keys), `gh`, Python 3.13, and host-persistent storage the agent can read/write.

```
Internet ──443──▶ traefik ──▶ hermes-agent  ┬ :3000 hermes-workspace (public, password)
                                             ├ :8642 gateway API   (127.0.0.1 only)
                                             └ :9119 dashboard     (127.0.0.1 only)

/srv/hermes/data       → /opt/data (agent)  +  /home/workspace/.hermes (workspace)
/srv/hermes/workspace  → /workspace (both)  ← drop files here for the agent
/srv/hermes/traefik    → acme.json
```

`hermes-workspace` shares the agent container's network namespace, so the dashboard and the
gateway API stay loopback-only (no auth gate, no exposure) while the workspace still reaches
them. Only `https://<WORKSPACE_HOST>` is published.

## Prerequisites

- Fresh Debian 12+ / Ubuntu 22.04+ VPS (2 vCPU, 4 GB RAM recommended), root or sudo, ports 80/443 open.
- DNS record `<WORKSPACE_HOST>` → VPS IP, in a Cloudflare zone.
- Cloudflare API token with **Zone → DNS → Edit** on that zone.
- The subscriptions you want to use: Claude **Max** (Anthropic OAuth needs Max + extra usage credits; Pro is not supported), ChatGPT Plus/Pro (Codex), SuperGrok / X Premium+.

## Install

```bash
git clone <this repo> hermes-setup && cd hermes-setup
sudo ./install.sh     # installs Docker if needed, asks host / email / CF token, builds, starts
sudo ./auth.sh        # OAuth logins (menu)
```

`install.sh` is idempotent. It writes `.env` (secrets generated: `API_SERVER_KEY`,
`HERMES_PASSWORD`), creates `/srv/hermes/*` owned by the invoking user (`SUDO_UID`), builds the
derived image, starts the stack, and sets the agent's working directory to `/workspace`.

Open `https://<WORKSPACE_HOST>` and log in with `HERMES_PASSWORD` (printed at the end of install,
stored in `.env`).

## Auth: subscriptions instead of API keys

All flows are headless-friendly (device code or paste-a-code). `sudo ./auth.sh <target>`:

| Target | Command run in the container | Credentials persist in |
|---|---|---|
| `hermes` | `hermes model` → choose **Anthropic** (Claude Max OAuth), **ChatGPT or Codex Subscription**, or **xAI Grok OAuth** as the agent's model provider | `/srv/hermes/data/auth.json` |
| `claude` | `claude auth login` (Claude subscription) — Hermes' `anthropic` provider reuses this refreshable login | `/srv/hermes/data/home/.claude/` |
| `claude-token` | `claude setup-token` → optionally stored as `CLAUDE_CODE_OAUTH_TOKEN` | `/srv/hermes/data/.env` |
| `codex` | `codex login --device-auth` — Hermes imports `~/.codex/auth.json` automatically | `/srv/hermes/data/home/.codex/` |
| `grok` | `grok login --device-auth` | `/srv/hermes/data/home/.grok/` |
| `gh` | `gh auth login --web` | `/srv/hermes/data/home/.config/gh/` |
| `status` | shows all of the above | |
| `shell` | bash inside the agent container (`HOME=/opt/data/home`, cwd `/workspace`) | |

Everything runs as the runtime user with `HOME=/opt/data/home`, which is the HOME Hermes gives
its tool subprocesses inside Docker — so the agent's own `claude -p …`, `codex exec …`,
`grok -p …`, `gh …` calls find the same credentials.

Upstream notes: xAI OAuth can return `403` on some tiers (fallback: `XAI_API_KEY`); Codex plan
quota semantics are not documented by Hermes.

## Files & Python

- Put files in `/srv/hermes/workspace` on the VPS → visible as `/workspace` (agent cwd, workspace
  file browser + terminal).
- Python 3.13 ships in the image; the agent runs scripts through its terminal tool. Extra
  libraries: `sudo ./auth.sh shell` → `pip install --user <pkg>` (persists in `/opt/data/.local`,
  already on PATH), or add them to `hermes/Dockerfile` and run `sudo ./update.sh`.

## Operations

```bash
docker compose ps
docker compose logs -f hermes-agent        # gateway + dashboard (s6-supervised)
docker compose logs -f hermes-workspace
docker compose logs -f traefik             # ACME / routing
sudo ./auth.sh shell                        # shell in the agent container
sudo ./update.sh                            # rebuild on latest base image, pull, recreate
```

Messaging platforms (Telegram, Discord, …): `sudo ./auth.sh shell` → `hermes setup`, then
`docker compose restart hermes-agent`. Resource limits: `AGENT_MEM_LIMIT`, `AGENT_CPUS` in `.env`.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | traefik, hermes-agent (built), hermes-workspace |
| `hermes/Dockerfile` | `FROM nousresearch/hermes-agent:latest` + `gh`, `tmux`, `jq` + `@anthropic-ai/claude-code`, `@openai/codex`, `@xai-official/grok` |
| `traefik/traefik.yml` | entrypoints 80→443 redirect, docker provider, `cloudflare` ACME resolver |
| `install.sh` / `auth.sh` / `update.sh` | bootstrap / logins / upgrade |
| `lib/common.sh` | shared helpers |
| `.env.example` | all variables |

## Troubleshooting

- **No certificate / browser warning** — `docker compose logs traefik`; check the DNS record and the
  token scope (Zone:DNS:Edit). `acme.json` must be mode 600. Let's Encrypt rejects `example.com`
  emails.
- **Workspace shows "Offline"** — inside the agent:
  `docker compose exec hermes-agent curl -s 127.0.0.1:8642/health` and
  `… 127.0.0.1:9119/api/status`. If you changed `API_SERVER_KEY` in `.env`, recreate both
  containers (`docker compose up -d --force-recreate`).
- **`[config-migrate] WARNING … predates version 12`** on first boot — benign; the image seeds
  the upstream example config and `hermes setup` / `hermes model` stamp the version.
- **Permission denied under `/srv/hermes`** — `HERMES_UID`/`HERMES_GID` in `.env` must match the
  directory owner; re-run `sudo ./install.sh`.
- **Browser tools crash** — `shm_size` is 1g; raise `AGENT_MEM_LIMIT`.
- **Local testing without root** — `ALLOW_NON_ROOT=1 ./install.sh` with `HERMES_*_DIR` pointing at
  directories you own.
