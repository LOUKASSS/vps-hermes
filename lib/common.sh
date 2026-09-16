#!/usr/bin/env bash
# Shared helpers for install.sh / auth.sh / update.sh / backup.sh. Source, do not execute.

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
  : "${HERMES_DATA_DIR:=/srv/hermes/data}" "${HERMES_WORKSPACE_DIR:=/srv/hermes/workspace}" "${TRAEFIK_DIR:=/srv/hermes/traefik}"
  : "${OBSIDIAN_DIR:=/srv/hermes/obsidian}" "${OBSIDIAN_VAULT_DIR:=vault}"
  : "${RESTIC_IMAGE:=restic/restic:latest}"
  [ -n "${RESTIC_REPOSITORY:-}" ] || RESTIC_REPOSITORY="b2:${B2_BUCKET:-}:hermes"
  export RESTIC_REPOSITORY RESTIC_IMAGE
}

# set_env KEY VALUE — write/replace KEY in .env
set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$STACK_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$STACK_DIR/.env"
  else
    printf '%s=%s\n' "$key" "$val" >> "$STACK_DIR/.env"
  fi
}
# env_val KEY — current value in .env (empty if unset)
env_val() { grep -E "^$1=" "$STACK_DIR/.env" | head -n1 | cut -d= -f2- || true; }

# ask KEY "prompt" [secret] — keep existing/exported value, else prompt (dies without a TTY)
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

compose() {
  docker compose --project-directory "$STACK_DIR" "$@"
}

# enable_profile <name> — add a compose profile to COMPOSE_PROFILES in .env (comma list) + export it.
enable_profile() {
  local cur; cur="$(env_val COMPOSE_PROFILES)"
  case ",$cur," in *",$1,"*) ;; *) cur="${cur:+$cur,}$1"; set_env COMPOSE_PROFILES "$cur" ;; esac
  export COMPOSE_PROFILES="$cur"
}

# Interactive command inside the agent container, as the runtime user, with HOME set
# to the tool-subprocess home so CLI credentials land where the agent's own tool calls
# will find them (/opt/data/home/.claude, .codex, .grok, .config/gh).
agent_exec() {
  compose exec -it -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home -w /workspace hermes-agent "$@"
}

# Same, non-interactive (for scripts).
agent_run() {
  compose exec -T -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home -w /workspace hermes-agent "$@"
}

# One-off command in the Obsidian sync image (same HOME volume as the sidecar), interactive.
obsidian_exec() {
  compose --profile obsidian run --rm --no-deps -it obsidian-sync "$@"
}

# restic in a throwaway container. Backed-up host paths are mounted read-only at the same
# path inside the container so snapshot paths match the host. RESTIC_* / B2_* come from .env.
#   restic_run [--rw <hostdir>] <restic args…>     (--rw mounts <hostdir> at /restore, writable)
restic_run() {
  local tty=() rw=()
  [ -t 0 ] && tty=(-it)
  if [ "${1:-}" = --rw ]; then rw=(-v "$2:/restore"); shift 2; fi
  docker run --rm "${tty[@]}" "${rw[@]}" --name hermes-restic --hostname hermes-vps \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
    -e RESTIC_CACHE_DIR=/cache -e TZ="${TZ:-UTC}" \
    -v hermes-restic-cache:/cache \
    -v "$HERMES_DATA_DIR:$HERMES_DATA_DIR:ro" \
    -v "$HERMES_WORKSPACE_DIR:$HERMES_WORKSPACE_DIR:ro" \
    -v "$TRAEFIK_DIR:$TRAEFIK_DIR:ro" \
    -v "$OBSIDIAN_DIR:$OBSIDIAN_DIR:ro" \
    -v "$STACK_DIR/.env:$STACK_DIR/.env:ro" \
    "$RESTIC_IMAGE" "$@"
}

# Recreate hermes-agent (new /opt/data/.env, new image…). A plain `restart` would leave the
# containers sharing its netns (workspace, dashboard) in the orphaned namespace; `up -d
# --force-recreate` recreates the dependants too.
restart_agent() {
  compose up -d --force-recreate hermes-agent
  wait_healthy hermes-agent 180 || warn "hermes-agent not healthy after 3 min: docker compose logs hermes-agent"
}

# wait_healthy <container> <seconds>
wait_healthy() {
  local name="$1" secs="${2:-180}" status=starting
  for _ in $(seq 1 $((secs / 5))); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo starting)"
    [ "$status" = healthy ] && return 0
    sleep 5
  done
  return 1
}
