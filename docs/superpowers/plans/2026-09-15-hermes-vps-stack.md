# Hermes VPS Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-command deployment of Hermes Agent + Hermes Workspace behind Traefik (Cloudflare DNS-01 TLS) on a fresh Debian/Ubuntu VPS, with subscription-OAuth CLIs (`claude`, `codex`, `grok`), `gh`, Python, and host-persistent storage.

**Architecture:** A derived image (`FROM nousresearch/hermes-agent:latest` + `gh` + npm CLIs) runs the gateway + loopback dashboard; `hermes-workspace` shares its network namespace (`network_mode: service:hermes-agent`) so it can scrape the unauthenticated loopback dashboard; Traefik routes `https://$WORKSPACE_HOST` to port 3000 inside that namespace via labels on the agent service. Bind mounts under `/srv/hermes` persist everything.

**Tech Stack:** Docker Engine + compose plugin, Traefik v3, `nousresearch/hermes-agent:latest`, `ghcr.io/outsourc-e/hermes-workspace:latest`, bash.

## Global Constraints

- Base image: `nousresearch/hermes-agent:latest` (never fork the install tree; `/opt/hermes` is read-only at runtime).
- Dashboard bind must stay `127.0.0.1` (`HERMES_DASHBOARD_HOST=127.0.0.1`) — non-loopback bind fails closed without auth, and the workspace needs the unauthenticated root HTML.
- Gateway API: `API_SERVER_ENABLED=true`, `API_SERVER_HOST=0.0.0.0`, `API_SERVER_KEY` mandatory, port 8642 **never published** to the host.
- Workspace: `network_mode: "service:hermes-agent"`, `HERMES_API_URL=http://127.0.0.1:8642`, `HERMES_DASHBOARD_URL=http://127.0.0.1:9119`, `HERMES_API_TOKEN=${API_SERVER_KEY}`, `HERMES_PASSWORD` required, `COOKIE_SECURE=1`, `TRUST_PROXY=1`.
- Only `https://$WORKSPACE_HOST` is public. No Traefik dashboard.
- Host paths: `/srv/hermes/data` → `/opt/data` + `/home/workspace/.hermes`; `/srv/hermes/workspace` → `/workspace`; `/srv/hermes/traefik/acme.json` → `/acme/acme.json` (mode 600).
- Both containers remap to `HERMES_UID`/`HERMES_GID` (VPS operator user).
- Tool subprocess HOME inside agent = `/opt/data/home`; all interactive CLI logins run with `HOME=/opt/data/home`.
- CLIs: `@anthropic-ai/claude-code`, `@openai/codex`, `@xai-official/grok` via `npm i -g`; `gh` via GitHub apt repo.
- Scripts: `bash`, `set -euo pipefail`, idempotent, pass `bash -n`.
- Commits: end with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `hermes/Dockerfile` | Derived agent image: base + `gh` + tmux/jq + npm CLIs |
| `hermes/config.seed.yaml` | Initial `config.yaml` (terminal cwd `/workspace`) copied once |
| `traefik/traefik.yml` | Traefik static config (entrypoints, docker provider, Cloudflare DNS-01 resolver) |
| `docker-compose.yml` | 3 services: traefik, hermes-agent, hermes-workspace; network `proxy` |
| `.env.example` | All variables with comments; secrets empty |
| `.gitignore` | `.env`, `acme.json` |
| `lib/common.sh` | Shared helpers: colors, `die`, `need_root`, `compose` wrapper, `.env` loading |
| `install.sh` | Fresh-VPS bootstrap (docker install, dirs, `.env` gen, build, up, health wait) |
| `auth.sh` | Interactive OAuth logins inside the agent container |
| `update.sh` | Rebuild/pull/recreate |
| `README.md` | Usage, layout, troubleshooting |

---

### Task 1: Repo skeleton, `.gitignore`, `.env.example`

**Files:**
- Create: `.gitignore`
- Create: `.env.example`

**Interfaces:**
- Produces: the variable names every later file relies on: `WORKSPACE_HOST`, `ACME_EMAIL`, `CF_DNS_API_TOKEN`, `API_SERVER_KEY`, `HERMES_PASSWORD`, `HERMES_UID`, `HERMES_GID`, `HERMES_DATA_DIR`, `HERMES_WORKSPACE_DIR`, `TRAEFIK_DIR`, `AGENT_MEM_LIMIT`, `AGENT_CPUS`, `TZ`.

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.env
*.local
acme.json
```

- [ ] **Step 2: Write `.env.example`**

```dotenv
# ── Public endpoint ───────────────────────────────────────────────
# FQDN served by Traefik (DNS record must point at this VPS, proxied or DNS-only in Cloudflare)
WORKSPACE_HOST=workspace.example.com
# Let's Encrypt registration email
ACME_EMAIL=you@example.com
# Cloudflare API token with Zone:DNS:Edit on the zone (DNS-01 challenge)
CF_DNS_API_TOKEN=

# ── Secrets (install.sh generates them if empty) ─────────────────
# Bearer for the gateway API (8642); workspace passes it as HERMES_API_TOKEN
API_SERVER_KEY=
# Login password of the workspace web UI
HERMES_PASSWORD=

# ── Host storage ─────────────────────────────────────────────────
HERMES_DATA_DIR=/srv/hermes/data
HERMES_WORKSPACE_DIR=/srv/hermes/workspace
TRAEFIK_DIR=/srv/hermes/traefik

# ── Ownership: the VPS user who should own /srv/hermes/* (install.sh fills from SUDO_UID)
HERMES_UID=1000
HERMES_GID=1000

# ── Resources ────────────────────────────────────────────────────
AGENT_MEM_LIMIT=4g
AGENT_CPUS=2
TZ=Europe/Paris
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore .env.example
git commit -m "chore: env template and gitignore

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Derived image `hermes/Dockerfile`

**Files:**
- Create: `hermes/Dockerfile`
- Create: `hermes/config.seed.yaml`

**Interfaces:**
- Produces: image tag `hermes-agent-vps:latest` (set in compose `build`), binaries `gh`, `claude`, `codex`, `grok`, `tmux`, `jq` on PATH for all users.

- [ ] **Step 1: Write `hermes/Dockerfile`**

```dockerfile
# Derived Hermes Agent image: official base + GitHub CLI + subscription-OAuth coding CLIs.
# The base image starts as root under s6-overlay and drops to the `hermes` user per
# service, so we deliberately do NOT add a trailing `USER` instruction.
FROM nousresearch/hermes-agent:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive

# GitHub CLI (official apt repo) + a few operator conveniences
RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        gnupg tmux jq less nano && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Coding CLIs that authenticate with consumer subscriptions (Claude Max, ChatGPT, SuperGrok).
# Installed globally under /usr/local so they are on PATH for the runtime `hermes` user.
# Their credentials land under the tool-subprocess HOME (/opt/data/home) at runtime.
RUN npm install -g --no-audit --no-fund --fetch-retries=5 \
        @anthropic-ai/claude-code \
        @openai/codex \
        @xai-official/grok && \
    npm cache clean --force

# Disable CLI self-updaters: the install tree is immutable and updates come from image rebuilds.
ENV DISABLE_AUTOUPDATER=1 \
    CODEX_DISABLE_UPDATE_CHECK=1

RUN gh --version && claude --version && codex --version && grok --version
```

- [ ] **Step 2: Write `hermes/config.seed.yaml`**

```yaml
# Initial Hermes config for the VPS stack. Copied to $HERMES_DATA_DIR/config.yaml
# by install.sh only when no config.yaml exists. Everything else is set later with
# `hermes setup`, `hermes model`, or the dashboard/workspace UI.
terminal:
  backend: "local"
  # Host directory /srv/hermes/workspace is mounted here in both containers.
  cwd: "/workspace"
  # auto = inside containers, tool subprocesses use HERMES_HOME/home (/opt/data/home)
  home_mode: "auto"
  timeout: 180
```

- [ ] **Step 3: Build locally to verify**

Run: `docker build -t hermes-agent-vps:latest hermes/`
Expected: build succeeds; last RUN prints four version strings.

If `@xai-official/grok` fails to install (package renamed), check `npm view @xai-official/grok version` and fix the name.

- [ ] **Step 4: Verify runtime user can see the binaries**

Run: `docker run --rm --entrypoint sh hermes-agent-vps:latest -c 'su -s /bin/sh hermes -c "gh --version; claude --version; codex --version; grok --version; python3 --version"'`
Expected: five version lines, no "not found".

- [ ] **Step 5: Commit**

```bash
git add hermes/Dockerfile hermes/config.seed.yaml
git commit -m "feat: derived hermes-agent image with gh and OAuth coding CLIs

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Traefik static config

**Files:**
- Create: `traefik/traefik.yml`

**Interfaces:**
- Produces: entrypoints `web` (80, redirects to `websecure`) and `websecure` (443); certresolver name `cloudflare`; docker provider with `exposedByDefault: false` and default network `proxy`. Compose labels in Task 4 reference `websecure` and `cloudflare`.

- [ ] **Step 1: Write `traefik/traefik.yml`**

```yaml
# Traefik v3 static configuration for the Hermes VPS stack.
# TLS: Let's Encrypt via Cloudflare DNS-01 (CF_DNS_API_TOKEN env in the traefik service).
api:
  dashboard: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: cloudflare

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy

certificatesResolvers:
  cloudflare:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
```

Note: Traefik does **not** expand `${ACME_EMAIL}` inside the static file. Task 4 therefore passes the email as a CLI argument (`--certificatesresolvers.cloudflare.acme.email=${ACME_EMAIL}`) which overrides the file value. Keep the file value as documentation only — replace `"${ACME_EMAIL}"` with `"placeholder@example.com"` so the file parses cleanly.

- [ ] **Step 2: Apply the note — final file content**

```yaml
api:
  dashboard: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: cloudflare

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy

certificatesResolvers:
  cloudflare:
    acme:
      # Overridden at runtime by --certificatesresolvers.cloudflare.acme.email (see docker-compose.yml)
      email: "placeholder@example.com"
      storage: /acme/acme.json
      dnsChallenge:
        provider: cloudflare
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"
```

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('traefik/traefik.yml')); print('ok')"` (or `docker run --rm -v "$PWD/traefik/traefik.yml:/t.yml:ro" traefik:v3.5 traefik --configfile=/t.yml --help >/dev/null && echo ok`)
Expected: `ok`

- [ ] **Step 4: Commit**

```bash
git add traefik/traefik.yml
git commit -m "feat: traefik static config with cloudflare dns-01

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `docker-compose.yml`

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Consumes: `.env` variables (Task 1), image build context `hermes/` (Task 2), `traefik/traefik.yml` (Task 3).
- Produces: service names `traefik`, `hermes-agent`, `hermes-workspace`; network `proxy`; used by scripts via `docker compose exec hermes-agent …`.

- [ ] **Step 1: Write `docker-compose.yml`**

```yaml
# Hermes Agent + Hermes Workspace + Traefik — single-VPS stack.
#
#   install.sh  → first boot on a fresh VPS
#   auth.sh     → OAuth logins (Claude Max / ChatGPT-Codex / SuperGrok / gh)
#   update.sh   → rebuild + pull + recreate
#
# Topology:
#   traefik ──proxy──▶ hermes-agent netns ─ :3000 hermes-workspace (public via Traefik)
#                                          ├ :8642 gateway API (internal only)
#                                          └ :9119 dashboard (127.0.0.1 only, no auth gate)
#
# hermes-workspace runs with network_mode: service:hermes-agent so it can reach the
# loopback-only dashboard (its session token is scraped from the dashboard root HTML,
# which is only served unauthenticated on a loopback bind). Because port 3000 therefore
# lives in the hermes-agent container's network namespace, the Traefik labels are on
# hermes-agent, not on hermes-workspace.

x-hermes-uid: &hermes-uid
  HERMES_UID: ${HERMES_UID:-1000}
  HERMES_GID: ${HERMES_GID:-1000}
  TZ: ${TZ:-UTC}

services:
  traefik:
    image: traefik:v3.5
    container_name: traefik
    restart: unless-stopped
    command:
      - --configfile=/etc/traefik/traefik.yml
      - --certificatesresolvers.cloudflare.acme.email=${ACME_EMAIL}
    environment:
      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}
      TZ: ${TZ:-UTC}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ${TRAEFIK_DIR:-/srv/hermes/traefik}/acme.json:/acme/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 30s
      timeout: 5s
      retries: 3

  hermes-agent:
    build:
      context: ./hermes
      pull: true
    image: hermes-agent-vps:latest
    container_name: hermes-agent
    restart: unless-stopped
    command: ["gateway", "run"]
    shm_size: 1g
    mem_limit: ${AGENT_MEM_LIMIT:-4g}
    cpus: ${AGENT_CPUS:-2}
    environment:
      <<: *hermes-uid
      HERMES_DASHBOARD: "1"
      HERMES_DASHBOARD_HOST: 127.0.0.1
      HERMES_DASHBOARD_PORT: "9119"
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: 0.0.0.0
      API_SERVER_PORT: "8642"
      API_SERVER_KEY: ${API_SERVER_KEY}
    volumes:
      - ${HERMES_DATA_DIR:-/srv/hermes/data}:/opt/data
      - ${HERMES_WORKSPACE_DIR:-/srv/hermes/workspace}:/workspace
    networks:
      - proxy
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8642/health >/dev/null && curl -fsS http://127.0.0.1:9119/api/status >/dev/null || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
    labels:
      traefik.enable: "true"
      traefik.docker.network: proxy
      traefik.http.routers.workspace.rule: Host(`${WORKSPACE_HOST}`)
      traefik.http.routers.workspace.entrypoints: websecure
      traefik.http.routers.workspace.tls.certresolver: cloudflare
      traefik.http.routers.workspace.service: workspace
      traefik.http.services.workspace.loadbalancer.server.port: "3000"

  hermes-workspace:
    image: ghcr.io/outsourc-e/hermes-workspace:latest
    container_name: hermes-workspace
    restart: unless-stopped
    network_mode: "service:hermes-agent"
    depends_on:
      hermes-agent:
        condition: service_healthy
    environment:
      <<: *hermes-uid
      HERMES_HOME: /home/workspace/.hermes
      HERMES_WORKSPACE_DIR: /workspace
      HERMES_API_URL: http://127.0.0.1:8642
      HERMES_DASHBOARD_URL: http://127.0.0.1:9119
      HERMES_API_TOKEN: ${API_SERVER_KEY}
      HERMES_PASSWORD: ${HERMES_PASSWORD}
      COOKIE_SECURE: "1"
      TRUST_PROXY: "1"
      HOST: 0.0.0.0
      PORT: "3000"
    volumes:
      - ${HERMES_DATA_DIR:-/srv/hermes/data}:/home/workspace/.hermes
      - ${HERMES_WORKSPACE_DIR:-/srv/hermes/workspace}:/workspace

networks:
  proxy:
    name: proxy
```

- [ ] **Step 2: Validate with a throwaway `.env`**

Run:
```bash
cp .env.example .env.local-test
sed -i 's/^CF_DNS_API_TOKEN=$/CF_DNS_API_TOKEN=x/; s/^API_SERVER_KEY=$/API_SERVER_KEY=k/; s/^HERMES_PASSWORD=$/HERMES_PASSWORD=p/' .env.local-test
docker compose --env-file .env.local-test config >/dev/null && echo ok
rm .env.local-test
```
Expected: `ok` (no warnings about unset variables).

- [ ] **Step 3: Local smoke test of the agent + workspace pair (no Traefik, no TLS)**

Run:
```bash
mkdir -p /tmp/hermes-smoke/{data,workspace,traefik} && touch /tmp/hermes-smoke/traefik/acme.json && chmod 600 /tmp/hermes-smoke/traefik/acme.json
cat > .env.local-test <<EOF
WORKSPACE_HOST=localhost
ACME_EMAIL=test@example.com
CF_DNS_API_TOKEN=x
API_SERVER_KEY=smoke-key
HERMES_PASSWORD=smoke-password-1234567890
HERMES_DATA_DIR=/tmp/hermes-smoke/data
HERMES_WORKSPACE_DIR=/tmp/hermes-smoke/workspace
TRAEFIK_DIR=/tmp/hermes-smoke/traefik
HERMES_UID=$(id -u)
HERMES_GID=$(id -g)
EOF
cp hermes/config.seed.yaml /tmp/hermes-smoke/data/config.yaml
docker compose --env-file .env.local-test -p hermes-smoke up -d --build hermes-agent hermes-workspace
for i in $(seq 1 24); do s=$(docker inspect -f '{{.State.Health.Status}}' hermes-agent); echo "$s"; [ "$s" = healthy ] && break; sleep 5; done
docker compose --env-file .env.local-test -p hermes-smoke exec hermes-agent curl -fsS http://127.0.0.1:3000/ | head -c 200
```
Expected: health reaches `healthy`; workspace returns HTML (login page).

Then: `docker compose --env-file .env.local-test -p hermes-smoke exec -u "$(id -u)" -e HOME=/opt/data/home hermes-agent sh -c 'gh --version && claude --version && ls -ld /workspace /opt/data/home'`
Expected: versions print; `/workspace` and `/opt/data/home` owned by your uid.

Cleanup: `docker compose --env-file .env.local-test -p hermes-smoke down; rm .env.local-test; sudo rm -rf /tmp/hermes-smoke`

If the gateway refuses to start because no model provider is configured, health still passes (`/health` + `/api/status` are served regardless) — confirm in logs with `docker logs hermes-agent`.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: compose stack traefik + hermes-agent + hermes-workspace

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Shared shell helpers `lib/common.sh`

**Files:**
- Create: `lib/common.sh`

**Interfaces:**
- Produces (sourced by `install.sh`, `auth.sh`, `update.sh`):
  - `STACK_DIR` — absolute path of the repo dir
  - `info "msg"`, `warn "msg"`, `die "msg"` (exit 1)
  - `need_root` — exits unless `EUID == 0`
  - `load_env` — sources `$STACK_DIR/.env` (dies if missing), exports vars
  - `compose …` — `docker compose --project-directory "$STACK_DIR" "$@"`
  - `agent_exec …` — `compose exec -it -u "$HERMES_UID:$HERMES_GID" -e HOME=/opt/data/home -w /workspace hermes-agent "$@"`

- [ ] **Step 1: Write `lib/common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for install.sh / auth.sh / update.sh. Source, do not execute.

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then
  _c_info=$'\033[1;34m'; _c_warn=$'\033[1;33m'; _c_err=$'\033[1;31m'; _c_off=$'\033[0m'
else
  _c_info=''; _c_warn=''; _c_err=''; _c_off=''
fi

info() { printf '%s[+]%s %s\n' "$_c_info" "$_c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$_c_err" "$_c_off" "$*" >&2; exit 1; }

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root (sudo $0)."
}

load_env() {
  [ -f "$STACK_DIR/.env" ] || die "Missing $STACK_DIR/.env — run ./install.sh first."
  set -a
  # shellcheck disable=SC1091
  . "$STACK_DIR/.env"
  set +a
  : "${HERMES_UID:=1000}" "${HERMES_GID:=1000}"
}

compose() {
  docker compose --project-directory "$STACK_DIR" "$@"
}

# Interactive shell/command inside the agent container, as the runtime user,
# with HOME set to the tool-subprocess home so CLI credentials land where the
# agent's own tool calls will find them (/opt/data/home/.claude, .codex, .grok, .config/gh).
agent_exec() {
  compose exec -it -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home -w /workspace hermes-agent "$@"
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n lib/common.sh && echo ok`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "feat: shared shell helpers

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `install.sh`

**Files:**
- Create: `install.sh` (mode 755)

**Interfaces:**
- Consumes: `lib/common.sh` helpers, `.env.example`, `hermes/config.seed.yaml`, compose services.
- Produces: `.env` populated; `/srv/hermes/{data,workspace,traefik}`; running stack.

- [ ] **Step 1: Write `install.sh`**

```bash
#!/usr/bin/env bash
# Bootstrap the Hermes stack on a fresh Debian/Ubuntu VPS. Idempotent: safe to re-run.
#
#   sudo ./install.sh
#
# Non-interactive: pre-fill WORKSPACE_HOST, ACME_EMAIL, CF_DNS_API_TOKEN in .env
# (or export them) and the script will not prompt.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"

need_root
cd "$STACK_DIR"

# ── 1. Docker ────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker Engine (get.docker.com)…"
  command -v curl >/dev/null 2>&1 || { apt-get update && apt-get install -y --no-install-recommends curl ca-certificates; }
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  info "Docker already installed: $(docker --version)"
fi
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing (apt install docker-compose-plugin)."

# ── 2. .env ──────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  info "Creating .env from .env.example"
  cp .env.example .env
  chmod 600 .env
fi

# set_env KEY VALUE — write/replace KEY in .env
set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}
# env_val KEY — current value in .env (empty if unset)
env_val() { grep -E "^$1=" .env | head -n1 | cut -d= -f2- || true; }

# ask KEY "prompt" [secret]
ask() {
  local key="$1" prompt="$2" secret="${3:-}" cur val
  cur="$(env_val "$key")"
  [ -n "${!key:-}" ] && cur="${!key}"
  if [ -n "$cur" ] && [ "$cur" != "workspace.example.com" ] && [ "$cur" != "you@example.com" ]; then
    set_env "$key" "$cur"; return
  fi
  [ -t 0 ] || die "$key is not set and stdin is not a terminal. Set it in .env and re-run."
  if [ -n "$secret" ]; then read -r -s -p "$prompt: " val; echo; else read -r -p "$prompt: " val; fi
  [ -n "$val" ] || die "$key is required."
  set_env "$key" "$val"
}

ask WORKSPACE_HOST "Public hostname for the workspace (e.g. workspace.example.com)"
ask ACME_EMAIL     "Email for Let's Encrypt"
ask CF_DNS_API_TOKEN "Cloudflare API token (Zone:DNS:Edit)" secret

[ -n "$(env_val API_SERVER_KEY)" ]  || set_env API_SERVER_KEY  "$(openssl rand -hex 32)"
[ -n "$(env_val HERMES_PASSWORD)" ] || set_env HERMES_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"

# Owner of /srv/hermes/*: the user who invoked sudo, else 1000.
owner_uid="${SUDO_UID:-1000}"; owner_gid="${SUDO_GID:-1000}"
[ "$owner_uid" -eq 0 ] && { owner_uid=1000; owner_gid=1000; }
[ -n "$(env_val HERMES_UID)" ] && [ "$(env_val HERMES_UID)" != "1000" ] || set_env HERMES_UID "$owner_uid"
[ -n "$(env_val HERMES_GID)" ] && [ "$(env_val HERMES_GID)" != "1000" ] || set_env HERMES_GID "$owner_gid"

load_env

# ── 3. Host storage ──────────────────────────────────────────────────────
info "Preparing ${HERMES_DATA_DIR}, ${HERMES_WORKSPACE_DIR}, ${TRAEFIK_DIR}"
mkdir -p "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR" "$TRAEFIK_DIR"
touch "$TRAEFIK_DIR/acme.json"; chmod 600 "$TRAEFIK_DIR/acme.json"
if [ ! -f "$HERMES_DATA_DIR/config.yaml" ]; then
  info "Seeding config.yaml"
  cp hermes/config.seed.yaml "$HERMES_DATA_DIR/config.yaml"
fi
chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR"

# ── 4. Build + start ─────────────────────────────────────────────────────
info "Building derived image (this pulls nousresearch/hermes-agent:latest)…"
compose build --pull
info "Pulling remaining images…"
compose pull --ignore-buildable
info "Starting stack…"
compose up -d --remove-orphans

# ── 5. Wait for health ───────────────────────────────────────────────────
info "Waiting for hermes-agent to become healthy…"
for _ in $(seq 1 36); do
  status="$(docker inspect -f '{{.State.Health.Status}}' hermes-agent 2>/dev/null || echo starting)"
  [ "$status" = healthy ] && break
  sleep 5
done
[ "$status" = healthy ] || { compose logs --tail=50 hermes-agent; die "hermes-agent not healthy after 3 min."; }

compose ps
cat <<EOF

$(info "Stack is up.")

  Workspace URL : https://${WORKSPACE_HOST}
  Login password: ${HERMES_PASSWORD}   (HERMES_PASSWORD in .env)
  Data dir      : ${HERMES_DATA_DIR}   (config, sessions, credentials)
  Files dir     : ${HERMES_WORKSPACE_DIR}   (drop files here → /workspace for the agent)

Next: configure model providers and CLI logins with your subscriptions:

  sudo ./auth.sh

Certificates are issued on first HTTPS request; give Traefik ~1 min after DNS points here.
EOF
```

- [ ] **Step 2: Syntax check + shellcheck if available**

Run: `chmod +x install.sh && bash -n install.sh && (command -v shellcheck >/dev/null && shellcheck -x install.sh lib/common.sh || true) && echo ok`
Expected: `ok`, no shellcheck errors (warnings about `${!key}` are acceptable).

- [ ] **Step 3: Dry-run the `.env` logic without root/docker**

Run:
```bash
tmp=$(mktemp -d); cp -r .env.example lib hermes "$tmp"/; cd "$tmp"
cp .env.example .env
WORKSPACE_HOST=w.example.org ACME_EMAIL=a@b.c CF_DNS_API_TOKEN=tok bash -c '
  set -euo pipefail; . lib/common.sh
  set_env(){ local k="$1" v="$2"; grep -q "^${k}=" .env && sed -i "s|^${k}=.*|${k}=${v}|" .env || printf "%s=%s\n" "$k" "$v" >> .env; }
  env_val(){ grep -E "^$1=" .env | head -n1 | cut -d= -f2- || true; }
  ask(){ local key="$1" cur; cur="$(env_val "$key")"; [ -n "${!key:-}" ] && cur="${!key}"; set_env "$key" "$cur"; }
  ask WORKSPACE_HOST; ask ACME_EMAIL; ask CF_DNS_API_TOKEN
  [ -n "$(env_val API_SERVER_KEY)" ] || set_env API_SERVER_KEY "$(openssl rand -hex 32)"
  grep -E "^(WORKSPACE_HOST|ACME_EMAIL|CF_DNS_API_TOKEN|API_SERVER_KEY)=" .env'
cd - >/dev/null; rm -rf "$tmp"
```
Expected: four lines with the exported values and a 64-hex `API_SERVER_KEY`.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: idempotent VPS bootstrap script

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `auth.sh`

**Files:**
- Create: `auth.sh` (mode 755)

**Interfaces:**
- Consumes: `agent_exec` from `lib/common.sh`; running `hermes-agent` service.
- Produces: credentials under `$HERMES_DATA_DIR/home/{.claude,.codex,.grok,.config/gh}` and `$HERMES_DATA_DIR/auth.json`; optional `CLAUDE_CODE_OAUTH_TOKEN` in `$HERMES_DATA_DIR/.env`.

- [ ] **Step 1: Write `auth.sh`**

```bash
#!/usr/bin/env bash
# Interactive OAuth logins for the Hermes stack. Runs commands inside the running
# hermes-agent container as the runtime user with HOME=/opt/data/home, so tokens
# persist on the host under $HERMES_DATA_DIR/home and are visible to agent tool calls.
#
#   sudo ./auth.sh            # menu
#   sudo ./auth.sh hermes     # or: claude | codex | grok | gh | status | shell
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

running="$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)"
[ "$running" = true ] || die "hermes-agent is not running. Run ./install.sh or: docker compose up -d"

do_hermes() {
  info "Hermes model provider — pick 'Anthropic' (Claude Max OAuth), 'ChatGPT or Codex Subscription', or 'xAI Grok OAuth'."
  info "Device-code / paste-code flows: open the printed URL on your laptop, paste the code back here."
  agent_exec hermes model
}

do_claude() {
  info "Claude Code: 'claude setup-token' prints a long-lived OAuth token (Claude Max required)."
  info "Open the URL on your laptop, approve, paste the code back."
  agent_exec claude setup-token
  echo
  read -r -p "Paste the token here to also store it as CLAUDE_CODE_OAUTH_TOKEN for Hermes (Enter to skip): " tok
  if [ -n "$tok" ]; then
    envf="$HERMES_DATA_DIR/.env"
    touch "$envf"; chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
    if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$envf"; then
      sed -i "s|^CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${tok}|" "$envf"
    else
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$envf"
    fi
    info "Stored in $envf. Restart the gateway to pick it up: docker compose restart hermes-agent"
  fi
}

do_codex() {
  info "Codex CLI device-code login (ChatGPT Plus/Pro/Team). Hermes also imports ~/.codex/auth.json automatically."
  agent_exec codex login --device-auth
}

do_grok() {
  info "Grok CLI login (SuperGrok / X Premium+). Open the printed URL on your laptop."
  agent_exec grok login
}

do_gh() {
  info "GitHub CLI login (device flow)."
  agent_exec gh auth login --web --git-protocol https
}

do_status() {
  agent_exec sh -c '
    echo "── hermes providers ──"; hermes auth status || true
    echo; echo "── claude ──"; claude auth status --text 2>/dev/null || echo "not logged in"
    echo; echo "── codex ──"; codex login status 2>/dev/null || echo "not logged in"
    echo; echo "── grok ──"; [ -f "$HOME/.grok/auth.json" ] && echo "auth.json present" || echo "not logged in"
    echo; echo "── gh ──"; gh auth status 2>&1 || true'
}

do_shell() { agent_exec bash; }

menu() {
  cat <<EOF
Hermes stack — auth

  1) hermes   Hermes model provider (Claude Max / ChatGPT-Codex / SuperGrok OAuth)
  2) claude   Claude Code CLI  (claude setup-token)
  3) codex    Codex CLI        (codex login --device-auth)
  4) grok     Grok CLI         (grok login)
  5) gh       GitHub CLI       (gh auth login)
  6) status   Show login state
  7) shell    Shell inside the agent container
  q) quit
EOF
  read -r -p "> " choice
  case "$choice" in
    1|hermes) do_hermes ;; 2|claude) do_claude ;; 3|codex) do_codex ;;
    4|grok) do_grok ;; 5|gh) do_gh ;; 6|status) do_status ;; 7|shell) do_shell ;;
    q|Q) exit 0 ;; *) warn "unknown choice" ;;
  esac
}

case "${1:-}" in
  hermes) do_hermes ;; claude) do_claude ;; codex) do_codex ;; grok) do_grok ;;
  gh) do_gh ;; status) do_status ;; shell) do_shell ;;
  "") while true; do menu; echo; done ;;
  *) die "usage: $0 [hermes|claude|codex|grok|gh|status|shell]" ;;
esac
```

- [ ] **Step 2: Syntax check**

Run: `chmod +x auth.sh && bash -n auth.sh && echo ok`
Expected: `ok`

- [ ] **Step 3: Verify the CLI flags exist in the installed versions**

Run (uses the image from Task 2):
```bash
docker run --rm --entrypoint sh hermes-agent-vps:latest -c 'codex login --help; echo ---; claude --help | grep -i setup-token; echo ---; grok --help | grep -i login; echo ---; gh auth login --help | grep -e --web'
```
Expected: `--device-auth` listed for codex; `setup-token` for claude; `login` for grok; `--web` for gh. Fix `auth.sh` if a flag differs.

- [ ] **Step 4: Commit**

```bash
git add auth.sh
git commit -m "feat: interactive OAuth login helper

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: `update.sh`

**Files:**
- Create: `update.sh` (mode 755)

- [ ] **Step 1: Write `update.sh`**

```bash
#!/usr/bin/env bash
# Update the stack: rebuild the derived image on the newest base, pull other images, recreate.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"
info "Rebuilding hermes-agent-vps on latest nousresearch/hermes-agent…"
compose build --pull
info "Pulling traefik + hermes-workspace…"
compose pull --ignore-buildable
info "Recreating containers…"
compose up -d --remove-orphans
docker image prune -f >/dev/null
compose ps
```

- [ ] **Step 2: Syntax check**

Run: `chmod +x update.sh && bash -n update.sh && echo ok`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add update.sh
git commit -m "feat: update script

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# Hermes Agent — VPS stack

Hermes Agent + Hermes Workspace behind Traefik (HTTPS via Cloudflare DNS-01), with
`claude` / `codex` / `grok` CLIs authenticated through your subscriptions, `gh`, Python,
and host-persistent storage.

```
Internet ──443──▶ traefik ──▶ hermes-agent  ┬ :3000 hermes-workspace (public)
                                             ├ :8642 gateway API (internal)
                                             └ :9119 dashboard (loopback only)
/srv/hermes/data       → /opt/data (agent) + /home/workspace/.hermes (workspace)
/srv/hermes/workspace  → /workspace (both) — drop files here for the agent
```

## Prerequisites

- Fresh Debian 12+/Ubuntu 22.04+ VPS, root/sudo, ports 80 and 443 open.
- A DNS record `WORKSPACE_HOST` → VPS IP (Cloudflare zone).
- Cloudflare API token with **Zone → DNS → Edit** on that zone.
- Subscriptions you want to use: Claude Max (with extra usage credits), ChatGPT (Codex), SuperGrok / X Premium+.

## Install

```bash
git clone <this repo> hermes-setup && cd hermes-setup
sudo ./install.sh          # installs Docker if needed, prompts for host/email/CF token, builds, starts
sudo ./auth.sh             # OAuth logins (menu)
```

Open `https://<WORKSPACE_HOST>` and log in with `HERMES_PASSWORD` (printed by install, stored in `.env`).

## Auth: subscriptions instead of API keys

All flows are headless-friendly (device code / paste code). Run `sudo ./auth.sh <target>`:

| Target | What | Where it lands |
|---|---|---|
| `hermes` | `hermes model` → choose Anthropic OAuth, ChatGPT/Codex, or xAI Grok OAuth as the agent's model provider | `/srv/hermes/data/auth.json` |
| `claude` | `claude setup-token` (Claude Max) — optionally stored as `CLAUDE_CODE_OAUTH_TOKEN` for Hermes | `/srv/hermes/data/home/.claude`, `/srv/hermes/data/.env` |
| `codex` | `codex login --device-auth` (ChatGPT) — Hermes imports `~/.codex/auth.json` too | `/srv/hermes/data/home/.codex` |
| `grok` | `grok login` (SuperGrok / Premium+) | `/srv/hermes/data/home/.grok` |
| `gh` | `gh auth login --web` | `/srv/hermes/data/home/.config/gh` |
| `status` | show everything | |

Notes from upstream docs: Anthropic OAuth needs a **Max** plan with extra usage credits (Pro is not
supported); xAI OAuth may return 403 on some tiers (fallback: `XAI_API_KEY`).

## Files & Python

- Put files in `/srv/hermes/workspace` on the VPS → visible as `/workspace` (agent cwd and the
  workspace file browser).
- Python 3.13 is in the image. Extra libs: `sudo ./auth.sh shell` then `pip install --user <pkg>`
  (persists in `/opt/data/.local`), or add them to `hermes/Dockerfile` and `sudo ./update.sh`.

## Operations

```bash
docker compose ps
docker compose logs -f hermes-agent          # gateway + dashboard
docker compose logs -f hermes-workspace
docker compose logs -f traefik               # ACME / routing
sudo ./auth.sh shell                          # shell in the agent container
sudo ./update.sh                              # rebuild on latest base image, pull, recreate
```

Messaging platforms (Telegram, Discord, …): `sudo ./auth.sh shell` → `hermes setup`, then
`docker compose restart hermes-agent`.

## Troubleshooting

- **No certificate / 404 on HTTPS** — check `docker compose logs traefik`; verify the DNS record and
  the Cloudflare token scope. `acme.json` must be mode 600.
- **Workspace shows "Offline"** — `docker compose exec hermes-agent curl -s 127.0.0.1:8642/health`
  and `curl -s 127.0.0.1:9119/api/status`; make sure `API_SERVER_KEY` in `.env` was not changed
  without recreating both containers.
- **Permission denied on /srv/hermes** — `HERMES_UID`/`HERMES_GID` in `.env` must match the owner of
  the directories; re-run `sudo ./install.sh`.
- **Browser tools crash** — `shm_size` is already 1g; raise `AGENT_MEM_LIMIT` in `.env`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README for the VPS stack

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: End-to-end local verification

**Files:** none (verification only)

- [ ] **Step 1: Fresh-clone consistency check**

Run:
```bash
tmp=$(mktemp -d) && git clone -q . "$tmp/repo" && cd "$tmp/repo" && ls -la && bash -n install.sh auth.sh update.sh lib/common.sh && echo syntax-ok
cd - >/dev/null; rm -rf "$tmp"
```
Expected: all files present; `syntax-ok`.

- [ ] **Step 2: Full compose config with generated secrets**

Run:
```bash
cp .env.example .env.local-test
sed -i "s/^CF_DNS_API_TOKEN=$/CF_DNS_API_TOKEN=x/; s/^API_SERVER_KEY=$/API_SERVER_KEY=$(openssl rand -hex 8)/; s/^HERMES_PASSWORD=$/HERMES_PASSWORD=p/" .env.local-test
docker compose --env-file .env.local-test config | grep -E "network_mode|traefik.http.routers.workspace.rule|HERMES_DASHBOARD_HOST|API_SERVER_HOST" 
rm .env.local-test
```
Expected output includes `network_mode: service:hermes-agent`, `Host(\`workspace.example.com\`)`, `HERMES_DASHBOARD_HOST: 127.0.0.1`, `API_SERVER_HOST: 0.0.0.0`.

- [ ] **Step 3: Confirm nothing sensitive is tracked**

Run: `git ls-files | grep -E '^\.env$|acme.json' || echo clean`
Expected: `clean`
