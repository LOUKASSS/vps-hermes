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

# ask KEY "prompt" [secret] — keep existing/exported value, else prompt
ask() {
  local key="$1" prompt="$2" secret="${3:-}" cur val
  cur="$(env_val "$key")"
  [ -n "${!key:-}" ] && cur="${!key}"
  case "$cur" in
    ""|workspace.example.com|you@example.com) ;;
    *) set_env "$key" "$cur"; return ;;
  esac
  [ -t 0 ] || die "$key is not set and stdin is not a terminal. Set it in .env and re-run."
  if [ -n "$secret" ]; then read -r -s -p "$prompt: " val; echo; else read -r -p "$prompt: " val; fi
  [ -n "$val" ] || die "$key is required."
  set_env "$key" "$val"
}

ask WORKSPACE_HOST   "Public hostname for the workspace (e.g. workspace.example.com)"
ask ACME_EMAIL       "Email for Let's Encrypt"
ask CF_DNS_API_TOKEN "Cloudflare API token (Zone:DNS:Edit)" secret

# The gateway api_server refuses keys shorter than 16 chars.
_key="$(env_val API_SERVER_KEY)"
[ "${#_key}" -ge 16 ] || set_env API_SERVER_KEY "$(openssl rand -hex 32)"
[ -n "$(env_val HERMES_PASSWORD)" ] || set_env HERMES_PASSWORD "$(openssl rand -base64 24 | tr -d '/+=')"

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
info "Preparing ${HERMES_DATA_DIR}, ${HERMES_WORKSPACE_DIR}, ${TRAEFIK_DIR}"
mkdir -p "$HERMES_DATA_DIR/home" "$HERMES_WORKSPACE_DIR" "$TRAEFIK_DIR"
touch "$TRAEFIK_DIR/acme.json"; chmod 600 "$TRAEFIK_DIR/acme.json"
chown -R "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR"

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

compose ps
cat <<MSG

  Workspace URL : https://${WORKSPACE_HOST}$(command -v tailscale >/dev/null 2>&1 && ts=$(tailscale ip -4 2>/dev/null) && [ -n "$ts" ] && printf '   (DNS A record → %s, tailnet only)' "$ts")
  Login password: ${HERMES_PASSWORD}   (HERMES_PASSWORD in .env)
  Data dir      : ${HERMES_DATA_DIR}   (config, sessions, credentials)
  Files dir     : ${HERMES_WORKSPACE_DIR}   (drop files here → /workspace for the agent)

Next: configure model providers and CLI logins with your subscriptions:

  sudo ./auth.sh

The certificate is issued on the first HTTPS request; give Traefik ~1 min once DNS points here.
MSG
