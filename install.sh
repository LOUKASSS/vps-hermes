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
ask CF_DNS_API_TOKEN "Cloudflare API token (Zone:DNS:Edit)" secret

# The gateway api_server refuses keys shorter than 16 chars.
_key="$(env_val API_SERVER_KEY)"
[ "${#_key}" -ge 16 ] || set_env API_SERVER_KEY "$(openssl rand -hex 32)"
[ -n "$(env_val HERMES_PASSWORD)" ] || set_env HERMES_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"
[ -n "$(env_val DESKTOP_PASSWORD)" ] || set_env DESKTOP_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"
[ -n "$(env_val DESKTOP_SECRET)" ]   || set_env DESKTOP_SECRET "$(openssl rand -base64 32 | tr -d '/+=')"
[ -n "$(env_val DESKTOP_USERNAME)" ] || set_env DESKTOP_USERNAME admin
# Publish the Desktop backend on the Tailscale IP only when the VPS is on a tailnet.
TS_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null || true)"
if [ -n "$TS_IP" ]; then
  set_env DESKTOP_BIND "$TS_IP"
else
  [ -n "$(env_val DESKTOP_BIND)" ] || set_env DESKTOP_BIND 127.0.0.1
  warn "No Tailscale IP found: Desktop backend (9120) and Orca (6768) stay on $(env_val DESKTOP_BIND). Run harden.sh (Tailscale) and re-run, or set DESKTOP_BIND in .env to a private IP yourself."
fi

# Owner of /srv/hermes/*: the `hermes` operator user created by harden.sh if present,
# else the user who invoked sudo, else 1000.
if id hermes >/dev/null 2>&1; then
  owner_uid="$(id -u hermes)"; owner_gid="$(id -g hermes)"
else
  owner_uid="${SUDO_UID:-1000}"; owner_gid="${SUDO_GID:-1000}"
  [ "$owner_uid" -eq 0 ] && { owner_uid=1000; owner_gid=1000; }
fi
[ "$(env_val HERMES_UID)" != "1000" ] && [ -n "$(env_val HERMES_UID)" ] || set_env HERMES_UID "$owner_uid"
[ "$(env_val HERMES_GID)" != "1000" ] && [ -n "$(env_val HERMES_GID)" ] || set_env HERMES_GID "$owner_gid"

load_env

# ── 3. Host storage ──────────────────────────────────────────────────────
info "Preparing ${HERMES_DATA_DIR}, ${HERMES_WORKSPACE_DIR}, ${TRAEFIK_DIR}, ${OBSIDIAN_DIR}"
mkdir -p "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$TRAEFIK_DIR" "$OBSIDIAN_DIR"
touch "$TRAEFIK_DIR/acme.json"; chmod 600 "$TRAEFIK_DIR/acme.json"
chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR" "$TRAEFIK_DIR" "$OBSIDIAN_DIR"
# The stack dir (this repo, incl. .env) belongs to the operator too, so `docker compose` works
# without sudo for the operator (docker group) and .env stays readable by them only.
chown -R "$HERMES_UID:$HERMES_GID" "$STACK_DIR"
chown "$HERMES_UID:$HERMES_GID" .env; chmod 600 .env

# ── 4. Build + start ─────────────────────────────────────────────────────
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

  Workspace URL : https://${WORKSPACE_HOST}$([ -n "$TS_IP" ] && printf '   (DNS A record → %s, tailnet only)' "$TS_IP")
  Login password: ${HERMES_PASSWORD}   (HERMES_PASSWORD in .env)
  Hermes Desktop: Settings → Gateways → Remote gateway → http://${DESKTOP_BIND}:${DESKTOP_PORT:-9120}
                  user ${DESKTOP_USERNAME} / password ${DESKTOP_PASSWORD}   (DESKTOP_* in .env)
  Data dir      : ${HERMES_DATA_DIR}   (config, sessions, credentials)
  Files dir     : ${HERMES_WORKSPACE_DIR}   (drop files here → /workspace for the agent)
  Backups       : ${backup_note}
  Updates       : weekly, Sunday 03:30 (hermes-update.timer) — manual: sudo ./update.sh
  Healer        : hermes-heal.timer (every minute: restart unhealthy, start exited)

Next: configure model providers, CLI logins and messaging with your subscriptions:

  sudo ./auth.sh
  sudo ./backup.sh setup     # Backblaze B2 backups (recommended before you rely on the agent)
  sudo ./auth.sh orca        # optional: Orca remote server (claude/codex/grok yourself, desktop + phone)

The certificate is issued on the first HTTPS request; give Traefik ~1 min once DNS points here.
MSG
