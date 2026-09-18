#!/usr/bin/env bash
# Bootstrap the Hermes stack on a fresh Debian/Ubuntu VPS. Idempotent: safe to re-run.
#
#   sudo ./install.sh
#
# Non-interactive: pre-fill WORKSPACE_HOST, ACME_EMAIL, CF_DNS_API_TOKEN in .env (or pass them
# through sudo: `sudo WORKSPACE_HOST=… ./install.sh`) and the script will not prompt.
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
command -v openssl >/dev/null 2>&1 || { apt-get update && apt-get install -y --no-install-recommends openssl; }

# ── 2. .env ──────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  info "Creating .env from .env.example"
  cp .env.example .env
fi
chmod 600 .env

ask WORKSPACE_HOST   "Public hostname for the workspace (e.g. workspace.example.com)"
ask ACME_EMAIL       "Email for Let's Encrypt"
ask CF_DNS_API_TOKEN "Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)" secret
# DNS zone served to the tailnet: WORKSPACE_HOST itself unless you chose a wider one.
_zone="$(env_val DNS_ZONE)"; _host="$(env_val WORKSPACE_HOST)"
[ -n "$_zone" ] || { _zone="$_host"; set_env DNS_ZONE "$_zone"; }
case "$_host" in "$_zone"|*".$_zone") ;; *) die "WORKSPACE_HOST=$_host is not under DNS_ZONE=$_zone (fix DNS_ZONE in .env)." ;; esac
# The zone is answered as a wildcard: an apex (example.com) would hijack mail./www. for the tailnet.
case "$_zone" in *.*.*) ;; *) warn "DNS_ZONE=$_zone looks like a registrable apex: every *.$_zone (www, mail…) will resolve to this VPS for tailnet devices. Prefer a subdomain, e.g. hermes.$_zone." ;; esac

# The gateway api_server refuses keys shorter than 16 chars.
_key="$(env_val API_SERVER_KEY)"
[ "${#_key}" -ge 16 ] || set_env API_SERVER_KEY "$(openssl rand -hex 32)"
[ -n "$(env_val HERMES_PASSWORD)" ] || set_env HERMES_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"
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
  warn "No Tailscale IP found: Traefik (80/443), Desktop backend (9120), DNS (53) and Orca (6768) stay on $(env_val DESKTOP_BIND). Run harden.sh (Tailscale) and re-run, or set DESKTOP_BIND in .env to a private IP yourself."
fi
# Port 53 is published on DESKTOP_BIND; a resolver bound to 0.0.0.0 or to that same IP would clash.
_bind="$(env_val DESKTOP_BIND)"
if ss -lunH 'sport = :53' 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]|${_bind//./\\.}):"; then
  warn "something already listens on ${_bind}:53 ($(ss -lunpH 'sport = :53' | awk '{print $4, $NF}' | head -n1)) — the dns service will fail to start until it is moved/stopped."
fi

# Owner of /srv/hermes/*: the `hermes` operator user created by harden.sh (always re-derived:
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

# ── 3. Host storage ──────────────────────────────────────────────────────
info "Preparing ${HERMES_DATA_DIR}, ${HERMES_WORKSPACE_DIR}, ${TRAEFIK_DIR}, ${OBSIDIAN_DIR}, ${POSTGRES_DIR}"
mkdir -p "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$TRAEFIK_DIR" "$OBSIDIAN_DIR"
# data/ is chowned to the postgres user by the image's entrypoint; dumps/ is written by backup.sh (root).
mkdir -p "$POSTGRES_DIR/data" "$POSTGRES_DIR/dumps"; chmod 700 "$POSTGRES_DIR" "$POSTGRES_DIR/dumps"
no_symlink "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR"
touch "$TRAEFIK_DIR/acme.json"; chmod 600 "$TRAEFIK_DIR/acme.json"
chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR" "$TRAEFIK_DIR" "$OBSIDIAN_DIR"
# Credentials live here (OAuth tokens under data/home, Obsidian login under obsidian/): owner only.
chmod 700 "$HERMES_DATA_DIR" "$HERMES_DATA_DIR/home" "$OBSIDIAN_DIR" "$TRAEFIK_DIR"
# .env belongs to the operator (harden.sh already made them own the whole checkout, so day-to-day
# `docker compose` / `git pull` work without sudo). The rest of the repo is deliberately left
# alone: chown -R on .git would make root's git refuse the repo ("dubious ownership").
chown "$HERMES_UID:$HERMES_GID" .env; chmod 600 .env

# ── 4. Build + start ─────────────────────────────────────────────────────
# Keep heal.sh (timer, every minute) out of the way while containers are (re)created.
if [ "${ALLOW_NON_ROOT:-}" != 1 ]; then
  lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
fi
info "Building derived image (pulls nousresearch/hermes-agent:latest)…"
compose build --pull
info "Pulling remaining images…"
compose pull --ignore-buildable
info "Starting stack…"
compose up -d --remove-orphans

# ── 5. Wait for health + first-boot config ───────────────────────────────
info "Waiting for hermes-agent to become healthy (up to 3 min)…"
wait_healthy hermes-agent 180 || { compose logs --tail=50 hermes-agent; die "hermes-agent not healthy after 3 min."; }

# The image seeds config.yaml on first boot; point the agent's terminal at the shared files dir.
if [ "$(agent_run hermes config get terminal.cwd 2>/dev/null | tr -d '[:space:]')" != "/workspace" ]; then
  info "Setting terminal.cwd = /workspace"
  agent_run hermes config set terminal.cwd /workspace >/dev/null
fi

# ── 6. systemd timers: weekly update, nightly backup (enabled once backup.sh setup ran) ──
if [ "${ALLOW_NON_ROOT:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1; then
  for unit in "$STACK_DIR"/systemd/*; do
    sed "s|@STACK_DIR@|$STACK_DIR|g" "$unit" > "/etc/systemd/system/$(basename "$unit")"
  done
  systemctl daemon-reload
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

  Workspace URL : https://${WORKSPACE_HOST}   (tailnet only)
  Tailnet DNS   : ${DESKTOP_BIND}:53 answers ${DNS_ZONE} and *.${DNS_ZONE} → ${DESKTOP_BIND}
                  Tailscale admin console → DNS → Nameservers → Add nameserver → Custom → ${DESKTOP_BIND},
                  "Restrict to domain" → ${DNS_ZONE}. Then every tailnet device resolves the URL.
  Login password: ${HERMES_PASSWORD}   (HERMES_PASSWORD in .env)
  Hermes Desktop: Settings → Gateways → Remote gateway → http://${DESKTOP_BIND}:${DESKTOP_PORT:-9120}
                  user ${DESKTOP_USERNAME} / password ${DESKTOP_PASSWORD}   (DESKTOP_* in .env)
  PostgreSQL    : postgresql://${POSTGRES_USER}:<POSTGRES_PASSWORD in .env>@${DESKTOP_BIND}:${POSTGRES_PORT:-5432}/${POSTGRES_DB}   (tailnet; the agent uses hermes-postgres:5432 via PG* / DATABASE_URL)
  Data dir      : ${HERMES_DATA_DIR}   (config, sessions, credentials)
  Files dir     : ${HERMES_WORKSPACE_DIR}   (drop files here → /workspace for the agent)
  Backups       : ${backup_note}
  Updates       : weekly, Sunday 03:30 (hermes-update.timer) — manual: sudo ./update.sh; undo: sudo ./update.sh rollback
  Healer        : hermes-heal.timer (every minute: restart unhealthy, start exited; touch .maintenance to pause)

  These secrets are also in .env (mode 600). Clear this terminal's scrollback if it is shared or logged.

Next: configure model providers, CLI logins and messaging with your subscriptions:

  sudo ./auth.sh
  sudo ./backup.sh setup     # Backblaze B2 backups (recommended before you rely on the agent)
  sudo ./orca.sh install     # optional: Orca remote server on the host (claude/codex/grok yourself, desktop + phone)

Traefik requests the certificate (DNS-01 via Cloudflare) as soon as it starts — give it ~1-2 min; no public DNS needed.
MSG
