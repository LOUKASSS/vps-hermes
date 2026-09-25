# Command center — VPS (Hermes, Orca, Helios, herdr)

One VPS, one folder per project under `/srv`, one shared workspace, and this repo as the
**command center** that deploys and administers everything:

- **Hermes** — one Hermes agent (gateway + dashboard) behind Traefik (HTTPS via Cloudflare DNS-01),
  an agent image with `claude` / `codex` / `grok` plus operator tools, PostgreSQL for your own
  structured data, an optional Obsidian Sync sidecar;
- **Orca** — optional [Orca](https://www.onorca.dev) remote server **on the host** (desktop + mobile
  Claude Code / Codex / Grok sessions);
- **Helios** — the personal dashboard (tinyauth + nginx + fitness collector), its own compose project;
- **herdr** — [herdr](https://herdr.dev) terminal workspace for coding agents on the host, with the
  [terminal-code](https://github.com/zenbu-labs/terminal-code) plugin (VS Code in the terminal);
- platform: tailnet-only Traefik + DNS, nightly encrypted backups to Backblaze B2, nightly tested updates with automatic rollback,
  a self-healing timer.

```
/srv/                       (owned by the operator user `hermes`, uid 1000 — the agent's uid too)
├── command-center/         this repo: `command-center` CLI, compose, scripts, .env, state/traefik/
├── hermes/                 Hermes agent project
│   ├── data/     → /opt/data   agent HOME: config, sessions, credentials, skills, private/, mcp/
│   ├── postgres/               data/ (live cluster) + dumps/ (daily pg_dumpall)
│   └── obsidian/               Obsidian Sync sidecar HOME
├── orca/                   Orca HOME (0700, not mounted in the agent)
├── helios/                 Helios deployment: .env (secrets), tinyauth/data
└── workspace/  → /srv/workspace (same path in the agent; /workspace = alias, also on the host)
    ├── projects/<repo>/        every git repo (helios, indo-vacation, hermes-agent…)
    ├── worktrees/{hermes,orca,herdr}/   git worktrees, per tool
    ├── vault/  scratch/  db/migrations/  helios/ (watchlist data)
    └── HERMES.md  AGENTS.md  CLAUDE.md → AGENTS.md   (rules for every agent, from agent/)
```

**One place for projects.** The Hermes agent (container), Orca sessions (host, `/srv/orca`
HOME), herdr panes and SSH shells (host, `/home/hermes` HOME) all work in `/srv/workspace`, at
the same absolute path, as the same uid: a path, a git worktree or a handoff written by one tool
is valid for all the others, with no ACL and no `chown`.

```
Tailnet ──53────▶ hermes-dns  (4km3/dnsmasq: DNS_ZONE + *.DNS_ZONE → this VPS; Tailscale split DNS)
Tailnet ──443───▶ traefik ──▶ hermes-agent  ┬ :9120 dashboard (https://HERMES_HOST, basic auth)
                    │    └──▶ helios: dashboard + tinyauth (https://dashboard.DOMAIN, auth.DOMAIN)
                    └▶ docker-socket-proxy   └ :8642 gateway API (127.0.0.1 only)
Tailnet ──9120─────────────────────────────▶ same dashboard, raw HTTP for Hermes Desktop (DESKTOP_BIND)
Tailnet ──5432──▶ hermes-postgres
Tailnet ──6768──▶ orca.service on the host (User=hermes, HOME /srv/orca, cwd /srv/workspace)
Tailnet ──22────▶ sshd → `herdr` attaches to herdr.service (User=hermes, panes in /srv/workspace)
```

Three HOMEs, one uid: `/home/hermes` (SSH + herdr), `/srv/orca` (Orca), `/srv/hermes/data/home`
(agent tools). Coding CLIs (`claude` / `codex` / `grok`) are installed both in the agent image
and on the host when Orca is installed; their credentials remain separate (only credential
files are ever copied between HOMEs: `orca.sh creds`, `herdr.sh creds` — grok and gh only; Claude
and Codex rotate a single-use refresh token, so a copied login gets revoked on its first refresh
and each HOME logs in on its own). DNS and Obsidian use
public images (`4km3/dnsmasq:2.90-r3`, `node:22-bookworm-slim`).

## Command center (`command-center`)

`/usr/local/bin/command-center` → `/srv/command-center/command-center`. Everything is idempotent.

```bash
sudo command-center                         # menu
sudo command-center status                  # /srv layout, containers, orca, helios, herdr, discord-backup, workspace
sudo command-center deploy all              # one click: platform + Hermes, Orca, Helios, herdr
sudo command-center deploy hermes|orca|helios|herdr|discord-backup
sudo command-center hermes auth|shell|chat|sync|update|rollback|backup|restart|logs|ps
sudo command-center orca pair mobile|creds|login claude|status|logs
sudo command-center helios deploy|status|logs|ps|down
sudo command-center herdr install|update|creds|login claude|status|logs|restart
sudo command-center discord-backup install|import|start|deploy|rollback|status|logs|verify|stop
sudo command-center workspace [status|fix]  # ownership, /workspace link, HERMES.md / AGENTS.md
```

`hermes` on the host runs the Hermes CLI **inside** `hermes-agent` (`/usr/local/bin/hermes` →
`bin/hermes`): same uid, `HOME=/opt/data/home` and config as the gateway, cwd = the current directory
when it is under `/srv/workspace` (else the workspace root). Any subcommand works (`hermes`,
`hermes chat --resume <id>`, `hermes config get …`); root or the `docker` group, no sudo needed for `hermes`.

The underlying scripts (`install.sh`, `auth.sh`, `agent.sh`, `orca.sh`, `helios.sh`, `herdr.sh`, `discord-backup.sh`,
`backup.sh`, `update.sh`, `heal.sh`, `harden.sh`) still work on their own; the sections below use them.

## Workspace (`/srv/workspace`)

Created by `install.sh` (`ensure_workspace`): `projects/`, `worktrees/`, `scratch/`, `db/migrations/`,
owned by `HERMES_UID`, plus the host symlink `/workspace → /srv/workspace` so paths the agent
wrote through its historical `/workspace` mount (kanban worktrees, old sessions) resolve on the host
too. `hermes-agent` mounts it twice: at `/srv/workspace` (canonical, `terminal.cwd`) and at
`/workspace` (alias). `agent.sh sync-files` writes the workspace rules: `HERMES.md` (read by Hermes),
`AGENTS.md` (Codex, Grok…), `CLAUDE.md → AGENTS.md` (Claude Code) — from `agent/HERMES.md` and
`agent/WORKSPACE.md`. `sudo command-center workspace fix` re-chowns the tree to the one owner.

Treat the workspace as **untrusted for sudo**: the agent writes there, and `helios deploy` builds
what `projects/helios` contains — review the diff before deploying.

## herdr + terminal-code (optional, on the host)

`sudo command-center herdr install` (`herdr.sh`):

- installs herdr for `hermes` with the official sha256-verified installer (`~/.local/bin/herdr`),
  seeds `~/.config/herdr/config.toml` (`onboarding = false`, new panes in `/srv/workspace`,
  worktrees in `/srv/workspace/worktrees/herdr`, native agent resume on restore);
- installs the plugin `zenbu-labs/terminal-code/herdr-plugin` (builds `tode` into `~/.local/lib/tode`)
  and the herdr integrations for `claude`, `codex`, `grok` (session restore);
- runs `herdr server` as **`herdr.service`** (`User=hermes`, `HOME=/home/hermes`, `MemoryMax=HERDR_MEM_LIMIT`):
  panes survive SSH disconnects and client detaches, and come back after a reboot;
- copies the agent's grok / gh login files into `/home/hermes` when absent (`herdr.sh creds` to
  refresh); Claude and Codex need `herdr.sh login claude|codex` (rotating refresh tokens) and adds a `~/.bashrc` block
  (`PATH`, `$WORKSPACE`, `ws`, SSH logins land in the workspace).

Use it: `ssh hermes@<tailscale-ip>` → `herdr` (detach `ctrl+b q`), or from a laptop with herdr:
`herdr --remote hermes@<tailscale-ip>`. VS Code in a pane: `tode` (or the plugin action
*Open terminal-code (right split)*); it needs a terminal with the kitty graphics protocol
(Ghostty, kitty, WezTerm) — run `tode --shortcut-setup` once. The nightly `update.sh` runs
`herdr.sh update` (new binary + `tode --upgrade`, previous binary restored if the new one does not start; the running server keeps its panes until
`sudo command-center herdr restart`).

## Helios

Code in the workspace (`/srv/workspace/projects/helios`, git), deployment in `/srv/helios`
(`.env` with the tinyauth / domain settings, `tinyauth/data`). `sudo command-center helios deploy`
runs the repo's `deploy.sh` as `hermes` with `HELIOS_ENV_FILE=/srv/helios/.env` and
`HELIOS_STATE_DIR=/srv/helios`; `HOME` is `HELIOS_CLI_HOME` (default `/srv/orca`: fitness-sync reads
its CLI logins for the quota panel, `deploy.sh` its `bws` binary and token under `.hermes/`). Compose
project `loukass`, on the `proxy` network (subnet pinned to `PROXY_SUBNET`, which tinyauth trusts).

## Discord backup bot

[discord-backup-bot](https://github.com/LOUKASSS/discord-backup-bot) takes encrypted (AES-256-GCM)
snapshots of the Discord guild at 04:00 Paris time and answers `/backup …`; a timer verifies every
archive at 05:00. `discord-backup.sh` runs it on the host as two **system units with `User=hermes`**,
taken from the repo's `deploy/` (whose tests guard their hardening: `systemd-analyze security` ≈ 1.5).

```
/srv/discord-backup/        0700 hermes — NOT mounted in the agent container, not in the workspace
├── app/src.git             bare mirror (fetched as hermes, gh credentials)
├── app/releases/<sha>/     git archive + npm ci + npm run check, then root:root read-only
├── app/current, previous   what the units run / the rollback target
├── bws.env                 BWS_ACCESS_TOKEN only (0600), copied from $HELIOS_CLI_HOME/.hermes/.env
└── var/                    backups/ (*.dsnap sealed, legacy v1 *.json), state, backup.lock, *.log
```

Secrets: the launcher (`bin/run-with-bws.py`) reads `DISCORD_BACKUP_BOT_TOKEN` and
`DISCORD_BACKUP_ARCHIVE_KEY` from Bitwarden Secrets Manager (project `hermes`) at every start, in
memory only. `bws` is `/usr/local/bin/bws` (pinned 2.0.0, sha256-checked). **Never replace
`DISCORD_BACKUP_ARCHIVE_KEY`**: every archive is sealed with it.

```bash
sudo command-center discord-backup install        # bws, tree, bws.env, tested release, units — nothing started
sudo command-center discord-backup import <dir>   # an old var/ (backups/, state) in, bot stopped
sudo command-center discord-backup start          # bot + 05:00 verify timer (asks: old instance stopped?)
sudo command-center discord-backup deploy [ref]   # new release (DISCORD_BACKUP_REF); restarted, waits READY, auto-rollback
sudo command-center discord-backup status | logs | verify | rollback | stop | uninstall
```

One instance per bot token: a second one (old host, a dev run) would also answer `/backup` and run
the 04:00 capture. `deploy` is manual — the automatic `update.sh` never touches the bot. The nightly
restic job copies `var/` (still sealed) to B2. Recovery procedures: the repo's
`docs/RECOVERY-RUNBOOK.md`, in `/srv/discord-backup/app/current/docs/`.

## Network and security

The dashboard is the image's own s6-supervised service inside `hermes-agent`; its
username/password gate is on because it binds `0.0.0.0` in the container, and the gateway API
stays loopback-only. Nothing is reachable from the Internet: Traefik (80/443), the dashboard
port and the DNS bind the Tailscale IP (`DESKTOP_BIND`); Orca listens on `0.0.0.0` and
`orca.service` pins its port to `tailscale0` + loopback with its own iptables rules;
`harden.sh`'s firewall is the second layer. Traefik reads container labels through
`docker-socket-proxy` (GET-only). Every container runs with `no-new-privileges` and a
`pids_limit`; traefik, the socket proxy and the DNS drop all capabilities (plus the few they
need) and have a read-only root filesystem.

## Prerequisites

- Fresh **Ubuntu 22.04+** VPS (`harden.sh` is Ubuntu-only; the stack itself also runs on Debian 12+,
  without the isolation), root or sudo. Sized for **8 vCPU / 16 GB** with the defaults
  (`AGENT_MEM_LIMIT=10g`, `AGENT_CPUS=6`; lower them for a smaller box). No inbound port needed.
- A Cloudflare zone containing `<HERMES_HOST>` (for the Let's Encrypt DNS-01 challenge only —
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
  tailnet device then reaches SSH, Traefik, the dashboard port and Orca on this node: on a
  shared tailnet, restrict that with a Tailscale ACL (e.g. only your own tagged devices to
  `tcp:22,443,5432,6768,9120` + `udp:53` of this host);
- **ufw**: deny in by default, allow everything on `tailscale0`, only UDP 41641 on the WAN NIC;
  a `DOCKER-USER` block makes Docker-published ports unreachable from the Internet even if one
  were ever bound to 0.0.0.0 (they all bind the Tailscale IP) but reachable from the tailnet
  (`--keep-public-ssh` keeps rate-limited SSH on WAN);
- **anti-lockout**: the firewall auto-disables after 10 min unless you confirm that
  `ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>` works from another terminal;
- then **sshd** hardening: keys only, no root, `AllowUsers hermes`, `MaxAuthTries 3`;
- **unattended-upgrades** (security + updates + Docker/Tailscale repos), unused-package cleanup,
  automatic reboot at 02:00 when required (before the 03:00 backup and the 04:00 nightly update), `needrestart` in auto mode;
- fail2ban (sshd), sysctl hardening, journald limits, Docker `daemon.json` (live-restore, log
  rotation), `/srv/{hermes,helios,workspace}` owned by `hermes` and a copy of this repo in `/srv/command-center`.

No public DNS record is needed: the stack runs its own DNS for the tailnet (below). The
dashboard is only reachable from your tailnet; TLS still works because DNS-01 needs no inbound
port. (A Cloudflare A record `<HERMES_HOST>` → Tailscale IP, DNS-only/grey cloud, is a
harmless fallback for devices that do not use the tailnet DNS.)

In the Tailscale admin console, open the machine and **Disable key expiry**: with SSH closed on
the WAN, an expired node key (180 days by default) means a trip through the provider's console.

Re-running `harden.sh` later: from `/srv/command-center` (`sudo /srv/command-center/harden.sh`), not
from the original clone — an existing `/srv/command-center` is never overwritten.

### 1. Stack

```bash
ssh -i ~/.ssh/hermes_vps hermes@<tailscale-ip>
cd /srv/command-center
sudo ./install.sh     # installs Docker if needed, asks host / email / CF token, builds, starts
sudo ./auth.sh        # OAuth logins (menu)
```

`install.sh` is idempotent. It writes `.env` (generated secrets: `API_SERVER_KEY`,
`DESKTOP_PASSWORD`, `DESKTOP_SECRET`), creates `/srv/workspace` (+ the `/workspace` host link), `data/private`,
`data/mcp` owned by `hermes` (fallback: the invoking `SUDO_UID`; credential dirs are mode 700),
copies `agent/config.yaml` into `data/` **before** the first `compose up`, sets `DESKTOP_BIND`
to the Tailscale IP, builds **only** the thin `hermes-agent` image (`compose build --pull hermes-agent`),
starts the stack, runs `CUTOVER=1 agent.sh sync`, installs the systemd timers and sets
the agent's working directory to `/srv/workspace`. Everything under `/srv` belongs to `hermes`
(except Traefik's `state/traefik/acme.json`, root 0600),
so day-to-day `docker compose …` and `git pull` from `/srv/command-center` work without sudo
(docker group; do not `sudo git pull` — root's git refuses a repo it does not own).

Re-running it after changes is the normal way to apply them; it recreates `hermes-agent`, so
running sessions restart. It keeps a `DESKTOP_BIND` you set by hand and always re-derives
`HERMES_UID/GID` from the `hermes` user. Fresh `.env` uses `HERMES_WORKSPACE_DIR=/srv/workspace`
and pins `OBSIDIAN_HEADLESS_VERSION=0.0.14` (not `latest`).

After step 2 below (the name only resolves through the tailnet DNS), open
`https://<HERMES_HOST>` and sign in with `DESKTOP_USERNAME` / `DESKTOP_PASSWORD` (printed at the
end of install, stored in `.env`; an external secret source in Hermes' `config.yaml` can override
them — see *Dashboard login* below). The install summary prints secrets: clear the scrollback if
the terminal is shared or recorded.

### 2. Tailnet DNS (split DNS)

`hermes-dns` (`4km3/dnsmasq:2.90-r3`, 32 MB) listens on the Tailscale IP, port 53, and answers
`DNS_ZONE` and every name under it with that IP — nothing else, no forwarding. `DNS_ZONE`
defaults to `HERMES_HOST`; set a wider one in `.env` (e.g. `DNS_ZONE=hermes.example.com` with
`HERMES_HOST=dash.hermes.example.com`) and every future `something.hermes.example.com`
resolves to the VPS too — handy for your own projects behind this Traefik (join the `proxy`
network, add labels, get a certificate from the same resolver). Then, once, in the
[Tailscale admin console](https://login.tailscale.com/admin/dns) → DNS:

1. Nameservers → **Add nameserver → Custom** → the VPS Tailscale IP (`100.x.y.z`) →
   **Restrict to domain** → `DNS_ZONE`. (MagicDNS may stay on or off; it is not required.)
2. On each device, Tailscale's **Use Tailscale DNS settings** must be enabled (the default).

From then on every device on the tailnet (laptop, phone, the VPS itself) resolves
`https://<HERMES_HOST>` — and only that zone — through the VPS. Check: `sudo ./auth.sh status`
(dns line), `nslookup <HERMES_HOST>` from your laptop; `docker compose logs dns`.
`install.sh` refuses a `HERMES_HOST` outside `DNS_ZONE` and warns when another resolver already
owns port 53 on all interfaces (Ubuntu's `systemd-resolved` only binds `127.0.0.53`, no clash).

The DNS network has no Internet egress. Patching dnsmasq is a pin bump of `4km3/dnsmasq:2.90-r3`
(monthly / on CVE), not an image rebuild.

## Auth: subscriptions instead of API keys

All flows are headless-friendly (device code or paste-a-code). `sudo ./auth.sh <target>`:

| Target | Command | Credentials persist in |
|---|---|---|
| `hermes` | `hermes model` inside the agent → **Anthropic** (Claude Max OAuth), **ChatGPT or Codex Subscription**, or **xAI Grok OAuth** | `/srv/hermes/data/auth.json` |
| `claude` | `claude auth login` inside the agent | `/srv/hermes/data/home/.claude/` |
| `claude-token` | `claude setup-token` (1-year token, nothing to refresh), stored for Hermes — **recommended** for the Claude Subscription DirectSDK provider | `/srv/hermes/data/.env` (`CLAUDE_CODE_OAUTH_TOKEN`) |
| `codex` | `codex login --device-auth` inside the agent | `/srv/hermes/data/home/.codex/` |
| `grok` | `grok login --device-auth` inside the agent | `/srv/hermes/data/home/.grok/` |
| `gh` | `gh auth login --web` + `gh auth setup-git` + git identity (`GH_CONFIG_DIR` / `GIT_CONFIG_GLOBAL`) | `/srv/hermes/data/home/.config/gh/`, `.gitconfig` |
| `messaging` | `hermes gateway setup` — Telegram / Discord / Slack / WhatsApp… then offers to recreate the gateway | `/srv/hermes/data/.env` |
| `obsidian` | `ob login` + `ob sync-setup` in the `obsidian-sync` sidecar (`node:22-bookworm-slim`; `compose pull`, no image build), then starts `ob sync --continuous` | `/srv/hermes/obsidian/` |
| `status` | hermes providers, gh, messaging, update hold, backup timer, dashboard gate, postgres, dns, orca (host User=hermes), obsidian | |
| `shell` | bash inside the agent container (`HOME=/opt/data/home`, cwd `/srv/workspace`) | |
| `chat [args]` | `hermes chat` inside the agent — same config, sessions and workspace as the gateway | |

Orca keeps separate host-side CLI credentials. Configure those, when needed, with
`sudo ./orca.sh login claude|codex|grok`.

Menu numbers work as arguments too (`sudo ./auth.sh 9`). `obsidian` and `status` (as arguments)
work while the agent container is down; everything else, and the menu itself, needs it running.

Hermes talks to models via `hermes model` / `auth.json` / OAuth providers (`anthropic`,
`openai-codex`, `xai-oauth`). Claude / Codex / Grok can run in the agent container; Orca offers
separate operator-driven sessions on the host.

Upstream notes: xAI OAuth can return `403` on some tiers (fallback: `XAI_API_KEY`); Codex plan
quota semantics are not documented by Hermes.

## Dashboard and the single agent

The Hermes dashboard (`hermes dashboard`: chat, sessions, skills, config, cron, kanban) runs as
the image's own supervised service inside `hermes-agent`, bound `0.0.0.0:9120` in the container
with the bundled username/password provider (`DESKTOP_USERNAME` / `DESKTOP_PASSWORD`,
`DESKTOP_SECRET` signs the login cookies). Two ways in, both tailnet-only:

- **Browser**: `https://<HERMES_HOST>` — Traefik terminates TLS and forwards to the dashboard,
  which does its own authentication.
- **Hermes Desktop**: **Settings → Gateways → Remote gateway** → `https://<HERMES_HOST>` (or the
  raw port `http://<tailscale-ip>:9120`, `DESKTOP_PORT`, published on `DESKTOP_BIND`) → **Sign in**.

Check the gate: `curl -s http://<tailscale-ip>:9120/api/status | jq '.auth_required, .auth_providers'`
→ `true`, `["basic"]`. Gateway liveness: `curl -s 127.0.0.1:8642/health` inside the agent.

**Dashboard login.** The compose file passes `DESKTOP_USERNAME` / `DESKTOP_PASSWORD` /
`DESKTOP_SECRET` as `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` / `_SECRET`. Hermes
loads its environment in layers, and an external secret source configured in the agent's
`config.yaml` (`secrets.bitwarden`: Bitwarden Secrets Manager, or another provider) is applied
*after* the container environment and overrides it. If such a source defines those three
variables, **its values are the effective login**, not the `DESKTOP_*` ones printed by
`install.sh`. Check: a wrong password lands in `data/logs/dashboard-auth.log`;
`sudo ./auth.sh status` (dashboard line) shows the gate and the URL.

There is **one** agent: `HERMES_HOME=/opt/data`, command `hermes gateway run`, healthcheck
`/health`. Skills are the union under `data/skills/` (synced from this repo). No sticky
`data/active_profile`, no gateway multiplex, no named-profile routing. `hermes` without `-p`
edits the default config.

## Agent as code (`agent/`, `skills/`, `agent.sh`)

Persona, config seed, skills and health MCP live in this repo and are copied onto
`/opt/data` by `agent.sh` (not `hermes profile install`):

```
agent/SOUL.md          always overwritten on sync (short, French)
agent/USER.md          seeded if absent; live USER.md is left in place
agent/config.yaml      fresh install only (copied before first compose up)
agent/plugins.txt      superpowers pin
agent/setup.sh         builds hevy / yazio / renpho into /opt/data/mcp/
skills/                union of skills (plus constraints/*)
mcp/                   MCP sources + lockfiles → data/mcp-src/
```

```bash
sudo CUTOVER=1 ./agent.sh sync-files            # host only, agent stopped OK
sudo CUTOVER=1 ./agent.sh sync [--force-config] # need running agent; builds MCP, plugins
sudo ./agent.sh diff | status
```

`--force-config` only replaces an upstream Hermes seed, never a customized live `config.yaml`.
SOUL is always distribution-owned. After editing skills: commit, `git pull` on the VPS,
`sudo CUTOVER=1 ./agent.sh sync`.

Health / markets sqlite lives in `/opt/data/private/` (host `data/private/`). MCP secrets
(`HEVY_API_KEY`, `YAZIO_*`, `RENPHO_*`) are names in `data/.env`. Smoke: `hermes mcp test hevy`
(and yazio, renpho) inside the agent.

## Orca remote server (optional, on the host)

[Orca](https://www.onorca.dev/docs/remote-servers) lets you run Claude Code / Codex / Grok
sessions yourself — parallel agents, worktrees, diff review — from the Orca desktop app or the
mobile app, with the runtime on the VPS. It is deliberately **not a container**: `orca.sh`
installs it on the host as `orca.service`, running as **`hermes`** (the same uid as `harden.sh`
and the agent binds) with its own `HOME` (`ORCA_HOME`, default `/srv/orca`, mode 0700 —
**not** `/home/hermes`, **not** mounted in the agent). Sessions cwd is
`/srv/workspace` (the same tree, at the same path, as the agent and herdr). Orca creates its
worktrees in `/srv/workspace/worktrees/orca` (Settings → workspace directory, set by the migration).

HOMEs stay split so a hook planted in the agent's `~/.claude/settings.json` or a
`core.hooksPath` in the agent's gitconfig cannot run as a sudoer. `orca.sh install` copies only
the agent's **credential files** into `ORCA_HOME` (same accounts, no second login). Repo-local
git hooks in the workspace are overridden for Orca by `GIT_CONFIG_COUNT` in `/etc/orca.env`
(git `-c` rank). Treat the workspace as **untrusted for sudo** (Makefiles / `deploy.sh` remain a
residual risk). There is no dedicated `orca` user and no POSIX ACLs on this checkout.

```bash
sudo ./orca.sh install         # hermes HOME, Xvfb + Electron libs, Node 22, claude/codex/grok/gh, Orca, orca.service, logins
sudo ./orca.sh pair mobile     # phone: scan the printed QR (phone on the tailnet); `pair desktop` = runtime link
sudo ./orca.sh creds           # re-copy the agent's grok / gh logins after `auth.sh grok|gh`
sudo ./orca.sh login claude    # Orca's own login (required for claude|codex, optional for grok|gh)
sudo ./orca.sh status | logs
```

**Editing this stack from Orca.** Open `/srv/command-center` as a project: sessions can change it
in place and run `sudo ./install.sh`, `sudo ./auth.sh …`, `docker compose …`. Same uid, no ACLs.
`.env` stays `0600` for the owner; a session reads it with `sudo`.

**Sharing code with the agent.** Same tree, same path: `/srv/workspace/projects/<repo>` on the
host and in the container (`/workspace/projects/<repo>` is the alias). One repo per `projects/<repo>`.

Desktop app: Settings → Remote Orca Servers → Add Server → paste the `orca://pair?…` link.
**Treat the link like a root password**: whoever holds it runs commands as `hermes`
(passwordless sudo, docker group). Orca listens on `0.0.0.0:ORCA_PORT` (6768) and advertises
`DESKTOP_BIND`; `orca.service` adds INPUT rules at every start. Orca state lives in
`ORCA_HOME/.config/orca` (backed up when the dir exists).

Layout: `/opt/orca/<tag>/` (extracted AppImage, sha512-verified), `/opt/orca/current` and
`/opt/orca/previous` symlinks, `/usr/local/bin/orca`, `/etc/orca.env` (`HOME` + `GIT_CONFIG_COUNT`)
and `orca.service` (`MemoryMax` = `ORCA_MEM_LIMIT`). `sudo ./orca.sh remove` drops the unit and
`/opt/orca` — it does **not** delete user `hermes` or `ORCA_HOME`.

The agent container itself has no Docker (only Traefik sees the daemon, read-only, through the
socket proxy): Hermes can write a compose project, you or an Orca session deploy it after
reviewing what it does.

## PostgreSQL (your data)

`hermes-postgres` (`postgres:17-alpine`, 512 MB cap, data checksums) is a plain database for
whatever you want kept in tables — weight, training sessions, anything the agent should query
or fill for you. `install.sh` generates `POSTGRES_PASSWORD`; user and database default to
`hermes` (`.env`: `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PORT`, `POSTGRES_DIR`, `POSTGRES_MEM_LIMIT`).

- **Agent**: the container has `psql`/`pg_dump` and the libpq variables (`PGHOST=hermes-postgres`,
  `PGUSER`, `PGPASSWORD`, `PGDATABASE`) plus `DATABASE_URL`.
- **You**: `postgresql://hermes:<POSTGRES_PASSWORD>@<tailscale-ip>:5432/hermes` from any tailnet device.
- **Your own projects** (Orca-deployed compose): join the network `hermes-data`.
- **Backups**: `backup.sh` takes a `pg_dumpall --clean` into `/srv/hermes/postgres/dumps/`
  (7 kept) before the restic upload; the live `data/` dir is deliberately not uploaded.
- Schemas `health` and `markets` (migrations under `projects/db/migrations/`). Sqlite copies:
  `/opt/data/private/health.sqlite3`, `markets.sqlite3`.

## Obsidian vault (optional)

The agent writes Markdown into `/srv/workspace/<OBSIDIAN_VAULT_DIR>` (default `vault`, same path
on the host). The `obsidian-sync` sidecar is the official
`node:22-bookworm-slim` image plus a bind-mounted `obsidian/entrypoint.sh` that installs
`obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}` (pin **0.0.14**, not `latest`) into the
persistent HOME volume, then `ob sync --continuous`. Credentials live in `/srv/hermes/obsidian`,
outside the agent's HOME.

`sudo ./auth.sh obsidian` pulls the node image, pre-installs `ob` into the volume, runs the
login, lists your remote vaults and asks which one to link, then starts the sidecar.
Checks: `sudo ./auth.sh status`, `docker compose logs -f obsidian-sync`.

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
and deduplicates; retention 7 daily / 4 weekly / 6 monthly, prune on Sundays. `/srv/discord-backup/var`
(the Discord bot's archives, already sealed with a key that exists only in Bitwarden) is included.

Each run first takes `hermes backup` inside the agent (consistent `state.db` snapshot), then
writes a fresh `pg_dumpall` of `hermes-postgres` to `postgres/dumps/`, then uploads `data/`,
the workspace (`HERMES_WORKSPACE_DIR`), `obsidian/`, `postgres/dumps/`, `state/traefik/acme.json`,
the command center `.env`, `/srv/orca` and `/srv/helios` (when present) — minus `node_modules`,
venvs, caches, browser profiles. herdr is not backed up (`command-center herdr install` rebuilds it).

**Keep `RESTIC_PASSWORD`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` and `RESTIC_REPOSITORY` outside the
VPS** (`setup` prints all four). Without them the repository cannot be read. Never change
`RESTIC_PASSWORD` by editing `.env` — that orphans the repository; use
`sudo ./backup.sh restic key add` / `key remove`.

Nothing alerts on a failed backup: check `sudo ./auth.sh status` or `journalctl -u hermes-backup`
now and then.

Snapshots taken before the `/srv` layout keep their old host paths (restic stores them as is):
workspace under `…/srv/hermes/projects/` (or `…/srv/hermes/workspace/` before the single-agent
cut-over), Orca under `…/srv/hermes/orca/`, Helios under `…/srv/hermes/helios/`. `backup.sh restore`
prints the matching `rsync` lines.

### Disaster recovery on a fresh VPS

1. `sudo ./harden.sh` (puts this repo in `/srv/command-center`), then as `hermes`:
   `cd /srv/command-center && cp .env.example .env` and add `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
   `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`.
2. `sudo ./install.sh` — installs Docker, asks host / email / CF token, starts an empty stack
   and, since `.env` has the restic credentials, enables the nightly backup timer: run
   `sudo systemctl disable --now hermes-backup.timer` right away so the empty stack does not
   become `latest` before you restore (re-enable it at the end).
3. `sudo ./backup.sh snapshots`, then `sudo ./backup.sh restore <id> /srv/restore` and the printed
   `sudo` lines (stack down, `rsync`/`cp` of `data/`, workspace-or-projects, `obsidian/`,
   `postgres/dumps/`, `acme.json`, `.env`).
4. `sudo ./install.sh` again (re-chowns for this host's `hermes` uid, sets `DESKTOP_BIND`,
   recreates), then load the newest dump into the fresh PostgreSQL (printed `zcat … | psql` line).
   If Orca was installed: `sudo ./orca.sh install`, then the printed `rsync` of `ORCA_HOME`
   (pairings, state). Helios: the printed `rsync` of `/srv/helios`, `git clone` of the repo into
   `/srv/workspace/projects/helios` if the workspace snapshot lacks it, `sudo command-center helios deploy`.
   herdr: `sudo command-center herdr install`. Finally `sudo rm -rf /srv/restore` (it holds every secret in clear).

All OAuth logins, memory, sessions and skills come back with `data/`. Skills/SOUL/MCP also live
in this repo: `sudo CUTOVER=1 ./agent.sh sync` rebuilds them without a backup. Hermes-only
alternative into a running agent: `sudo ./auth.sh shell` → `hermes import /opt/data/backups/<zip>`.

## Files & Python

- Put files in `/srv/workspace` on the VPS → same path for the agent (its cwd), Orca and herdr.
  Repos go in `/srv/workspace/projects/<repo>`.
- Python 3.13 ships in the image (venv `/opt/hermes/.venv`, no `pip`, `uv` is available); the
  agent runs scripts through its terminal tool. Extra libraries: add a
  `RUN uv pip install --python /opt/hermes/.venv/bin/python <pkg>` line to `hermes/Dockerfile` and
  run `sudo ./update.sh`. The same command from `sudo ./auth.sh shell` works until the next image
  rebuild. Commit such edits to your fork: only `.env` of the checkout is backed up, and `git pull`
  will not merge over uncommitted changes.

## Cut-over (existing six-profile VPS)

Historical (paths below are the pre-`/srv` ones). The later move to the `/srv` layout is
`migrate-srv-layout.sh` — see *Moving to the /srv layout* below.

`heal.sh` recreates `hermes-agent` every minute if it is unhealthy. The new compose uses
`hermes gateway run` without `-p default`; checking it out while `data/active_profile` still
points at a named profile steals `:8642`. **Touch `.maintenance` before any git checkout** of
this branch:

```bash
touch /srv/hermes/stack/.maintenance
# take the update lock (the script takes it again)
git fetch && git checkout refactor/single-agent
sudo ./migrate-single-agent.sh --dry-run
sudo ./migrate-single-agent.sh
```

The script refuses to run without `.maintenance`. Order (idempotent, fail-closed):

1. Secrets (`HEVY_*` / `YAZIO_*` / `RENPHO_*`) from the health Bitwarden project **while the
   agent is still up** — fail before `compose stop` if a key is missing.
2. Stop the agent, `mv /srv/hermes/workspace /srv/hermes/projects` (no flatten, no symlink).
3. Kanban SQL on table `tasks` (and `task_runs.profile`, `notifier_profile`).
4. Copy sqlite/json into `data/private/`, archive `data/profiles/` + `data/distributions/`,
   remove `data/active_profile`, patch `config.yaml` (multiplex off, MCP servers, empty
   orchestrator — does not clobber `max_turns` or Bitwarden `project_id`).
5. Rewrite `projects/HERMES.md`, `CUTOVER=1 agent.sh sync-files`.
6. Orca: warn → `systemctl stop orca` → wait `ps -u orca` empty (60 s) → chown → `User=hermes`
   → `userdel orca` without `-r` (skip if processes remain).
7. Tag rollback images (`node:previous`, `4km3/dnsmasq:previous`, plus the old custom names),
   `compose up -d --force-recreate`, `wait_healthy`, `CUTOVER=1 agent.sh sync`.
8. **Fail** if `hermes mcp test hevy|yazio|renpho` is not 0. `rg` leftover coding-CLI
   invocations outside `data/archive` also fails the migrate.

It does **not** remove `.maintenance`. After you have checked the dashboard (one agent),
`curl 127.0.0.1:8642/health`, MCP tests, `orca.sh status` (`User=hermes`) and
`nslookup $HERMES_HOST $DESKTOP_BIND`: `rm /srv/hermes/stack/.maintenance`.

## Moving to the /srv layout (existing `/srv/hermes/stack` install)

`migrate-srv-layout.sh` (`sudo command-center migrate`) moves a live install, idempotently:

| Before | After |
|---|---|
| `/srv/hermes/stack` | `/srv/command-center` |
| `/srv/hermes/traefik` | `/srv/command-center/state/traefik` |
| `/srv/hermes/projects` | `/srv/workspace` |
| `/srv/hermes/helios` (repo + `.env` + `tinyauth/data`) | code → `/srv/workspace/projects/helios`, `.env` + `tinyauth/data` → `/srv/helios` |
| `/srv/hermes/data/projects/<repo>` | `/srv/workspace/projects/<repo>` (absolute symlink left behind for the agent's `/opt/data/projects/…` paths) |
| `/srv/hermes/orca` | `/srv/orca` |

```bash
sudo /srv/hermes/stack/migrate-srv-layout.sh --dry-run
sudo /srv/hermes/stack/migrate-srv-layout.sh      # phase 1: stack + Helios down/up (minutes), Orca keeps running
sudo command-center herdr install
sudo command-center migrate finalize              # phase 2: restarts Orca — ends every Orca session
```

Phase 1 stops Helios and the compose stack (project `stack` → `command-center`), moves the
directories, rewrites `.env` (`HERMES_WORKSPACE_DIR`, `TRAEFIK_DIR`, `ORCA_HOME`, `HELIOS_*`,
`PROXY_SUBNET`), updates the host paths in the agent's `MEMORY.md` (backup kept), re-renders the
systemd units, rewrites `orca.service` / `/etc/orca.env` **without restarting Orca**, starts the
stack, sets `terminal.cwd`, writes the workspace rules and redeploys Helios. The running Orca
(possibly the session running the script) keeps working through compat symlinks
`/srv/hermes/{stack,orca,projects,helios}`. Phase 2 (detached with `systemd-run` when started from
an Orca session: `journalctl -u command-center-finalize -f`) stops Orca, rewrites absolute paths in
its state (`orca-data.json` repos, `.claude.json`, `.gitconfig`, Codex trust, Claude project dirs —
also for `/home/hermes`), moves Orca's worktree directory to `/srv/workspace/worktrees/orca`,
removes the compat symlinks and starts Orca. Paired devices keep their tokens.

## Operations

```bash
sudo command-center status                 # everything: /srv, containers, orca, helios, herdr, workspace
docker compose ps
docker compose logs -f hermes-agent        # gateway + dashboard (s6-supervised)
docker compose logs -f traefik             # ACME / routing
sudo ./auth.sh shell                        # shell in the agent container
sudo ./auth.sh status                       # logins, update hold, backup timer, orca (host), obsidian
sudo ./agent.sh status                      # SOUL, skills count, superpowers, MCP stamp
sudo ./update.sh                            # what the 04:00 timer runs: build + test first, recreate what changed, auto-rollback
sudo ./update.sh check                      # build + smoke-test + pull, report what would change; recreates nothing
sudo ./update.sh rollback                   # back to the images that ran before the last update, and hold
sudo ./update.sh resume                     # lift the hold, forget the versions that failed
sudo ./heal.sh                              # what hermes-heal.timer does every minute
systemctl list-timers 'hermes-*'            # backup 03:00 daily, update 04:00 daily, heal every minute
```

**Updates (every night, 04:00).** Public images track their pins / `:latest` (agent base, restic,
`node:22-bookworm-slim`, `4km3/dnsmasq:2.90-r3`); the agent image is rebuilt with `--no-cache` so the
npm CLIs advance even when its base is unchanged. `update.sh` never touches a running service
before the new version has passed its checks:

1. **preflight** — skipped (nothing touched) when `hermes-agent` is not healthy, updates are on hold,
   or Docker has less than `UPDATE_MIN_FREE_GB` (10) free;
2. **stage** — the agent image is built as `hermes-agent-vps:candidate`, never over `:latest`, and
   smoke-tested in a throwaway offline container (`hermes`, `claude`, `codex`, `grok`, `gh` must
   start); public images are pulled. A failed build, pull or test puts every tag back: the running
   version stays, nothing is restarted;
3. **compare** — same agent content (tool versions, OS and npm packages) and same digests → nothing
   is recreated, and `:previous` (the rollback point of the last real update) is kept. A version
   listed in `.update-failed` is skipped until a newer one ships;
   **busy gate** — when `hermes-agent` is about to be recreated, the update first waits for Hermes to
   be idle: no herdr pane where Hermes is `working`/`blocked`, no gateway turn, cron job, kanban run
   or async delegation in flight, no open session active in the last 2 min (`lib/hermes-probe.py`
   reads the container's databases, read-only). Still busy after `UPDATE_BUSY_WAIT` (1 h) → the
   night is skipped (nothing recreated, `state/last-update` says why) and you are notified. Once
   idle, Hermes is paused (`hermes pause`: no new gateway turn / cron / kanban dispatch) until the
   swap is over. `sudo ./update.sh busy` shows what is working right now; `--force` does not wait;
4. **swap** — only the services whose image changed are recreated (`--no-deps`); what they ran
   before becomes `:previous`;
5. **verify** — every service that was OK before must be running and healthy within
   `UPDATE_VERIFY_TIMEOUT` (420 s) and still be `UPDATE_SETTLE` (60 s) later. Otherwise automatic
   rollback to `:previous`, the new versions go to `.update-failed` (no hold: the next night tries
   again once something newer is out);
6. **host** — `orca.sh update`: host CLIs (`npm -g`, reinstalled at their previous versions when one
   no longer starts) and the Orca release (back to the previous one, updates on hold, if it does not
   come up); `herdr.sh update` (binary + `tode`, previous binary restored if the new one does not
   start, running panes untouched).

**Hermes sessions in herdr survive the swap.** Just before `hermes-agent` is recreated, the herdr
panes whose foreground is the Hermes CLI are noted; once it is healthy again (after the update or
its rollback), each gets `hermes --resume <id>` typed into its shell — the id the CLI printed when
the recreate closed it. The id is only typed when it has the exact session-id format and is a CLI
session that ended during this recreate (pane output is not trusted). Same for `heal.sh`,
`command-center hermes restart` and `auth.sh` (they go through `restart_agent`, which also asks
first, from a terminal, when Hermes is working). `hermes` on the host keeps a process named
`hermes` in the foreground (`bin/hermes` does not `exec` docker) so herdr recognises the agent and
its idle / working / blocked state.

The result of the last run is in `state/last-update` (`command-center status`); set
`UPDATE_NOTIFY_HERMES=telegram` (the Hermes agent messages its Telegram home channel through
`hermes send`) and/or `UPDATE_NOTIFY_URL` (Discord webhook or `https://ntfy.sh/<topic>`) in `.env`
to be told about skipped nights, failures and rollbacks. `sudo ./update.sh rollback` goes back to `:previous` by hand and puts the
timer on hold (`update.sh resume` lifts it). Disable auto-updates: `sudo systemctl disable --now
hermes-update.timer`. Pin `OBSIDIAN_HEADLESS_VERSION` and `ORCA_VERSION` in `.env`; the agent base by
editing `hermes/Dockerfile` `FROM`. Recreating `hermes-agent` ends its running sessions: that only
happens on a night where its image really changed, once Hermes is idle. Helios images are rebuilt by
`command-center helios deploy`, not by the nightly update (it builds the workspace checkout, which is
reviewed before deploying).

**Healing.** `hermes-heal.timer` runs `heal.sh` every minute — restarts containers Docker marks
unhealthy or stuck in Docker's `restarting` loop, starts exited ones, and recreates
`hermes-agent` when it is the one unhealthy — at most 3 times in a row
(`HEAL_MAX_AGENT_RECREATES`). It stays idle when nothing in the project runs, while `update.sh`
runs, and while `/srv/command-center/.maintenance` exists — **touch that file before
`docker compose stop <service>`**, otherwise the service is back within a minute.

**Restarting the agent:** `docker compose up -d --force-recreate hermes-agent` (recreate, so a
changed `.env` / `data/.env` is picked up). Resource limits: `AGENT_MEM_LIMIT`, `AGENT_CPUS`
(container), `ORCA_MEM_LIMIT` (orca.service) in `.env`.

**Updating these scripts:** `cd /srv/command-center && git pull` (as `hermes`, no sudo) then
`sudo ./install.sh`.

**Logs.** `sudo journalctl -u hermes-backup|hermes-update|hermes-heal|orca|fail2ban`,
`/var/log/unattended-upgrades/`, `docker compose logs <service>` (json-file, 20 MB × 5; DNS is
service `dns`). Traefik access log is off. There is no monitoring or alerting. `TZ` in `.env`
applies to containers and restic only; timer times follow the host timezone (`timedatectl`).

### Rotating secrets

| Secret | Then |
|---|---|
| `API_SERVER_KEY` | `docker compose up -d --force-recreate hermes-agent` |
| `DESKTOP_PASSWORD` / `DESKTOP_SECRET` | `docker compose up -d --force-recreate hermes-agent` (no effect while an external secret source supplies `HERMES_DASHBOARD_BASIC_AUTH_*` — rotate it there) |
| `CF_DNS_API_TOKEN` | `docker compose up -d --force-recreate traefik` |
| `RESTIC_PASSWORD` | `sudo ./backup.sh restic key add` (asks the new one), then `key remove <old id>` — only then edit `.env` |
| SSH key of `hermes` | `sudo /srv/command-center/harden.sh --rotate-key` |
| Orca pairings | revoke in the app (Shared Server Access) |
| Agent coding CLI logins | `sudo ./auth.sh claude\|codex\|grok` |
| Orca coding CLI logins | `sudo ./orca.sh login claude\|codex\|grok` (and `sudo ./orca.sh creds` for grok / gh after agent-side logins) |

Changing `HERMES_HOST` / `DNS_ZONE`: edit `.env` (host inside zone), `sudo ./install.sh`
(recreates `hermes-dns` and `hermes-agent` — the router labels live on `hermes-agent`, Traefik
picks them up live), update the restricted domain of the nameserver in the Tailscale admin console;
the old certificate stays in `acme.json`, harmless.

### Uninstall

```bash
sudo systemctl disable --now hermes-backup.timer hermes-update.timer hermes-heal.timer
sudo rm /etc/systemd/system/hermes-* /etc/systemd/system/docker.service.d/10-tailscale.conf && sudo systemctl daemon-reload
cd /srv/command-center && docker compose --profile '*' down --remove-orphans
docker volume rm hermes-restic-cache; docker image prune -a
sudo ./orca.sh remove              # if installed (keeps user hermes, Node, host CLIs, ORCA_HOME)
sudo ./herdr.sh remove             # if installed (keeps ~/.config/herdr)
(cd /srv/workspace/projects/helios && docker compose --profile '*' down)   # Helios, if deployed
sudo rm -f /usr/local/bin/command-center /workspace
sudo rm -rf /srv/hermes /srv/orca /srv/helios /srv/workspace /srv/command-center   # data + every secret
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
| `docker-compose.yml` | project `command-center`: docker-socket-proxy, traefik, hermes-agent (gateway + dashboard), postgres, dns (`4km3/dnsmasq`), obsidian-sync (`node:22-bookworm-slim`, profile `obsidian`); network subnets pinned |
| `dns/dnsmasq.conf` | bind-mounted into the public dnsmasq image (zone via compose `command`) |
| `hermes/Dockerfile` | `FROM nousresearch/hermes-agent:latest` + `claude`, `codex`, `grok`, `gh`, `tmux`, `jq`, `psql`, `less`, `nano` |
| `obsidian/entrypoint.sh` | install `obsidian-headless@0.0.14` into the volume, then `ob` |
| `command-center` | CLI / menu: status, one-click deploys, admin of hermes / orca / helios / herdr / workspace |
| `orca.sh` / `orca/orca.service` | Orca on the host as `User=hermes`, HOME `/srv/orca`, cwd `/srv/workspace`, `GIT_CONFIG_COUNT` |
| `helios.sh` | Helios deploy/admin: code `/srv/workspace/projects/helios`, deployment `/srv/helios` |
| `herdr.sh` / `herdr/herdr.service` | herdr + terminal-code plugin for `hermes`, `herdr server` as a systemd service |
| `discord-backup.sh` | Discord backup bot: tested releases in `/srv/discord-backup`, units from the repo's `deploy/`, BWS secrets |
| `agent/WORKSPACE.md` | → `/srv/workspace/AGENTS.md` (+ `CLAUDE.md` link): rules for every agent in the workspace |
| `migrate-srv-layout.sh` | live move from `/srv/hermes/*` to the `/srv` layout (phase 1 + `finalize` for Orca) |
| `agent.sh` / `agent/` / `skills/` / `mcp/` | default agent as code (sync-files / sync / diff / status) |
| `migrate-single-agent.sh` | in-place cut-over from six profiles + user `orca` |
| `harden.sh` | VPS isolation: user `hermes` + key, Tailscale, ufw + DOCKER-USER, sshd, auto-updates |
| `install.sh` / `auth.sh` / `update.sh` | bootstrap / logins + messaging / nightly update: tested before the swap, automatic `:previous` rollback |
| `backup.sh` / `heal.sh` | restic → B2 backups / self-healing |
| `systemd/` | `hermes-backup`, `hermes-update`, `hermes-heal` service + timer templates |
| `lib/common.sh` | shared helpers, `/srv` layout defaults, `ensure_workspace` |
| `state/` | runtime state kept next to the scripts, git-ignored (`traefik/acme.json`) |
| `.env.example` | all variables |

## Troubleshooting

- **Locked out?** The 10-minute guard disables ufw if you never confirmed. Otherwise use the
  provider's console: `ufw disable`, fix Tailscale (expired node key? `tailscale up` again and
  disable key expiry in the admin console), re-run `/srv/command-center/harden.sh`.
- **`ufw reload` broke the containers** — ufw flushes Docker's iptables chains:
  `systemctl restart docker`.

- **`<HERMES_HOST>` does not resolve** — the device is not using the tailnet DNS: Tailscale
  admin console → DNS → nameserver `100.x.y.z` restricted to `DNS_ZONE`, and on the device
  Tailscale's "Use Tailscale DNS settings" enabled. `nslookup <HERMES_HOST> <tailscale-ip>`
  must answer from anywhere on the tailnet.
- **No certificate / browser warning, or Traefik 404 with its default certificate** —
  `docker compose logs traefik`. `open /acme/acme.json: permission denied` ⇒ the ACME resolver was
  skipped and the router dropped: `acme.json` must be `root:root` mode 600 —
  `sudo chown 0:0 /srv/command-center/state/traefik/acme.json && sudo docker restart traefik`. Otherwise check the
  Cloudflare zone and the token scope (Zone:DNS:Edit + Zone:Zone:Read). Let's Encrypt rejects
  `example.com` emails.
- **Dashboard rejects `DESKTOP_USERNAME` / `DESKTOP_PASSWORD`** — an external secret source
  (Hermes `config.yaml` → `secrets.*`) supplies `HERMES_DASHBOARD_BASIC_AUTH_*` and overrides the
  compose values; use those credentials or drop them from the source. Attempts are logged in
  `data/logs/dashboard-auth.log`.
- **Dashboard says the gateway is offline / `hermes-agent` unhealthy** — inside the agent:
  `docker compose exec hermes-agent curl -s 127.0.0.1:8642/health` and
  `… 127.0.0.1:9120/api/status`; `docker compose logs hermes-agent`. If you changed
  `API_SERVER_KEY` in `.env`, recreate the agent. If you checked out this compose on a live
  six-profile VPS without migrate, restore `.maintenance` and run `migrate-single-agent.sh`.
- **`[config-migrate] WARNING … predates version 12`** on first boot — benign; the image seeds
  the upstream example config and `hermes setup` / `hermes model` stamp the version. Fresh
  install copies `agent/config.yaml` first so this should not be the live default.
- **Permission denied under `/srv/hermes` or `/srv/workspace`** — `HERMES_UID`/`HERMES_GID` in `.env` must match the
  directory owner; `sudo command-center workspace fix`, or re-run `sudo ./install.sh`. Right after an update this can also mean the
  upstream image changed its uid handling: `sudo ./update.sh rollback`.
- **Update broke something** — a service that no longer comes up healthy is rolled back
  automatically; for a subtler breakage: `sudo ./update.sh rollback` (previous images, timer on hold).
  `journalctl -u hermes-update -n 100` for what happened, `state/last-update` for the last result.
  `sudo ./update.sh resume` when fixed. Host CLIs: `sudo npm i -g <pkg>@<version>`; herdr:
  `sudo ./herdr.sh rollback`; Orca: `sudo ./orca.sh rollback`.
- **A service I stopped keeps coming back** — `heal.sh`: `touch /srv/command-center/.maintenance`
  first (remove it when done).
- **Browser tools crash** — `shm_size` is 1g; raise `AGENT_MEM_LIMIT` (default 10g / 6 CPUs, sized for an 8 vCPU / 16 GB VPS).
- **Backup failed** — `journalctl -u hermes-backup -n 50`; `sudo ./backup.sh restic unlock` after
  an interrupted run; `sudo ./backup.sh check` to verify the repository. A long first upload can
  be cut by the 02:00 reboot window: run the first `backup.sh run` by hand.
- **404 on `https://<HERMES_HOST>` / Traefik sees no router** — `docker compose logs docker-socket-proxy traefik`;
  Traefik reaches the Docker API only through the proxy on the internal `docker-api` network.
- **Local testing without root** — `ALLOW_NON_ROOT=1 ./install.sh` with `HERMES_*_DIR` pointing at
  directories you own.
