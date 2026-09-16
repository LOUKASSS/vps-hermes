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
  : "${HERMES_DATA_DIR:=/srv/hermes/data}" "${HERMES_WORKSPACE_DIR:=/srv/hermes/workspace}" "${TRAEFIK_DIR:=/srv/hermes/traefik}"
  : "${OBSIDIAN_DIR:=/srv/hermes/obsidian}" "${OBSIDIAN_VAULT_DIR:=vault}"
}

compose() {
  docker compose --project-directory "$STACK_DIR" "$@"
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
