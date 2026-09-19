# Hermes Agent — VPS stack

Hermes Agent + [Hermes Workspace](https://github.com/outsourc-e/hermes-workspace) behind Traefik
(HTTPS via Cloudflare DNS-01), with `claude` / `codex` / `grok` CLIs authenticated through your
subscriptions (no API keys), `gh`, Python 3.13, a PostgreSQL database for your own structured
data (weight, training logs…), an optional Obsidian Sync sidecar,
host-persistent storage the agent can read/write, nightly encrypted backups to Backblaze B2,
weekly auto-updates, a self-healing timer, and an optional [Orca](https://www.onorca.dev) remote
server **on the host** to drive the same CLIs yourself, from desktop or phone — as its own user,
with Docker and sudo, so your Orca sessions can deploy on this VPS.

```
Tailnet ──53────▶ hermes-dns  (DNS_ZONE + *.DNS_ZONE → this VPS; Tailscale split DNS points here)
Tailnet ──443───▶ traefik ──▶ hermes-agent  ┬ :3000 hermes-workspace (https://WORKSPACE_HOST, password)
                    │                        ├ :8642 gateway API   (127.0.0.1 only)
                    └▶ docker-socket-proxy   ├ :9119 dashboard     (127.0.0.1 only, for the workspace)
Tailnet ──9120─────────────────────────────▶ └ :9120 hermes-dashboard (basic auth, for Hermes Desktop)
Tailnet ──5432──▶ hermes-postgres  (PostgreSQL 17: your tables; the agent reaches it as hermes-postgres:5432)
Tailnet ──6768──▶ orca.service on the host (optional, orca.sh: claude/codex/grok yourself, from the Orca desktop/mobile app)

/srv/hermes/                 (owned by the operator user `hermes`)
├── stack/                   this repo: compose, scripts, .env
├── data/       → /opt/data (agent) + /home/workspace/.hermes (workspace)
├── workspace/  → /workspace (both)  ← drop files here for the agent; vault/ inside
├── traefik/    → acme.json
├── postgres/   data/ (live cluster, postgres-owned) + dumps/ (daily pg_dumpall, backed up)
└── obsidian/   → /data (obsidian-sync HOME: Obsidian Sync credentials)
```

`hermes-workspace` shares the agent container's network namespace, so the dashboard and the
gateway API stay loopback-only (no auth gate, no exposure) while the workspace still reaches
them. Nothing is reachable from the Internet: Traefik (80/443), the Desktop backend, the DNS and
Orca all bind the Tailscale IP (`DESKTOP_BIND`), and `harden.sh`'s firewall (default deny, allow
on `tailscale0`) is the second layer. Traefik reads container labels through
`docker-socket-proxy` (GET-only view of the Docker API: containers, events, version — no `/info`,
no POST) instead of the raw socket. Every container runs with `no-new-privileges` and a
`pids_limit`; traefik, the socket proxy and the DNS drop all capabilities (plus the one or two
they need) and have a read-only root filesystem.

## Prerequisites

- Fresh **Ubuntu 22.04+** VPS (`harden.sh` is Ubuntu-only; the stack itself also runs on Debian 12+,
  without the isolation), root or sudo. Sized for **8 vCPU / 16 GB** with the defaults
  (`AGENT_MEM_LIMIT=10g`, `AGENT_CPUS=6`; lower them for a smaller box). No inbound port needed.
- A Cloudflare zone containing `<WORKSPACE_HOST>` (for the Let's Encrypt DNS-01 challenge only —
  no public A record: the tailnet resolves the name through the stack's own DNS, see below).
- Cloudflare API token with **Zone → DNS → Edit** *and* **Zone → Zone → Read** on that zone
  (Traefik's ACME client looks the zone id up before writing the challenge record).
- A Tailscale account (the VPS, your laptop and phone join the same tailnet).
- The subscriptions you want to use: Claude **Max** (Anthropic OAuth needs Max + extra usage credits; Pro is not supported), ChatGPT Plus/Pro (Codex), SuperGrok / X Premium+.

## Install

### 0. Isolate the VPS first (`harden.sh`, Ubuntu)

Run once as root on the fresh VPS, before the stack:

```bash
apt-get update && apt-get install -y git     # cloud images ship without git
git clone <this repo> hermes-setup && cd hermes-setup
sudo ./harden.sh                 # sudo TS_AUTHKEY=tskey-... ./harden.sh  for a non-interactive Tailscale join
                                 # sudo HARDEN_ASSUME_YES=1 ./harden.sh  skips the lockout check (only if you verified Tailscale SSH yourself)
```

(Variables go *after* `sudo`: `VAR=x sudo cmd` is stripped by sudo's `env_reset`. Same for
`install.sh`.)

What it does:

- creates the operator user **`hermes`** (sudo without password, `docker` group), generates an
  **ed25519 key pair**, installs the public key and **prints both keys once** — save the private
  key as `~/.ssh/hermes_vps` on your laptop; it is shredded from the server afterwards
  (`--keep-key` to retain, `--rotate-key` to regenerate);
- installs **Tailscale** and joins your tailnet (interactive URL, or `TS_AUTHKEY`). Every
  tailnet device then reaches SSH, Traefik, the Desktop backend and Orca on this node: on a
  shared tailnet, restrict that with a Tailscale ACL (e.g. only your own tagged devices to
  `tcp:22,443,6768,9120` of this host);
- **ufw**: deny in by default, allow everything on `tailscale0`, only UDP 41641 on the WAN NIC;
  a `DOCKER-USER` block makes Docker-published ports unreachable from the Internet even if one
  were ever bound to 0.0.0.0 (they all bind the Tailscale IP) but reachable from the tailnet
  (`--keep-public-ssh` keeps rate-limited SSH on WAN);
- **anti-lockout**: the firewall auto-disables after 10 min unless you confirm that
  `ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>` works from another terminal;
- then **sshd** hardening: keys only, no root, `AllowUsers hermes`, `MaxAuthTries 3`;
- **unattended-upgrades** (security + updates + Docker/Tailscale repos), unused-package cleanup,
  automatic reboot at 02:00 when required (before the 03:00 backup and the Sunday 03:30 update), `needrestart` in auto mode;
- fail2ban (sshd), sysctl hardening, journald limits, Docker `daemon.json` (live-restore, log
  rotation), `/srv/hermes` owned by `hermes` with a copy of this repo in `/srv/hermes/stack`.

No public DNS record is needed: the stack runs its own DNS for the tailnet (below). The
workspace is only reachable from your tailnet; TLS still works because DNS-01 needs no inbound
port. (A Cloudflare A record `<WORKSPACE_HOST>` → Tailscale IP, DNS-only/grey cloud, is a
harmless fallback for devices that do not use the tailnet DNS.)

In the Tailscale admin console, open the machine and **Disable key expiry**: with SSH closed on
the WAN, an expired node key (180 days by default) means a trip through the provider's console.

Re-running `harden.sh` later: from `/srv/hermes/stack` (`sudo /srv/hermes/stack/harden.sh`), not
from the original clone — an existing `/srv/hermes/stack` is never overwritten.

### 1. Stack

```bash
ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>
cd /srv/hermes/stack
sudo ./install.sh     # installs Docker if needed, asks host / email / CF token, builds, starts
sudo ./auth.sh        # OAuth logins (menu)
```

`install.sh` is idempotent. It writes `.env` (generated secrets: `API_SERVER_KEY`,
`HERMES_PASSWORD`, `DESKTOP_PASSWORD`, `DESKTOP_SECRET`), creates `/srv/hermes/*` owned by `hermes`
(fallback: the invoking `SUDO_UID`; credential dirs are mode 700), sets `DESKTOP_BIND` to the
Tailscale IP, builds the derived image, starts the stack, installs the systemd timers and sets
the agent's working directory to `/workspace`. Everything under `/srv/hermes` belongs to `hermes`,
so day-to-day `docker compose …` and `git pull` from `/srv/hermes/stack` work without sudo
(docker group; do not `sudo git pull` — root's git refuses a repo it does not own).

Re-running it after changes is the normal way to apply them; it recreates `hermes-agent` (and
the containers sharing its namespaces), so running sessions restart. It keeps a `DESKTOP_BIND`
you set by hand and always re-derives `HERMES_UID/GID` from the `hermes` user.

After step 2 below (the name only resolves through the tailnet DNS), open
`https://<WORKSPACE_HOST>` and log in with `HERMES_PASSWORD` (printed at the end of install,
stored in `.env`). The install summary prints secrets: clear the scrollback if the terminal is
shared or recorded.

### 2. Tailnet DNS (split DNS)

`hermes-dns` (`dns/`: dnsmasq on Alpine, 32 MB) listens on the Tailscale IP, port 53, and answers
`DNS_ZONE` and every name under it with that IP — nothing else, no forwarding. `DNS_ZONE`
defaults to `WORKSPACE_HOST`; set a wider one in `.env` (e.g. `DNS_ZONE=hermes.example.com` with
`WORKSPACE_HOST=workspace.hermes.example.com`) and every future `something.hermes.example.com`
resolves to the VPS too — handy for your own projects behind this Traefik (join the `proxy`
network, add labels, get a certificate from the same resolver). Then, once, in the
[Tailscale admin console](https://login.tailscale.com/admin/dns) → DNS:

1. Nameservers → **Add nameserver → Custom** → the VPS Tailscale IP (`100.x.y.z`) →
   **Restrict to domain** → `DNS_ZONE`. (MagicDNS may stay on or off; it is not required.)
2. On each device, Tailscale's **Use Tailscale DNS settings** must be enabled (the default).

From then on every device on the tailnet (laptop, phone, the VPS itself) resolves
`https://<WORKSPACE_HOST>` — and only that zone — through the VPS. Check: `sudo ./auth.sh status`
(dns line), `nslookup <WORKSPACE_HOST>` from your laptop; `docker compose logs dns`.
`install.sh` refuses a `WORKSPACE_HOST` outside `DNS_ZONE` and warns when another resolver already
owns port 53 on all interfaces (Ubuntu's `systemd-resolved` only binds `127.0.0.53`, no clash).

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
| `messaging` | `hermes gateway setup` — Telegram / Discord / Slack / WhatsApp… wizard, then offers to recreate the gateway. Bots only make outbound connections: nothing to open, tailnet-only stays intact | `/srv/hermes/data/.env` |
| `obsidian` | `ob login` + `ob sync-setup --vault <id|name> --path /vault` in the `obsidian-sync` image (Obsidian Sync subscription required), then enables the `obsidian` compose profile and starts the sidecar (`ob sync --continuous`) | `/srv/hermes/obsidian/` (`OBSIDIAN_DIR`), vault `.obsidian/` |
| `status` | shows all of the above + update hold / backup timer / orca (host) / obsidian | |
| `shell` | bash inside the agent container (`HOME=/opt/data/home`, cwd `/workspace`) | |
| `chat [args]` | `hermes chat` inside the agent container — the interactive CLI on the same config, sessions and `/workspace` as the gateway (`chat --tui`, `chat --resume <session>`) | |

Menu numbers work as arguments too (`sudo ./auth.sh 8`). `obsidian` and `status` (as arguments)
work while the agent container is down; everything else, and the menu itself, needs it running.
Orca has its own script: `orca.sh` (below).

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

In the app: **Settings → Gateways → Remote gateway** → `http://<tailscale-ip>:9120` (port =
`DESKTOP_PORT`) → **Sign in** with `DESKTOP_USERNAME` / `DESKTOP_PASSWORD` from `.env` (printed at
the end of `install.sh`).
`DESKTOP_SECRET` keeps you signed in across restarts. Check the gate:
`curl -s http://<tailscale-ip>:9120/api/status | jq '.auth_required, .auth_providers'` → `true`, `["basic"]`.

Username/password is the provider recommended by Hermes for VPN/tailnet access; for a
public-internet backend Hermes recommends the Nous Portal OAuth provider instead — not needed here.

## Orca remote server (optional, on the host)

[Orca](https://www.onorca.dev/docs/remote-servers) lets you run Claude Code / Codex / Grok
sessions yourself — parallel agents, worktrees, diff review — from the Orca desktop app or the
mobile app, with the runtime on the VPS. It is deliberately **not a container**: `orca.sh`
installs it on the host as `orca.service`, running as a dedicated system user **`orca`** (docker
group, passwordless sudo) with its own `HOME` (`ORCA_HOME`, default `/srv/hermes/orca`, mode
0700). Being on the host, a session can `docker compose up` a project for real on this VPS, next
to this stack (attach it to the `proxy` network and reuse the stack's Traefik with labels — 80/443
are taken).

Why its own user and HOME, not the agent's: the agent container writes `/srv/hermes/data/home`
and `/srv/hermes/workspace` as uid `HERMES_UID`, and anything a session on the host loads from
there — `~/.claude/settings.json` hooks, `~/.gitconfig` (`core.hooksPath`), `~/.codex/config.toml`
MCP commands, `.git/hooks` of a checkout — would run as a sudo user. So Orca never reads those
directories: `orca.sh install` copies only the agent's **credential files** (`.claude/.credentials.json`,
`.codex/auth.json`, `.grok/auth.json`, `gh/hosts.yml`) into `ORCA_HOME` (same accounts, no second
login; both sides refresh their tokens on their own), and sessions start in `ORCA_HOME/work`.

```bash
sudo ./orca.sh install         # user orca, Xvfb + Electron libs, Node 22, claude/codex/grok/gh, Orca, orca.service, logins; prints the pairing link
sudo ./orca.sh pair mobile     # phone: scan the printed QR (phone on the tailnet); `pair desktop` = runtime link (each restarts orca.service)
sudo ./orca.sh creds           # re-copy the agent's logins after `auth.sh <cli>` (or if Orca's copy expired)
sudo ./orca.sh login claude    # or log in as user orca with a different account (claude|codex|grok|gh)
sudo ./orca.sh status | logs
```

Sharing code with the agent: through git remotes (`gh` is logged in on both sides). Do not point
Orca at `/srv/hermes/workspace` — it belongs to the container's uid, so git refuses it ("dubious
ownership") and the point of the separate user is that Orca never executes what the agent wrote
in place. Clone the repo under `ORCA_HOME/work`, push, let the agent pull (and vice versa).

Desktop app: Settings → Remote Orca Servers → Add Server → paste the `orca://pair?…` link. Orca
prints one pairing link per run (runtime link by default, mobile-scoped with `--mobile-pairing`);
already-paired devices keep their tokens, so switching modes to add another device is fine. The
printed browser URL (`http://<tailscale-ip>:6768/web-index.html#pairing=…`) also works from any
browser on the tailnet. **Treat the link like a root password**: whoever holds it runs commands as
`orca` (passwordless sudo, docker group). Orca listens on `ORCA_PORT` (6768), advertises
`DESKTOP_BIND` (the Tailscale IP) to clients, and the firewall from `harden.sh` keeps it off the
Internet. Orca prints the link on every start, so it also sits in `journalctl -u orca` (root /
`adm` readable, kept up to a month); `orca.sh` only echoes it to a terminal, never into the
`hermes-update` journal. Orca state (projects, pairings, secrets — unencrypted, no keyring) lives
in `ORCA_HOME/.config/orca`; `ORCA_HOME` is part of the backups when it exists.

Layout: `/opt/orca/<tag>/` (extracted AppImage, sha512-verified against the release manifest),
`/opt/orca/current` and `/opt/orca/previous` symlinks, `/usr/local/bin/orca`, `/etc/sudoers.d/91-orca`,
`/etc/orca.env` (rendered from `.env`: `DESKTOP_BIND`, `ORCA_PORT`, `ORCA_PAIRING`) and `orca.service`
(`MemoryMax` = `ORCA_MEM_LIMIT`). After editing those in `.env`: `sudo ./orca.sh update --force`.
Versions: with `ORCA_VERSION=latest` (default) `orca.sh update` — run by `update.sh` at the end
of every weekly update — resolves the current GitHub release, installs it only when it changed
(sessions are restarted then), and refreshes the host CLIs with `npm -g`. `sudo ./orca.sh rollback`
goes back to the previous release and puts Orca updates on hold (`/opt/orca/.hold`) until
`sudo ./orca.sh update --force`. Pin with `ORCA_VERSION=vX.Y.Z` in `.env`. `sudo ./orca.sh remove`
drops the service, the sudoers fragment and `/opt/orca` (keeps Node, the CLIs, the `orca` user and
`ORCA_HOME`: `sudo userdel -r orca` to drop those too).

The agent container itself has no Docker (only Traefik sees the daemon, read-only, through the
socket proxy): Hermes can write a compose project, you or an Orca session deploy it — from a
checkout under `ORCA_HOME/work`, after reviewing what it does (a compose file is root on the host).

## PostgreSQL (your data)

`hermes-postgres` (`postgres:17-alpine`, 512 MB cap, data checksums) is a plain database for
whatever you want kept in tables — weight, training sessions, anything the agent should query
or fill for you. `install.sh` generates `POSTGRES_PASSWORD`; user and database default to
`hermes` (`.env`: `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PORT`, `POSTGRES_DIR`, `POSTGRES_MEM_LIMIT`).

- **Agent**: the container has `psql`/`pg_dump` and the libpq variables (`PGHOST=hermes-postgres`,
  `PGUSER`, `PGPASSWORD`, `PGDATABASE`) plus `DATABASE_URL`, so "store my weight in the database"
  just works — `psql -c "…"` in its terminal, or any Python/Node client with `DATABASE_URL`.
  The workspace terminal (same network namespace) resolves `hermes-postgres` too.
- **You**: `postgresql://hermes:<POSTGRES_PASSWORD>@<tailscale-ip>:5432/hermes` from psql,
  DBeaver, Grafana… on any tailnet device (port bound to `DESKTOP_BIND`, firewalled like the rest).
- **Your own projects** (Orca-deployed compose): join the network `hermes-data`
  (`networks: {data: {external: true, name: hermes-data}}`) and use the same URL as the agent.
- **Backups**: `backup.sh` takes a `pg_dumpall --clean` into `/srv/hermes/postgres/dumps/`
  (7 kept) before the restic upload; the live `data/` dir is deliberately not uploaded (not
  consistent while running). Restore: `zcat dumps/pg_dumpall-<ts>.sql.gz | sudo docker exec -i
  hermes-postgres psql -U hermes -d postgres` (the agent must not hold connections: `--clean`
  drops and recreates the database).
- Major upgrades (17 → 18) are manual (`pg_dumpall`, change the tag, restore); `update.sh` only
  follows `17-alpine` minor releases.

## Obsidian vault (optional)

The agents write Markdown into `/workspace/<OBSIDIAN_VAULT_DIR>` (default `vault`, host
`/srv/hermes/workspace/vault`). The `obsidian-sync` sidecar — a separate ~350 MB
`node:22-slim` image with only `obsidian-headless`, running `ob sync --continuous` as the same
UID — is the **only** sync client on that vault and pushes/pulls it to your Obsidian Sync
remote vault with end-to-end encryption. The agent image does not contain `ob`, and the
Obsidian credentials live in `/srv/hermes/obsidian`, outside the agent's HOME.

`sudo ./auth.sh obsidian` builds the image, runs the login, lists your remote vaults and asks
which one to link (ID or name; an empty answer creates a new end-to-end encrypted vault), asks
the E2E password, then starts the sidecar. Checks: `sudo ./auth.sh status`,
`docker compose logs -f obsidian-sync`.

## Backups (Backblaze B2, restic)

```bash
sudo ./backup.sh setup       # bucket + application key → .env, generates RESTIC_PASSWORD, init, enables the nightly timer
sudo ./backup.sh run         # what hermes-backup.timer runs at 03:00 — run the first one by hand, during the day
sudo ./backup.sh snapshots
sudo ./backup.sh restore <id|latest> /srv/restore
sudo ./backup.sh check       # integrity (reads 5 % of the data)
sudo ./backup.sh restic <args…>   # raw restic (unlock, ls, dump, key add…)
sudo journalctl -u hermes-backup  # history
```

B2: private bucket + an application key restricted to it (`listBuckets, listFiles, readFiles,
writeFiles, deleteFiles`). restic (in a throwaway `restic/restic` container) encrypts client-side
and deduplicates; retention 7 daily / 4 weekly / 6 monthly, prune on Sundays.

Each run first takes `hermes backup` inside the agent (consistent `state.db` snapshot via the
SQLite backup API, kept as `/srv/hermes/data/backups/hermes-backup-<ts>.zip`, 2 newest), then
writes a fresh `pg_dumpall` of `hermes-postgres` to `postgres/dumps/`, then uploads `data/`,
`workspace/`, `obsidian/`, `postgres/dumps/`, `traefik/acme.json` and `stack/.env` — minus
`node_modules`, venvs, caches, browser profiles.

**Keep `RESTIC_PASSWORD`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` and `RESTIC_REPOSITORY` outside the
VPS** (`setup` prints all four). Without them the repository cannot be read. Never change
`RESTIC_PASSWORD` by editing `.env` — that orphans the repository; use
`sudo ./backup.sh restic key add` / `key remove`.

Nothing alerts on a failed backup: check `sudo ./auth.sh status` or `journalctl -u hermes-backup`
now and then.

### Disaster recovery on a fresh VPS

1. `sudo ./harden.sh` (puts this repo in `/srv/hermes/stack`), then as `hermes`:
   `cd /srv/hermes/stack && cp .env.example .env` and add `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
   `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`.
2. `sudo ./install.sh` — installs Docker, asks host / email / CF token, starts an empty stack
   and, since `.env` has the restic credentials, enables the nightly backup timer: run
   `sudo systemctl disable --now hermes-backup.timer` right away so the empty stack does not
   become `latest` before you restore (re-enable it at the end).
3. `sudo ./backup.sh snapshots`, then `sudo ./backup.sh restore <id> /srv/restore` and the printed
   `sudo` lines (stack down, `rsync`/`cp` of `data/`, `workspace/`, `obsidian/`, `postgres/dumps/`,
   `acme.json`, `.env`).
4. `sudo ./install.sh` again (re-chowns for this host's `hermes` uid, sets `DESKTOP_BIND`,
   recreates), then load the newest dump into the fresh PostgreSQL (printed `zcat … | psql` line).
   If Orca was installed: `sudo ./orca.sh install`, then the printed `rsync` of `ORCA_HOME`
   (pairings, state). Finally `sudo rm -rf /srv/restore` (it holds every secret in clear).

All OAuth logins, memory, sessions and skills come back with `data/`. Hermes-only alternative
into a running agent: `sudo ./auth.sh shell` → `hermes import /opt/data/backups/<zip>`.

## Files & Python

- Put files in `/srv/hermes/workspace` on the VPS → visible as `/workspace` (agent cwd, workspace
  file browser + terminal).
- Python 3.13 ships in the image (venv `/opt/hermes/.venv`, no `pip`, `uv` is available); the
  agent runs scripts through its terminal tool. Extra libraries: add a
  `RUN uv pip install --python /opt/hermes/.venv/bin/python <pkg>` line to `hermes/Dockerfile` and
  run `sudo ./update.sh`. The same command from `sudo ./auth.sh shell` works until the next image
  rebuild. Commit such edits to your fork: only `.env` of the checkout is backed up, and `git pull`
  will not merge over uncommitted changes.

## Operations

```bash
docker compose ps
docker compose logs -f hermes-agent        # gateway + dashboard (s6-supervised)
docker compose logs -f hermes-workspace
docker compose logs -f traefik             # ACME / routing
sudo ./auth.sh shell                        # shell in the agent container
sudo ./auth.sh status                       # logins, update hold, backup timer, orca (host), obsidian
sudo ./update.sh                            # rebuild on latest base image (no cache), pull, recreate (auto-rollback if unhealthy)
sudo ./update.sh rollback                   # back to the images that ran before the last update, and hold
sudo ./update.sh resume                     # lift the hold
sudo ./heal.sh                              # what hermes-heal.timer does every minute
systemctl list-timers 'hermes-*'            # backup 03:00 daily, update Sun 03:30, heal every minute
```

**Updates.** Images track `:latest` (agent base, workspace, restic, obsidian-headless).
`update.sh` first tags every running image `:previous`, then rebuilds/pulls and
recreates; if `hermes-agent` or `hermes-workspace` are not healthy within a few minutes it rolls
back to `:previous` on its own and writes `.update-hold`, which makes the weekly timer skip until
`sudo ./update.sh resume` (or `--force`). `sudo ./update.sh rollback` does the same by hand — one
step back only, the next update overwrites `:previous`. Disable auto-updates:
`sudo systemctl disable --now hermes-update.timer`. Pin instead of `:latest`: `ORCA_VERSION`,
`OBSIDIAN_HEADLESS_VERSION` in `.env`; the agent base and the workspace by editing
`hermes/Dockerfile` `FROM` / the compose `image:` tag. Build cache is capped at 4 GB
(`docker builder prune`); watch `df -h /var/lib/docker`. When Orca is installed, `update.sh`
ends with `orca.sh update` (host CLIs + Orca release, own `previous`/`rollback`, not covered by
the image rollback).

**Healing.** `hermes-heal.timer` runs `heal.sh` every minute — restarts containers Docker marks
unhealthy, starts exited ones (Docker's own restart policy only reacts to a process exiting) and
recreates `hermes-agent` with its dependants when it is the one unhealthy. It stays idle when
nothing in the project runs (`docker compose down`), while `update.sh` runs, and while
`/srv/hermes/stack/.maintenance` exists — **touch that file before `docker compose stop <service>`**,
otherwise the service is back within a minute.

**Restarting the agent:** `docker compose up -d --force-recreate hermes-agent hermes-workspace hermes-dashboard` (not `restart` —
`hermes-workspace` and `hermes-dashboard` live in its network namespace and must be recreated
with it; if you do use `restart`, `heal.sh` repairs them within ~2 min). Resource limits:
`AGENT_MEM_LIMIT`, `AGENT_CPUS`, `WORKSPACE_MEM_LIMIT` (containers), `ORCA_MEM_LIMIT` (orca.service) in `.env`;
traefik/dashboard/obsidian have fixed limits in the compose file.

**Updating these scripts:** `cd /srv/hermes/stack && git pull` (as `hermes`, no sudo) then
`sudo ./install.sh`.

**Logs.** `sudo journalctl -u hermes-backup|hermes-update|hermes-heal|orca|fail2ban` (the
`hermes` user is not in `adm`, hence `sudo`), `/var/log/unattended-upgrades/`, container logs via
`docker compose logs <service>` (json-file, 20 MB × 5 per container; the DNS is service `dns`).
Traefik access log is off. There is no monitoring or alerting in this stack. Note that `TZ` in
`.env` applies to containers and restic only; the timer times above follow the host timezone
(`timedatectl`).

### Rotating secrets

| Secret | Then |
|---|---|
| `API_SERVER_KEY` | `docker compose up -d --force-recreate hermes-agent hermes-workspace hermes-dashboard` |
| `HERMES_PASSWORD` | `docker compose up -d --force-recreate hermes-workspace` |
| `DESKTOP_PASSWORD` / `DESKTOP_SECRET` | `docker compose up -d --force-recreate hermes-dashboard` |
| `CF_DNS_API_TOKEN` | `docker compose up -d --force-recreate traefik` |
| `RESTIC_PASSWORD` | `sudo ./backup.sh restic key add` (asks the new one), then `key remove <old id>` — only then edit `.env` |
| SSH key of `hermes` | `sudo /srv/hermes/stack/harden.sh --rotate-key` (a full harden run: apt upgrade, ufw reset + the lockout confirmation with the new key) |
| Orca pairings | revoke in the app (Shared Server Access) |
| CLI logins | `sudo ./auth.sh <claude\|codex\|grok\|gh>` again, then `sudo ./orca.sh creds` if Orca is installed |

Changing `WORKSPACE_HOST` / `DNS_ZONE`: edit `.env` (host inside zone), `sudo ./install.sh`
(recreates `hermes-dns` and the agent group — the router labels live on `hermes-agent`, Traefik
picks them up live), update the restricted domain of the nameserver in the Tailscale admin console;
the old certificate stays in `acme.json`, harmless.

### Uninstall

```bash
sudo systemctl disable --now hermes-backup.timer hermes-update.timer hermes-heal.timer
sudo rm /etc/systemd/system/hermes-* /etc/systemd/system/docker.service.d/10-tailscale.conf && sudo systemctl daemon-reload
cd /srv/hermes/stack && docker compose --profile '*' down --remove-orphans
docker volume rm hermes-restic-cache; docker image prune -a   # built images, their :previous tags, pulled images
sudo ./orca.sh remove              # if installed (then: sudo userdel -r orca; apt remove nodejs gh; npm -g uninstall the CLIs)
sudo rm -rf /srv/hermes            # data + every secret
```
`harden.sh` leftovers if you want the host back to stock: `ufw --force reset` (the HERMES block
in `/etc/ufw/after*.rules` included), `/etc/ssh/sshd_config.d/00-hermes-hardening.conf`,
`/etc/sudoers.d/90-hermes`, `/etc/apt/apt.conf.d/20auto-upgrades` + `52-hermes-unattended`,
`/etc/fail2ban/jail.d/sshd.local`, `/etc/sysctl.d/90-hardening.conf`,
`/etc/systemd/journald.conf.d/90-limits.conf`, `/etc/needrestart/conf.d/90-auto.conf`,
`/etc/docker/daemon.json`, `/root/hermes-ssh/`, the Tailscale and GitHub CLI apt repos +
keyrings, user `hermes`, Tailscale itself. `orca.sh install` also left NodeSource's repo,
Node, Xvfb and the Electron libraries.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | docker-socket-proxy, traefik, hermes-agent (built), hermes-workspace, hermes-dashboard (Desktop backend), postgres, dns (built), obsidian-sync (profile `obsidian`) |
| `dns/` | `alpine` + `dnsmasq`: authoritative-only answers for `DNS_ZONE`/`*.DNS_ZONE` → Tailscale IP, for Tailscale split DNS |
| `hermes/Dockerfile` | `FROM nousresearch/hermes-agent:latest` + `gh`, `tmux`, `jq`, `psql` + `@anthropic-ai/claude-code`, `@openai/codex`, `@xai-official/grok` |
| `obsidian/Dockerfile` | `FROM node:22-bookworm-slim` + `obsidian-headless` (`ob sync --continuous`) |
| `orca.sh` / `orca/orca.service` | Orca on the host: deps + Node + CLIs, sha512-verified AppImage under `/opt/orca/<tag>`, systemd unit template (install / update / rollback / pair / remove) |
| traefik (compose `command:`) | static config as flags: 80→443 redirect, docker provider via `docker-socket-proxy`, `cloudflare` ACME resolver |
| `harden.sh` | VPS isolation: user `hermes` + key, Tailscale, ufw + DOCKER-USER, sshd, auto-updates |
| `install.sh` / `auth.sh` / `update.sh` | bootstrap / logins + messaging / upgrade with `:previous` rollback |
| `backup.sh` / `heal.sh` | restic → B2 backups / self-healing |
| `systemd/` | `hermes-backup`, `hermes-update`, `hermes-heal` service + timer templates |
| `lib/common.sh` | shared helpers |
| `.env.example` | all variables |

## Troubleshooting

- **Locked out?** The 10-minute guard disables ufw if you never confirmed. Otherwise use the
  provider's console: `ufw disable`, fix Tailscale (expired node key? `tailscale up` again and
  disable key expiry in the admin console), re-run `/srv/hermes/stack/harden.sh`.
- **`ufw reload` broke the containers** — ufw flushes Docker's iptables chains:
  `systemctl restart docker`.

- **`<WORKSPACE_HOST>` does not resolve** — the device is not using the tailnet DNS: Tailscale
  admin console → DNS → nameserver `100.x.y.z` restricted to `DNS_ZONE`, and on the device
  Tailscale's "Use Tailscale DNS settings" enabled. `nslookup <WORKSPACE_HOST> <tailscale-ip>`
  must answer from anywhere on the tailnet.
- **No certificate / browser warning, or Traefik 404 with its default certificate** —
  `docker compose logs traefik`. `open /acme/acme.json: permission denied` ⇒ the ACME resolver was
  skipped and the workspace router dropped: `acme.json` must be `root:root` mode 600 (Traefik runs
  root with every capability dropped, so it cannot read a file owned by another user) —
  `sudo chown 0:0 /srv/hermes/traefik/acme.json && sudo docker restart traefik`. Otherwise check the
  Cloudflare zone and the token scope (Zone:DNS:Edit + Zone:Zone:Read — "zone could not be found" =
  Zone:Read missing). Let's Encrypt rejects `example.com` emails.
- **Workspace shows "Offline"** — inside the agent:
  `docker compose exec hermes-agent curl -s 127.0.0.1:8642/health` and
  `… 127.0.0.1:9119/api/status`. If you changed `API_SERVER_KEY` in `.env`, recreate the agent
  and its dependants (`docker compose up -d --force-recreate hermes-agent hermes-workspace hermes-dashboard`).
- **`[config-migrate] WARNING … predates version 12`** on first boot — benign; the image seeds
  the upstream example config and `hermes setup` / `hermes model` stamp the version.
- **Permission denied under `/srv/hermes`** — `HERMES_UID`/`HERMES_GID` in `.env` must match the
  directory owner; re-run `sudo ./install.sh`. Right after an update this can also mean the
  upstream image changed its uid handling: `sudo ./update.sh rollback`.
- **Update broke something** — `sudo ./update.sh rollback` (previous images, timer on hold);
  `journalctl -u hermes-update -n 100` for what happened. `sudo ./update.sh resume` when fixed.
- **A service I stopped keeps coming back** — `heal.sh`: `touch /srv/hermes/stack/.maintenance`
  first (remove it when done).
- **Browser tools crash** — `shm_size` is 1g; raise `AGENT_MEM_LIMIT` (default 10g / 6 CPUs, sized for an 8 vCPU / 16 GB VPS).
- **Backup failed** — `journalctl -u hermes-backup -n 50`; `sudo ./backup.sh restic unlock` after
  an interrupted run; `sudo ./backup.sh check` to verify the repository. A long first upload can
  be cut by the 02:00 reboot window: run the first `backup.sh run` by hand.
- **Workspace 404 / Traefik sees no router** — `docker compose logs docker-socket-proxy traefik`;
  Traefik reaches the Docker API only through the proxy on the internal `docker-api` network.
- **`hermes-dashboard` exited (137)** — expected right after an agent restart (shared PID
  namespace); `heal.sh` starts it again within a minute.
- **Local testing without root** — `ALLOW_NON_ROOT=1 ./install.sh` with `HERMES_*_DIR` pointing at
  directories you own.
