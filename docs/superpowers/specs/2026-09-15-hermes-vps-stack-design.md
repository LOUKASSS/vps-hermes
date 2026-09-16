# Hermes Agent VPS Stack — Design

Date: 2026-09-15

## Goal

Deploy Hermes Agent + Hermes Workspace on any fresh Debian/Ubuntu VPS with one
script, behind Traefik (HTTPS via Cloudflare DNS-01), using subscription OAuth
(Claude Max, ChatGPT/Codex, SuperGrok) instead of API keys, with `gh`, Python
and host-persistent storage the agents can read/write.

## Facts verified in upstream sources

- `nousresearch/hermes-agent:latest`: Debian 13.4, Python 3.13 (venv at
  `/opt/hermes/.venv`), Node 26, s6-overlay PID 1, user `hermes` UID 10000
  (remappable via `HERMES_UID`/`HERMES_GID`), `HERMES_HOME=/opt/data`,
  `VOLUME /opt/data`, `ENTRYPOINT /opt/hermes/docker/entrypoint-dispatch.sh`.
  Tool subprocess HOME inside containers = `/opt/data/home` (`terminal.home_mode: auto`).
  No `gh`, `claude`, `codex`, `grok` binaries in the image.
- Dashboard (`HERMES_DASHBOARD=1`, port 9119) fails closed on a non-loopback
  bind unless an auth provider is configured (June 2026 hardening).
  Loopback bind (`HERMES_DASHBOARD_HOST=127.0.0.1`) needs no auth.
- Gateway API server: `API_SERVER_ENABLED=true`, `API_SERVER_HOST`,
  `API_SERVER_KEY` (mandatory), port 8642, `/health`.
- Hermes providers with subscription OAuth, all headless-capable:
  `anthropic` (Claude Max: borrows `~/.claude/.credentials.json` or
  `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`), `openai-codex`
  (device code, also imports `~/.codex/auth.json`), `xai-oauth` (device code).
  Tokens stored in `/opt/data/auth.json`.
- `hermes-workspace` (`ghcr.io/outsourc-e/hermes-workspace:latest`): Node
  server on port 3000, user `workspace` UID 10010 (remappable via
  `HERMES_UID`/`HERMES_GID`), needs `HERMES_API_URL` (gateway), `HERMES_DASHBOARD_URL`
  (dashboard), `HERMES_API_TOKEN` (= `API_SERVER_KEY`), `HERMES_PASSWORD`
  (required off-loopback), `COOKIE_SECURE`, `TRUST_PROXY`. It scrapes the
  dashboard session token from the dashboard root HTML, so the dashboard must
  be reachable **unauthenticated** → must be loopback → workspace must share
  the agent's network namespace.
- CLIs: `npm i -g @anthropic-ai/claude-code @openai/codex @xai-official/grok`.
  `gh` from GitHub's apt repo.

## Architecture

```
Internet ──443──▶ traefik ──proxy net──▶ hermes-agent (netns) :3000  hermes-workspace
                                              │ :8642 gateway API (internal)
                                              │ :9119 dashboard (127.0.0.1 only)
                                              ▼
                              /srv/hermes/data  (/opt/data, /home/workspace/.hermes)
                              /srv/hermes/workspace (/workspace)
```

### Services (docker compose)

1. **traefik** (`traefik:v3`) — ports 80/443; static config `traefik/traefik.yml`:
   entrypoints `web` (redirect → `websecure`) and `websecure`; docker provider
   with `exposedByDefault: false`; certresolver `cloudflare` (DNS-01,
   `CF_DNS_API_TOKEN` env), storage `/acme/acme.json` bind-mounted from
   `/srv/hermes/traefik/acme.json` (mode 600). Docker socket mounted read-only.
   No Traefik dashboard.
2. **hermes-agent** — built from `hermes/Dockerfile` (image `hermes-agent-vps`),
   `command: ["gateway","run"]`, `restart: unless-stopped`, `shm_size: 1g`,
   env: `HERMES_UID`, `HERMES_GID`, `HERMES_DASHBOARD=1`,
   `HERMES_DASHBOARD_HOST=127.0.0.1`, `API_SERVER_ENABLED=true`,
   `API_SERVER_HOST=0.0.0.0` (bridge-internal only, never published),
   `API_SERVER_KEY`. Volumes: `/srv/hermes/data:/opt/data`,
   `/srv/hermes/workspace:/workspace`. Healthcheck: `curl 127.0.0.1:8642/health`
   and `127.0.0.1:9119/api/status`. Traefik labels live on this service
   (router `Host(\`${WORKSPACE_HOST}\`)` → service port 3000) because port 3000
   is served inside this container's network namespace. Networks: `proxy`.
   Resource limits `mem_limit: 4g`, `cpus: 2` (overridable in `.env`).
3. **hermes-workspace** — `ghcr.io/outsourc-e/hermes-workspace:latest`,
   `network_mode: "service:hermes-agent"`, `depends_on: hermes-agent
   (service_healthy)`, env: `HERMES_UID`, `HERMES_GID`,
   `HERMES_HOME=/home/workspace/.hermes`, `HERMES_WORKSPACE_DIR=/workspace`,
   `HERMES_API_URL=http://127.0.0.1:8642`,
   `HERMES_DASHBOARD_URL=http://127.0.0.1:9119`, `HERMES_API_TOKEN=${API_SERVER_KEY}`,
   `HERMES_PASSWORD`, `COOKIE_SECURE=1`, `TRUST_PROXY=1`. Volumes:
   `/srv/hermes/data:/home/workspace/.hermes`, `/srv/hermes/workspace:/workspace`.

### Derived image (`hermes/Dockerfile`)

```
FROM nousresearch/hermes-agent:latest
USER root
- apt: gh (GitHub apt repo), tmux, jq, nano, less
- npm i -g @anthropic-ai/claude-code @openai/codex @xai-official/grok
- keep ENTRYPOINT/CMD/USER semantics of the base (s6 needs to start as root)
```
No `USER` switch at the end (base image starts root, s6 drops privileges).

### Seed config (`hermes/config.seed.yaml`)

Copied to `/srv/hermes/data/config.yaml` by `install.sh` only if absent:
`terminal.cwd: /workspace`, `terminal.home_mode: auto`. Everything else
via `hermes setup` / `hermes model` / dashboard.

### Persistent storage (host)

| Host path | Container mount | Contents |
|---|---|---|
| `/srv/hermes/data` | `/opt/data` (agent), `/home/workspace/.hermes` (workspace) | config, `.env`, `auth.json`, sessions, memories, skills, `home/` (subprocess HOME: `~/.claude`, `~/.codex`, `~/.grok`, `~/.config/gh`) |
| `/srv/hermes/workspace` | `/workspace` (both) | user files; agent cwd; workspace file browser root |
| `/srv/hermes/traefik` | `/acme` | `acme.json` |

Owned by `HERMES_UID:HERMES_GID` (the VPS operator user, default = invoking
`SUDO_UID` or 1000) so the operator can `scp`/edit files directly.

### Scripts

**`install.sh`** (run as root on a fresh Debian/Ubuntu VPS, idempotent):
1. Install Docker Engine + compose plugin via `get.docker.com` if `docker` missing.
2. Create `/srv/hermes/{data,workspace,traefik}`, `touch acme.json; chmod 600`.
3. If `.env` missing: copy `.env.example`, generate `API_SERVER_KEY`,
   `HERMES_PASSWORD` (`openssl rand -hex 32` / `-base64 24`), set
   `HERMES_UID/GID`; prompt for `WORKSPACE_HOST`, `ACME_EMAIL`, `CF_DNS_API_TOKEN`
   if empty (non-interactive: fail with clear message).
4. Seed `config.yaml` if absent; `chown -R`.
5. `docker compose build --pull` then `docker compose up -d`.
6. Wait for `hermes-agent` healthy (timeout 180 s), print status, URL,
   generated `HERMES_PASSWORD`, and next step (`./auth.sh`).

**`auth.sh`** — menu (or `./auth.sh <target>`), each step runs
`docker compose exec -it -u <uid> -e HOME=/opt/data/home hermes-agent …`:
- `hermes` → `hermes model` (pick Anthropic OAuth / ChatGPT-Codex / xAI Grok OAuth; device-code flows)
- `claude` → `claude setup-token` (Claude Max) — prints token; script stores it in
  `/srv/hermes/data/.env` as `CLAUDE_CODE_OAUTH_TOKEN` when user confirms
- `codex` → `codex login --device-auth`
- `grok` → `grok login`
- `gh` → `gh auth login --web --git-protocol https`
- `status` → `hermes auth status`, `claude auth status`, `codex login status`, `gh auth status`, `ls ~/.grok/auth.json`

**`update.sh`** — `docker compose build --pull && docker compose pull && docker compose up -d`.

### Python

Base image ships Python 3.13; the agent runs scripts through its terminal tool.
Extra libs: `pip install --user` lands in `/opt/data/.local` (already on PATH,
persisted); permanent additions go in `hermes/Dockerfile`.

### Error handling

- `install.sh`: `set -euo pipefail`, checks root, OS family, required env,
  fails fast with actionable messages; safe to re-run.
- Healthchecks + `restart: unless-stopped` on all services; s6 supervises
  gateway/dashboard inside the agent container.
- Traefik: ACME failure only affects TLS; logs via `docker compose logs traefik`.

### Verification

- `docker compose config` validates.
- Local build of the derived image succeeds; `gh --version`, `claude --version`,
  `codex --version`, `grok --version`, `python3 --version` inside the image.
- On VPS: `hermes-agent` healthy, `https://$WORKSPACE_HOST` returns the
  workspace login page, cert issued by Let's Encrypt.

## Out of scope

Messaging platforms (Telegram/Discord — via `hermes setup` later), backups,
monitoring, Traefik dashboard, exposing the gateway API publicly.

## Deviations found during implementation (2026-09-16)

- `hermes/config.seed.yaml` dropped: the image's stage2 hook seeds `config.yaml` from
  `cli-config.yaml.example` on first boot. `install.sh` runs
  `hermes config set terminal.cwd /workspace` after the container is healthy instead.
- `API_SERVER_HOST=127.0.0.1` (not `0.0.0.0`): the workspace shares the network namespace,
  so loopback is enough and the gateway's "network-accessible + local terminal" warning goes away.
- `API_SERVER_KEY` must be ≥ 16 chars or the api_server refuses to start; `install.sh` enforces it.
- Traefik `v3.7`: `v3.5` fails against Docker 29 ("client version 1.24 is too old").
- `auth.sh claude` uses `claude auth login` (refreshable credentials Hermes borrows);
  `claude-token` keeps the `setup-token` path. `grok login --device-auth` for headless.
- `ALLOW_NON_ROOT=1` escape hatch in `install.sh` for local testing.

## Addendum 2026-09-16 — VPS isolation (`harden.sh`)

Tailnet-only VPS: operator user `hermes` (NOPASSWD sudo, docker group, generated ed25519 key
printed once then shredded), Tailscale (interactive or `TS_AUTHKEY`), ufw deny-in with
`allow in on tailscale0` + UDP 41641 on WAN, `DOCKER-USER` chain pre-created in
`/etc/ufw/after{,6}.rules` (RETURN tailscale0/ESTABLISHED, DROP NEW from WAN NIC) so Traefik's
published ports are tailnet-only, 10-minute `systemd-run` anti-lockout guard before sshd
hardening (`00-hermes-hardening.conf`: keys only, no root, `AllowUsers hermes`),
unattended-upgrades (Ubuntu security/updates + `site=download.docker.com`,
`site=pkgs.tailscale.com`, auto-reboot 04:30), fail2ban, sysctl, journald, Docker daemon.json.
`WORKSPACE_HOST` DNS A record must point at the Tailscale IP (DNS-only). Compose unchanged.

## Addendum 2026-09-16 — Obsidian Sync

`obsidian-headless` (`ob`, npm) baked into the derived image (Node already present). Sync runs
in a dedicated `obsidian-sync` sidecar (same image, `ob sync --continuous --path
/workspace/$OBSIDIAN_VAULT_DIR`, same UID + `HOME=/opt/data/home` so credentials under
`~/.config` are shared with the agent container and persisted). Single sync client per vault.
Compose profile `obsidian`, enabled by `auth.sh obsidian` after `ob login` + `ob sync-setup`.
Chosen over a host install to keep the VPS Docker-only and ownership aligned.
