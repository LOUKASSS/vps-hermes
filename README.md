# Hermes Agent — VPS stack

Hermes Agent + [Hermes Workspace](https://github.com/outsourc-e/hermes-workspace) behind Traefik
(HTTPS via Cloudflare DNS-01), with `claude` / `codex` / `grok` CLIs authenticated through your
subscriptions (no API keys), `gh`, Python 3.13, an optional Obsidian Sync sidecar,
host-persistent storage the agent can read/write, nightly encrypted backups to Backblaze B2,
weekly auto-updates, a self-healing timer, and an optional [Orca](https://www.onorca.dev) remote
server to drive the same CLIs on the same projects yourself, from desktop or phone.

```
Internet ──443──▶ traefik ──▶ hermes-agent  ┬ :3000 hermes-workspace (public, password)
                                             ├ :8642 gateway API   (127.0.0.1 only)
                                             ├ :9119 dashboard     (127.0.0.1 only, for the workspace)
Tailnet ──9120─────────────────────────────▶ └ :9120 hermes-dashboard (basic auth, for Hermes Desktop)
Tailnet ──6768──▶ orca (optional: claude/codex/grok yourself, from the Orca desktop/mobile app)

/srv/hermes/                 (owned by the operator user `hermes`)
├── stack/                   this repo: compose, scripts, .env
├── data/       → /opt/data (agent) + /home/workspace/.hermes (workspace)
├── workspace/  → /workspace (both)  ← drop files here for the agent; vault/ inside
├── traefik/    → acme.json
└── obsidian/   → /data (obsidian-sync HOME: Obsidian Sync credentials)
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

### 0. Isolate the VPS first (`harden.sh`, Ubuntu)

Run once as root on the fresh VPS, before the stack:

```bash
git clone <this repo> hermes-setup && cd hermes-setup
sudo ./harden.sh                 # TS_AUTHKEY=tskey-... sudo ./harden.sh  for non-interactive Tailscale join
```

What it does:

- creates the operator user **`hermes`** (sudo without password, `docker` group), generates an
  **ed25519 key pair**, installs the public key and **prints both keys once** — save the private
  key as `~/.ssh/hermes_vps` on your laptop; it is shredded from the server afterwards
  (`--keep-key` to retain, `--rotate-key` to regenerate);
- installs **Tailscale** and joins your tailnet (interactive URL, or `TS_AUTHKEY`);
- **ufw**: deny in by default, allow everything on `tailscale0`, only UDP 41641 on the WAN NIC;
  a `DOCKER-USER` block makes Docker-published ports (Traefik 80/443) unreachable from the
  Internet but reachable from the tailnet (`--keep-public-ssh` keeps rate-limited SSH on WAN);
- **anti-lockout**: the firewall auto-disables after 10 min unless you confirm that
  `ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>` works from another terminal;
- then **sshd** hardening: keys only, no root, `AllowUsers hermes`, `MaxAuthTries 3`;
- **unattended-upgrades** (security + updates + Docker/Tailscale repos), unused-package cleanup,
  automatic reboot at 04:30 when required, `needrestart` in auto mode;
- fail2ban (sshd), sysctl hardening, journald limits, Docker `daemon.json` (live-restore, log
  rotation), `/srv/hermes` owned by `hermes` with a copy of this repo in `/srv/hermes/stack`.

Then in Cloudflare create the A record `<WORKSPACE_HOST>` → **Tailscale IP (100.x.y.z)**, DNS-only
(grey cloud). The workspace is only reachable from your tailnet; TLS still works because DNS-01
needs no inbound port.

### 1. Stack

```bash
ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>
cd /srv/hermes/stack
sudo ./install.sh     # installs Docker if needed, asks host / email / CF token, builds, starts
sudo ./auth.sh        # OAuth logins (menu)
```

`install.sh` is idempotent. It writes `.env` (secrets generated: `API_SERVER_KEY`,
`HERMES_PASSWORD`), creates `/srv/hermes/*` owned by `hermes` (fallback: the invoking `SUDO_UID`),
builds the derived image, starts the stack, and sets the agent's working directory to `/workspace`.
Everything under `/srv/hermes` belongs to `hermes`, so day-to-day `docker compose …` from
`/srv/hermes/stack` works without sudo (docker group).

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
| `gh` | `gh auth login --web` + `gh auth setup-git` (https pushes use the token) + git `user.name`/`user.email` | `/srv/hermes/data/home/.config/gh/`, `.gitconfig` |
| `messaging` | `hermes gateway setup` — Telegram / Discord / Slack / WhatsApp… wizard, then recreates the gateway. Bots only make outbound connections: nothing to open, tailnet-only stays intact | `/srv/hermes/data/.env` |
| `orca [desktop\|mobile]` | enables the `orca` profile, builds/starts the Orca remote server, prints the pairing link (or the mobile QR) | `/srv/hermes/data/home/.config/orca/` |
| `obsidian` | `ob login` + `ob sync-setup --path /vault` in the `obsidian-sync` image (Obsidian Sync subscription required), then enables the `obsidian` compose profile and starts the sidecar (`ob sync --continuous`) | `/srv/hermes/obsidian/` (`OBSIDIAN_DIR`), vault `.obsidian/` |
| `status` | shows all of the above + backup timer | |
| `shell` | bash inside the agent container (`HOME=/opt/data/home`, cwd `/workspace`) | |

Everything runs as the runtime user with `HOME=/opt/data/home`, which is the HOME Hermes gives
its tool subprocesses inside Docker — so the agent's own `claude -p …`, `codex exec …`,
`grok -p …`, `gh …` calls find the same credentials.

Upstream notes: xAI OAuth can return `403` on some tiers (fallback: `XAI_API_KEY`); Codex plan
quota semantics are not documented by Hermes.

## Hermes Desktop

Hermes Desktop connects to a **dashboard backend** (`hermes serve` / `hermes dashboard`) with an
auth provider. The stack runs a second dashboard instance, `hermes-dashboard`, bound
`0.0.0.0:9120` inside the agent's network namespace with the username/password provider, and
publishes it on the **Tailscale IP only** (`DESKTOP_BIND`, set by `install.sh`). The first
dashboard (9119) stays loopback and auth-free because the workspace needs it that way, and a
loopback bind rejects remote clients — hence two instances. `hermes-dashboard` runs with
`init: true` (no s6, no profile reconciler → no second gateway) and shares the agent's PID
namespace for gateway-liveness detection.

In the app: **Settings → Gateways → Remote gateway** → `http://<tailscale-ip>:9120` → **Sign in**
with `DESKTOP_USERNAME` / `DESKTOP_PASSWORD` from `.env` (printed at the end of `install.sh`).
`DESKTOP_SECRET` keeps you signed in across restarts. Check the gate:
`curl -s http://<tailscale-ip>:9120/api/status | jq '.auth_required, .auth_providers'` → `true`, `["basic"]`.

Username/password is the provider recommended by Hermes for VPN/tailnet access; for a
public-internet backend Hermes recommends the Nous Portal OAuth provider instead — not needed here.

## Orca remote server (optional)

[Orca](https://www.onorca.dev/docs/remote-servers) lets you run Claude Code / Codex / Grok
sessions yourself — parallel agents, worktrees, diff review — from the Orca desktop app or the
mobile app, with the runtime on the VPS. Here it runs as the `orca` compose service, built on the
agent image (`orca/Dockerfile`: Electron headless libs + Xvfb + the extracted AppImage), as the
same UID with `HOME=/opt/data/home` — so it uses **the same CLI logins as the agent** (no second
`claude`/`codex`/`grok`/`gh` login) and **the same `/workspace`** as the Hermes agent. Published on
the Tailscale IP only (`${DESKTOP_BIND}:6768`).

```bash
sudo ./auth.sh orca            # desktop: paste the orca://pair?… link in Settings → Remote Orca Servers → Add Server
sudo ./auth.sh orca mobile     # phone: scan the printed QR (phone on the tailnet)
```

Orca prints one pairing link per run (runtime link by default, mobile-scoped with
`--mobile-pairing`); already-paired devices keep their tokens, so switching modes to add another
device is fine. The printed browser URL (`http://<tailscale-ip>:6768/web-index.html#pairing=…`)
also works from any browser on the tailnet. Treat links like passwords; revoke under Shared
Server Access in the app. Orca state (projects, pairings, secrets — unencrypted, no keyring in
the container) lives in `data/home/.config/orca` and is part of the backups. Pin a release with
`ORCA_VERSION=vX.Y.Z` in `.env`; `update.sh` rebuilds on it.

You and the Hermes agent share the files: Orca isolates its sessions in git worktrees, but
nothing locks a plain checkout — keep agent work on branches/worktrees too.

## Obsidian vault (optional)

The agents write Markdown into `/workspace/<OBSIDIAN_VAULT_DIR>` (default `vault`, host
`/srv/hermes/workspace/vault`). The `obsidian-sync` sidecar — a separate ~350 MB
`node:22-slim` image with only `obsidian-headless`, running `ob sync --continuous` as the same
UID — is the **only** sync client on that vault and pushes/pulls it to your Obsidian Sync
remote vault with end-to-end encryption. The agent image does not contain `ob`, and the
Obsidian credentials live in `/srv/hermes/obsidian`, outside the agent's HOME.

`sudo ./auth.sh obsidian` builds the image, runs the login and vault linking, then starts the
sidecar. Checks: `sudo ./auth.sh status`, `docker compose logs -f obsidian-sync`.
No remote vault yet: `docker compose --profile obsidian run --rm obsidian-sync sync-create-remote`.

## Backups (Backblaze B2, restic)

```bash
sudo ./backup.sh setup       # bucket + application key → .env, generates RESTIC_PASSWORD, init, enables the nightly timer
sudo ./backup.sh run         # what hermes-backup.timer runs at 03:00
sudo ./backup.sh snapshots
sudo ./backup.sh restore latest /srv/restore
sudo ./backup.sh check       # integrity (reads 5 % of the data)
journalctl -u hermes-backup  # history
```

B2: private bucket + an application key restricted to it (`listBuckets, listFiles, readFiles,
writeFiles, deleteFiles`). restic (in a throwaway `restic/restic` container) encrypts client-side
and deduplicates; retention 7 daily / 4 weekly / 6 monthly, prune on Sundays.

Each run first takes `hermes backup` inside the agent (consistent `state.db` snapshot via the
SQLite backup API, kept as `/srv/hermes/data/backups/hermes-backup-<ts>.zip`, 2 newest), then
uploads `data/`, `workspace/`, `obsidian/`, `traefik/acme.json` and `stack/.env` — minus
`node_modules`, venvs, caches, browser profiles.

**Keep `RESTIC_PASSWORD`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` and `RESTIC_REPOSITORY` outside the
VPS** (`setup` prints them). Without them the repository cannot be read.

Disaster recovery on a fresh VPS: `harden.sh` → clone this repo into `/srv/hermes/stack` → put
those four values in `.env` → `sudo ./backup.sh restore latest /srv/restore` → follow the
printed `rsync` lines (they put `data/`, `workspace/`, `obsidian/`, `acme.json`, `.env` back) →
`sudo ./install.sh`. All OAuth logins, memory, sessions and skills come back with `data/`.
Hermes-only alternative into a running agent: `hermes import /opt/data/backups/<zip>`.

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
sudo ./heal.sh                              # what hermes-heal.timer does every minute
systemctl list-timers 'hermes-*'            # backup 03:00 daily, update Sun 03:30, heal every minute
```

Timers (installed by `install.sh` from `systemd/`): `hermes-update.timer` runs `update.sh`
every Sunday 03:30 (after the 03:00 backup, before the 04:30 unattended-upgrades reboot window);
`hermes-heal.timer` runs `heal.sh` every minute — restarts containers Docker marks unhealthy and
starts exited ones (Docker's own restart policy only reacts to a process exiting). It stays idle
when nothing in the project runs (`docker compose down`/`stop` for maintenance).

Restarting the agent: `docker compose up -d --force-recreate hermes-agent` (not `restart` —
`hermes-workspace` and `hermes-dashboard` live in its network namespace and must be recreated
with it; if you do use `restart`, `heal.sh` repairs them within ~2 min). Resource limits:
`AGENT_MEM_LIMIT`, `AGENT_CPUS` in `.env`.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | traefik, hermes-agent (built), hermes-workspace, hermes-dashboard (Desktop backend), orca (profile `orca`), obsidian-sync (profile `obsidian`) |
| `hermes/Dockerfile` | `FROM nousresearch/hermes-agent:latest` + `gh`, `tmux`, `jq` + `@anthropic-ai/claude-code`, `@openai/codex`, `@xai-official/grok` |
| `obsidian/Dockerfile` | `FROM node:22-bookworm-slim` + `obsidian-headless` (`ob sync --continuous`) |
| `orca/Dockerfile` | `FROM` the agent image + Electron headless libs + Xvfb + extracted Orca AppImage (`orca serve`) |
| `traefik/traefik.yml` | entrypoints 80→443 redirect, docker provider, `cloudflare` ACME resolver |
| `harden.sh` | VPS isolation: user `hermes` + key, Tailscale, ufw + DOCKER-USER, sshd, auto-updates |
| `install.sh` / `auth.sh` / `update.sh` | bootstrap / logins + messaging / upgrade |
| `backup.sh` / `heal.sh` | restic → B2 backups / self-healing |
| `systemd/` | `hermes-backup`, `hermes-update`, `hermes-heal` service + timer templates |
| `lib/common.sh` | shared helpers |
| `.env.example` | all variables |

## Troubleshooting

- **Locked out?** The 10-minute guard disables ufw if you never confirmed. Otherwise use the
  provider's console: `ufw disable`, fix Tailscale, re-run `harden.sh`.
- **`ufw reload` broke the containers** — ufw flushes Docker's iptables chains:
  `systemctl restart docker`.

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
- **Browser tools crash** — `shm_size` is 1g; raise `AGENT_MEM_LIMIT` (default 10g / 6 CPUs, sized for an 8 vCPU / 16 GB VPS).
- **Backup failed** — `journalctl -u hermes-backup -n 50`; `sudo ./backup.sh restic unlock` after
  an interrupted run; `sudo ./backup.sh check` to verify the repository.
- **`hermes-dashboard` exited (137)** — expected right after an agent restart (shared PID
  namespace); `heal.sh` starts it again within a minute.
- **Local testing without root** — `ALLOW_NON_ROOT=1 ./install.sh` with `HERMES_*_DIR` pointing at
  directories you own.
