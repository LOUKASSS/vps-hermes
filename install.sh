#!/usr/bin/env bash
# Bootstrap the platform + Hermes agent on a fresh Debian/Ubuntu VPS. Idempotent: safe to re-run.
# One-click entry point for everything else (orca, helios, herdr): /srv/command-center/command-center
#
#   sudo ./install.sh
#
# Non-interactive: pre-fill HERMES_HOST, ACME_EMAIL, CF_DNS_API_TOKEN in .env (or pass them
# through sudo: `sudo HERMES_HOST=… ./install.sh`) and the script will not prompt.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"

# ALLOW_NON_ROOT=1 is for local testing only (dirs must already be writable by you).
[ "${ALLOW_NON_ROOT:-0}" = 1 ] || need_root
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
for _pkg in openssl rsync; do   # rsync: agent.sh sync-files copies skills/ + mcp/ into the data dir
  command -v "$_pkg" >/dev/null 2>&1 || { apt-get update && apt-get install -y --no-install-recommends "$_pkg"; }
done

# ── 2. .env ──────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  info "Creating .env from .env.example"
  cp .env.example .env
fi
chmod 600 .env
# Retired variables (hermes-workspace UI, removed 2026-09): its hostname becomes the stack's
# (unless it is still the old example placeholder — then HERMES_HOST is asked for below).
_old_host="$(env_val WORKSPACE_HOST)"
[ -n "$(env_val HERMES_HOST)" ] || [ -z "$_old_host" ] || [ "$_old_host" = workspace.example.com ] || set_env HERMES_HOST "$_old_host"
unset_env WORKSPACE_HOST WORKSPACE_PROFILE WORKSPACE_API_TOKEN WORKSPACE_MEM_LIMIT HERMES_PASSWORD

ask HERMES_HOST      "Hostname of the Hermes dashboard (e.g. hermes.example.com)" "" \
  '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
ask ACME_EMAIL       "Email for Let's Encrypt" "" '^[A-Za-z0-9._%+-]+@([a-z0-9-]+\.)+[a-z]{2,}$'
ask CF_DNS_API_TOKEN "Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)" secret '^[A-Za-z0-9_-]{20,}$'
# DNS zone served to the tailnet: HERMES_HOST itself unless you chose a wider one.
_zone="$(env_val DNS_ZONE)"; _host="$(env_val HERMES_HOST)"
[ -n "$_zone" ] || { _zone="$_host"; set_env DNS_ZONE "$_zone"; }
case "$_host" in "$_zone"|*".$_zone") ;; *) die "HERMES_HOST=$_host is not under DNS_ZONE=$_zone (fix DNS_ZONE in .env)." ;; esac
# The zone is answered as a wildcard: an apex (example.com) would hijack mail./www. for the tailnet.
case "$_zone" in *.*.*) ;; *) warn "DNS_ZONE=$_zone looks like a registrable apex: every *.$_zone (www, mail…) will resolve to this VPS for tailnet devices. Prefer a subdomain, e.g. hermes.$_zone." ;; esac

# The gateway api_server refuses keys shorter than 16 chars.
_key="$(env_val API_SERVER_KEY)"
[ "${#_key}" -ge 16 ] || set_env API_SERVER_KEY "$(openssl rand -hex 32)"
[ -n "$(env_val DESKTOP_PASSWORD)" ] || set_env DESKTOP_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"
[ -n "$(env_val DESKTOP_SECRET)" ]   || set_env DESKTOP_SECRET "$(openssl rand -base64 32 | tr -d '/+=')"
[ -n "$(env_val DESKTOP_USERNAME)" ] || set_env DESKTOP_USERNAME admin
[ -n "$(env_val POSTGRES_USER)" ]    || set_env POSTGRES_USER hermes
[ -n "$(env_val POSTGRES_DB)" ]      || set_env POSTGRES_DB hermes
[ -n "$(env_val POSTGRES_PASSWORD)" ] || set_env POSTGRES_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"
# Publish the Desktop backend / Orca on the Tailscale IP when the VPS is on a tailnet. A value
# you set yourself (anything but empty/loopback/a stale Tailscale IP) is kept.
TS_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null || true)"
cur_bind="$(env_val DESKTOP_BIND)"
if [ -n "$TS_IP" ]; then
  case "$cur_bind" in
    ""|127.0.0.1|100.*) set_env DESKTOP_BIND "$TS_IP" ;;
    "$TS_IP") ;;
    *) warn "DESKTOP_BIND=$cur_bind kept (Tailscale IP is $TS_IP)" ;;
  esac
else
  [ -n "$cur_bind" ] || set_env DESKTOP_BIND 127.0.0.1
  warn "No Tailscale IP found: Traefik (80/443), dashboard (9120) and DNS (53) stay on $(env_val DESKTOP_BIND), Orca (6768) would advertise it. Run harden.sh (Tailscale) and re-run, or set DESKTOP_BIND in .env to a private IP yourself."
fi
# /srv layout (lib/common.sh). A live pre-/srv install is moved by migrate-srv-layout.sh, which
# rewrites these; install.sh only fills them when empty.
[ -n "$(env_val HERMES_WORKSPACE_DIR)" ] || set_env HERMES_WORKSPACE_DIR "$SRV_ROOT/workspace"
[ -n "$(env_val HERMES_DATA_DIR)" ] || set_env HERMES_DATA_DIR "$SRV_ROOT/hermes/data"
[ -n "$(env_val TRAEFIK_DIR)" ] || set_env TRAEFIK_DIR "$STACK_DIR/state/traefik"
case "$(env_val OBSIDIAN_HEADLESS_VERSION)" in ""|latest) set_env OBSIDIAN_HEADLESS_VERSION 0.0.14 ;; esac
# Port 53 is published on DESKTOP_BIND; a resolver bound to 0.0.0.0 or to that same IP would clash.
# Our own hermes-dns (docker-proxy) is not a clash — on a re-run it is already listening there.
_bind="$(env_val DESKTOP_BIND)"
_clash="$(ss -lunpH 'sport = :53' 2>/dev/null | grep -v '"docker-proxy"' | awk '{print $4, $NF}' | grep -E "^(0\.0\.0\.0|\*|\[::\]|${_bind//./\\.}):" | head -n1 || true)"
if [ -n "$_clash" ]; then
  warn "something already listens on ${_bind}:53 ($_clash) — the dns service will fail to start until it is moved/stopped."
fi

# Owner of /srv/{hermes,workspace,orca,helios}: the `hermes` operator user created by harden.sh (always re-derived:
# its uid can differ on a rebuilt VPS), else the user who invoked sudo, else 1000.
if id hermes >/dev/null 2>&1; then
  set_env HERMES_UID "$(id -u hermes)"; set_env HERMES_GID "$(id -g hermes)"
else
  owner_uid="${SUDO_UID:-1000}"; owner_gid="${SUDO_GID:-1000}"
  [ "$owner_uid" -eq 0 ] && { owner_uid=1000; owner_gid=1000; }
  [ "$(env_val HERMES_UID)" != "1000" ] && [ -n "$(env_val HERMES_UID)" ] || set_env HERMES_UID "$owner_uid"
  [ "$(env_val HERMES_GID)" != "1000" ] && [ -n "$(env_val HERMES_GID)" ] || set_env HERMES_GID "$owner_gid"
fi

load_env

# This compose's gateway is `hermes gateway run` without -p default. Recreating
# on a six-profile tree (sticky active_profile) steals :8642. Fresh VPS: neither path exists.
if [ -e "$HERMES_DATA_DIR/active_profile" ] || [ -d "$HERMES_DATA_DIR/profiles/chief" ]; then
  die "refusing install: six-profile data still present ($HERMES_DATA_DIR/active_profile or profiles/chief). Touch $STACK_DIR/.maintenance then sudo $STACK_DIR/migrate-single-agent.sh"
fi

# ── 3. Host storage ──────────────────────────────────────────────────────
info "Preparing ${HERMES_DATA_DIR}, ${HERMES_WORKSPACE_DIR}, ${TRAEFIK_DIR}, ${OBSIDIAN_DIR}, ${POSTGRES_DIR}"
mkdir -p "$HERMES_DATA_DIR/home" "$HERMES_DATA_DIR/private" "$HERMES_DATA_DIR/mcp" \
  "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$TRAEFIK_DIR" "$OBSIDIAN_DIR"
# data/ is chowned to the postgres user by the image's entrypoint; dumps/ is written by backup.sh (root).
mkdir -p "$POSTGRES_DIR/data" "$POSTGRES_DIR/dumps"; chmod 700 "$POSTGRES_DIR" "$POSTGRES_DIR/dumps"
no_symlink "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR"
ensure_workspace
# acme.json stays root-owned: Traefik runs as root with cap_drop ALL (no DAC_OVERRIDE), so it can
# only open a mode-600 file it owns. Re-run of install.sh fixes older hermes-owned installs.
touch "$TRAEFIK_DIR/acme.json"
chown 0:0 "$TRAEFIK_DIR" "$TRAEFIK_DIR/acme.json"; chmod 600 "$TRAEFIK_DIR/acme.json"
[ "$(dirname "$TRAEFIK_DIR")" != "$STACK_DIR/state" ] || chmod 755 "$STACK_DIR/state"
chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR" "$OBSIDIAN_DIR"
# Credentials live here (OAuth tokens under data/home, Obsidian login under obsidian/): owner only.
chmod 700 "$HERMES_DATA_DIR" "$HERMES_DATA_DIR/home" "$OBSIDIAN_DIR" "$TRAEFIK_DIR"
# .env (Cloudflare token, B2 keys, restic password…) is root's: Hermes runs as the operator user,
# and every reader of .env runs as root (sudo command-center …). The rest of the repo stays the
# operator's (harden.sh; `git pull` without sudo): chown -R on .git would make root's git refuse
# the repo ("dubious ownership").
chown 0:0 .env; chmod 600 .env

# Seed config.yaml BEFORE the first compose up — otherwise the image writes the
# upstream Hermes seed (_config_version, no MCP, multiplex on).
# The agent's config lives in the hermes-config repo (HERMES_CONFIG_DIR, cloned when missing).
hermes_config_ensure
if [ ! -f "$HERMES_DATA_DIR/config.yaml" ]; then
  hermes_config_snapshot
  [ -f "$HCFG/agent/config.yaml" ] || die "missing agent/config.yaml in $HERMES_CONFIG_DIR"
  info "Seeding $HERMES_DATA_DIR/config.yaml from hermes-config agent/config.yaml"
  no_symlink "$HERMES_DATA_DIR/config.yaml"
  install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$HCFG/agent/config.yaml" "$HERMES_DATA_DIR/config.yaml"
fi

# ── 4. Hermes on the host + platform containers ─────────────────────────
# Keep heal.sh (timer, every minute) out of the way while services are (re)started.
if [ "${ALLOW_NON_ROOT:-}" != 1 ]; then
  lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
fi
# A re-run keeps the active release (update.sh moves it forward); a fresh VPS builds HERMES_REF.
if ! hermes_installed; then
  info "Building the Hermes release (HERMES_REF=${HERMES_REF:-main})…"
  _rel="$("$STACK_DIR/hermes-host.sh" build | tail -n1)"
  [ -n "$_rel" ] || die "Hermes build failed"
  "$STACK_DIR/hermes-host.sh" activate "$_rel" || true   # writes the units; the first start is verified below
fi
info "Writing /etc/hermes/agent.env, the systemd units, the Traefik route…"
"$STACK_DIR/hermes-host.sh" units
info "Pulling platform images…"
compose pull --ignore-buildable
info "Starting platform containers…"
compose up -d --remove-orphans
systemctl start hermes-gateway.service hermes-dashboard.service

# ── 5. Wait for health + first-boot config ───────────────────────────────
info "Waiting for Hermes to be healthy (up to 3 min)…"
agent_wait_healthy 180 || { journalctl -u hermes-gateway -u hermes-dashboard -n 50 --no-pager -o cat; die "Hermes not healthy after 3 min."; }

# Point the agent's terminal at the shared workspace, and keep its tool subprocesses on its own
# HOME (/opt/data/home: its CLI logins), not the operator's — `auto` would pick the real HOME on a host.
if [ "$(agent_run hermes config get terminal.cwd 2>/dev/null | tr -d '[:space:]')" != "$HERMES_WORKSPACE_DIR" ]; then
  info "Setting terminal.cwd = $HERMES_WORKSPACE_DIR"
  agent_run hermes config set terminal.cwd "$HERMES_WORKSPACE_DIR" >/dev/null
fi
if [ "$(agent_run hermes config get terminal.home_mode 2>/dev/null | tr -d '[:space:]')" != profile ]; then
  info "Setting terminal.home_mode = profile"
  agent_run hermes config set terminal.home_mode profile >/dev/null
fi

# ── 5b. Default agent (skills, SOUL, health MCP) ─────────────────────────
# Re-run after a change merged in hermes-config (agent/, skills/, mcp/): sudo command-center hermes sync
if [ "${ALLOW_NON_ROOT:-0}" != 1 ]; then
  info "Syncing the default agent from hermes-config ($HERMES_CONFIG_DIR)…"
  CUTOVER=1 UPDATE_LOCKED=1 "$STACK_DIR/agent.sh" sync \
    || die "agent.sh sync failed — fix and re-run: sudo CUTOVER=1 UPDATE_LOCKED=1 $STACK_DIR/agent.sh sync"
fi

# Hermes layers its external secret sources (config.yaml secrets.*, e.g. Bitwarden Secrets Manager)
# over its env at startup, so HERMES_DASHBOARD_BASIC_AUTH_* coming from there silently replace
# DESKTOP_USERNAME/DESKTOP_PASSWORD. Try the .env credentials for real (as the agent, credentials
# on stdin) and print the ones the dashboard actually accepts.
dash_login="user ${DESKTOP_USERNAME} / password ${DESKTOP_PASSWORD}   (DESKTOP_* in .env)"
_code="$(printf '%s\n%s\n' "$DESKTOP_USERNAME" "$DESKTOP_PASSWORD" | agent_run python3 -c '
import json, sys, urllib.request, urllib.error
u, p = sys.stdin.read().split("\n")[:2]
req = urllib.request.Request("http://%s:%s/auth/password-login" % (sys.argv[1], sys.argv[2]), method="POST",
    data=json.dumps({"provider": "basic", "username": u, "password": p, "next": "/"}).encode(),
    headers={"Content-Type": "application/json"})
try: print(urllib.request.urlopen(req, timeout=10).status)
except urllib.error.HTTPError as e: print(e.code)
except Exception: print(0)
' "${DESKTOP_BIND:-127.0.0.1}" "${DESKTOP_PORT:-9120}" 2>/dev/null || echo 0)"
case "$_code" in
  200) ;;
  401)
    # Same loader the dashboard runs: tells us the username it ended up with (never its password).
    _eff="$(agent_run python3 -c 'import os; from hermes_cli.env_loader import load_hermes_dotenv; load_hermes_dotenv(); print(os.environ.get("HERMES_DASHBOARD_BASIC_AUTH_USERNAME", ""))' 2>/dev/null || true)"
    warn "dashboard login: DESKTOP_USERNAME/DESKTOP_PASSWORD from .env are REJECTED — an external secret source (config.yaml secrets.*, e.g. Bitwarden) supplies HERMES_DASHBOARD_BASIC_AUTH_USERNAME/PASSWORD/SECRET and overrides them. Remove those secrets there to use the .env ones."
    dash_login="user ${_eff:-<see your secret source>} / password: the one in that secret source   (DESKTOP_* in .env are NOT in effect)" ;;
  *) warn "dashboard login could not be verified (HTTP $_code)"; dash_login="$dash_login — unverified" ;;
esac

# ── 6. systemd timers (nightly update, nightly backup once backup.sh setup ran) + CLIs on PATH ──
if [ "${ALLOW_NON_ROOT:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1; then
  for unit in "$STACK_DIR"/systemd/*; do
    sed "s|@STACK_DIR@|$STACK_DIR|g" "$unit" > "/etc/systemd/system/$(basename "$unit")"
  done
  docker_wait_for_tailscale   # ports bind DESKTOP_BIND: dockerd must not start before tailscaled has the IP
  systemctl daemon-reload
  ln -sfn "$STACK_DIR/command-center" /usr/local/bin/command-center
  ln -sfn "$STACK_DIR/bin/hermes" /usr/local/bin/hermes   # host `hermes` → the active release, as the agent
  systemctl enable --now hermes-update.timer hermes-heal.timer >/dev/null
  if [ -n "$(env_val B2_ACCOUNT_KEY)" ] && [ -n "$(env_val RESTIC_PASSWORD)" ]; then
    systemctl enable --now hermes-backup.timer >/dev/null
    backup_note="nightly 03:00 → ${RESTIC_REPOSITORY}"
  else
    backup_note="not configured — run: sudo ./backup.sh setup"
  fi
else
  backup_note="(timers skipped: no systemd / ALLOW_NON_ROOT)"
fi

compose ps
cat <<MSG

  Dashboard     : https://${HERMES_HOST}   (tailnet only)  — ${dash_login}
  Tailnet DNS   : ${DESKTOP_BIND}:53 answers ${DNS_ZONE} and *.${DNS_ZONE} → ${DESKTOP_BIND}
                  Tailscale admin console → DNS → Nameservers → Add nameserver → Custom → ${DESKTOP_BIND},
                  "Restrict to domain" → ${DNS_ZONE}. Then every tailnet device resolves the URL.
  Hermes Desktop: Settings → Gateways → Remote gateway → https://${HERMES_HOST} (or http://${DESKTOP_BIND}:${DESKTOP_PORT:-9120}),
                  same user / password
  PostgreSQL    : postgresql://${POSTGRES_USER}:<POSTGRES_PASSWORD in .env>@${DESKTOP_BIND}:${POSTGRES_PORT:-5432}/${POSTGRES_DB}   (tailnet; the agent uses 127.0.0.1:${POSTGRES_PORT:-5432} via PG* / DATABASE_URL)
  Agent         : default (sudo ./agent.sh status) — skills in ${HERMES_DATA_DIR}/skills, MCP in ${HERMES_DATA_DIR}/mcp
  Data dir      : ${HERMES_DATA_DIR}   (config, sessions, credentials, skills, private/)
  Hermes        : on the host — hermes-gateway + hermes-dashboard (systemd), release $(basename "$(readlink -f "$HERMES_CURRENT")")
  Workspace     : ${HERMES_WORKSPACE_DIR}   (Hermes, Orca, herdr, SSH; /workspace = alias)
  Backups       : ${backup_note}
  Updates       : nightly, 04:00 (hermes-update.timer) — images, Hermes release, CLIs; tested first, auto-rollback; undo: sudo ./update.sh rollback
  Healer        : hermes-heal.timer (every minute: restart unhealthy containers / a hung Hermes; touch .maintenance to pause)

  These secrets are also in .env (mode 600). Clear this terminal's scrollback if it is shared or logged.

Next: configure model providers, CLI logins and messaging with your subscriptions:

  sudo ./auth.sh
  sudo ./backup.sh setup     # Backblaze B2 backups (recommended before you rely on the agent)
  sudo ./orca.sh install     # optional: Orca remote server on the host (claude/codex/grok yourself, desktop + phone)
  sudo ./command-center      # menu: one-click deploy of orca / helios / herdr, status of every service

Traefik requests the certificate (DNS-01 via Cloudflare) as soon as it starts — give it ~1-2 min; no public DNS needed.
MSG
