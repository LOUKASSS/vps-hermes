#!/usr/bin/env bash
# Shared helpers for the command-center scripts (install.sh, auth.sh, update.sh, backup.sh,
# orca.sh, helios.sh, herdr.sh, command-center). Source, do not execute.
#
# /srv layout (one folder per project, one shared workspace):
#   /srv/command-center   this repo: scripts, compose, .env, state/traefik (STACK_DIR)
#   /srv/hermes           Hermes agent: data/ (/opt/data), obsidian/, postgres/
#   /srv/orca             Orca HOME (orca.service)
#   /srv/helios           Helios deployment: .env, tinyauth/ (code: WORKSPACE/projects/helios)
#   /srv/discord-backup   Discord backup bot: app/ releases, bws.env, var/ archives (discord-backup.sh)
#   /srv/workspace        shared projects — same absolute path on the host and in hermes-agent

# Physical path (-P): scripts reached through a compat symlink must still resolve to the real
# checkout, or compose would derive another project name / relative paths from the link.
STACK_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SRV_ROOT="${SRV_ROOT:-/srv}"

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

# Published ports bind the Tailscale IP (DESKTOP_BIND): make dockerd wait (up to 60 s) for
# tailscaled to have it at boot, or every container with a published port fails to start until
# heal.sh kicks it. Called by harden.sh (Ubuntu) and install.sh (any distro with Tailscale).
docker_wait_for_tailscale() {
  command -v tailscale >/dev/null 2>&1 || return 0
  install -d /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/10-tailscale.conf <<'UNIT'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 2; done; echo "docker: no Tailscale IP after 60 s, starting anyway" >&2'
UNIT
  systemctl daemon-reload
}

# .env is sourced, not exported wholesale: only the restic/B2 variables restic_run passes with
# `-e NAME` are exported, so child processes (npm, apt, curl|sh installers, docker build) never
# inherit the CF token, API key or passwords. compose reads .env itself.
load_env() {
  [ -f "$STACK_DIR/.env" ] || die "Missing $STACK_DIR/.env — run ./install.sh first."
  ! grep -q $'\r' "$STACK_DIR/.env" || die "$STACK_DIR/.env has CRLF line endings (edited on Windows?): sed -i 's/\\r\$//' .env"
  # shellcheck disable=SC1091
  . "$STACK_DIR/.env"
  : "${HERMES_UID:=1000}" "${HERMES_GID:=1000}"
  # Defaults = the /srv layout above (migrate-srv-layout.sh writes them into a live .env).
  : "${HERMES_DATA_DIR:=$SRV_ROOT/hermes/data}" "${HERMES_WORKSPACE_DIR:=$SRV_ROOT/workspace}" "${TRAEFIK_DIR:=$STACK_DIR/state/traefik}"
  : "${OBSIDIAN_DIR:=$SRV_ROOT/hermes/obsidian}" "${OBSIDIAN_VAULT_DIR:=vault}" "${ORCA_HOME:=$SRV_ROOT/orca}"
  : "${POSTGRES_DIR:=$SRV_ROOT/hermes/postgres}" "${POSTGRES_USER:=hermes}" "${POSTGRES_DB:=hermes}"
  : "${HELIOS_DIR:=$SRV_ROOT/helios}" "${HELIOS_SRC:=$HERMES_WORKSPACE_DIR/projects/helios}"
  : "${DISCORD_BACKUP_DIR:=$SRV_ROOT/discord-backup}"
  : "${HERMES_CONFIG_DIR:=$HERMES_WORKSPACE_DIR/projects/hermes-config}" "${HERMES_CONFIG_REPO:=https://github.com/LOUKASSS/hermes-config.git}"
  : "${OP_USER:=hermes}" "${OP_HOME:=$(getent passwd "${OP_USER}" 2>/dev/null | cut -d: -f6)}"
  : "${OP_HOME:=/home/$OP_USER}"
  : "${RESTIC_IMAGE:=restic/restic:latest}"
  [ -n "${RESTIC_REPOSITORY:-}" ] || RESTIC_REPOSITORY="b2:${B2_BUCKET:-}:hermes"
  export RESTIC_REPOSITORY RESTIC_IMAGE RESTIC_PASSWORD="${RESTIC_PASSWORD:-}" B2_ACCOUNT_ID="${B2_ACCOUNT_ID:-}" B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY:-}"
}

# no_symlink <path>… — refuse to chmod/chown/write through a path the agent container could have
# replaced with a symlink (it owns everything under its bind mounts).
no_symlink() { local p; for p in "$@"; do [ ! -L "$p" ] || die "$p is a symlink — refusing to touch it (check the data dir for tampering)"; done; }

# set_env KEY VALUE — write/replace KEY in .env (VALUE is stored literally: no quoting, one line)
# set_env KEY VALUE [file] — replace or append KEY=VALUE (default file: the stack .env).
set_env() {
  local key="$1" val="$2" f="${3:-$STACK_DIR/.env}" esc
  case "$val" in *$'\n'*) die "set_env $key: value must be a single line" ;; esac
  if grep -qs "^${key}=" "$f"; then
    # escape what sed would interpret in the replacement: \, & and our | delimiter
    esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
    sed -i "s|^${key}=.*|${key}=${esc}|" "$f"
  else
    [ ! -s "$f" ] || [ -z "$(tail -c1 "$f")" ] || echo >> "$f"   # file must end with a newline
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}
# env_val KEY — current value in .env (empty if unset)
env_val() { grep -E "^$1=" "$STACK_DIR/.env" | head -n1 | cut -d= -f2- || true; }
# unset_env KEY… — drop KEY=… lines from .env (retired variables)
unset_env() { local k; for k in "$@"; do sed -i "/^${k}=/d" "$STACK_DIR/.env"; done; }

# ask KEY "prompt" [secret] [regex] — keep existing/exported value, else prompt (dies without a
# TTY). Values are validated against the regex (default: printable ASCII, no spaces): a stray
# arrow-key escape or a pasted non-ASCII byte would otherwise land in .env and only surface much
# later (Let's Encrypt: "contact email contains non-ASCII characters"). Interactive input is
# re-asked until valid; a pre-set invalid value dies so a non-interactive run cannot proceed.
ask() {
  local key="$1" prompt="$2" secret="${3:-}" re="${4:-^[!-~]+$}" cur val
  cur="$(env_val "$key")"
  [ -n "${!key:-}" ] && cur="${!key}"
  case "$cur" in
    ""|hermes.example.com|workspace.example.com|you@example.com) ;;   # .env.example placeholders (old and new)
    *) LC_ALL=C grep -qE "$re" <<<"$cur" || die "$key=$cur is invalid (must match $re). Fix it in .env."
       set_env "$key" "$cur"; return ;;
  esac
  [ -t 0 ] || die "$key is not set and stdin is not a terminal. Set it in .env and re-run."
  while :; do
    if [ -n "$secret" ]; then read -r -s -p "$prompt: " val; echo; else read -r -e -p "$prompt: " val; fi
    LC_ALL=C grep -qE "$re" <<<"$val" && break
    warn "$key: invalid value (must match $re) — try again."
  done
  set_env "$key" "$val"
}

compose() {
  docker compose --project-directory "$STACK_DIR" "$@"
}

# Locks (flock on fd 9 / fd 8). STACK_LOCK serialises backup.sh and update.sh (they both touch the
# containers and the data dir); UPDATE_LOCK is held by update.sh only, heal.sh skips while it is
# held so it does not fight a recreate in progress.
STACK_LOCK=/run/lock/hermes-stack.lock
UPDATE_LOCK=/run/lock/hermes-update.lock
# lock_stack [-n|-w <secs>] — fd 9
lock_stack() { exec 9>"$STACK_LOCK"; flock "${@:--w 10800}" 9; }
# lock_update [-n] — fd 8
lock_update() { exec 8>"$UPDATE_LOCK"; flock "${@:--n}" 8 && UPDATE_LOCKED=1; }

# Files that switch the automation off:
#   .maintenance  → heal.sh does nothing (touch it before `docker compose stop <service>`)
#   .update-hold  → update.sh (timer) does nothing; written by `update.sh rollback`
# shellcheck disable=SC2034  # used by heal.sh / update.sh / auth.sh
MAINTENANCE_FLAG="$STACK_DIR/.maintenance"
# shellcheck disable=SC2034
UPDATE_HOLD="$STACK_DIR/.update-hold"

# notify <text> — optional push for unattended runs, to either or both of:
#   UPDATE_NOTIFY_HERMES  a `hermes send` target (telegram = its home channel, telegram:<chat_id>,
#                         discord:#ops…): the Hermes agent delivers it with the gateway's bot
#                         credentials — no LLM call; skipped while hermes-agent is not running
#   UPDATE_NOTIFY_URL     a Discord webhook gets {"content": …}, any other URL (ntfy.sh/<topic>, …)
#                         the plain text as the POST body.
# Never fails the caller.
notify() {
  local url="${UPDATE_NOTIFY_URL:-}" target="${UPDATE_NOTIFY_HERMES:-}" msg
  msg="[$(hostname)] $*"
  if [ -n "$target" ] && [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null)" = true ]; then
    timeout 60 docker exec -u "${HERMES_UID:-1000}:${HERMES_GID:-1000}" -e HOME=/opt/data/home hermes-agent \
      hermes send -q --to "$target" "$msg" >/dev/null 2>&1 || warn "notify: hermes send --to $target failed"
  fi
  [ -n "$url" ] || return 0
  case "$url" in
    https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*)
      python3 -c 'import json, sys; print(json.dumps({"content": sys.argv[1][:1900]}))' "$msg" \
        | curl -fsS -m 15 -H 'Content-Type: application/json' --data-binary @- "$url" >/dev/null 2>&1 || true ;;
    *) curl -fsS -m 15 --data-binary "$msg" "$url" >/dev/null 2>&1 || true ;;
  esac
}

# Resolve ORCA_VERSION=latest to the current release tag (GitHub API) and export it, so orca.sh
# installs/updates only when the tag differs from the installed one. Silently keeps "latest" when
# GitHub is unreachable (orca.sh then downloads the latest asset and reads the tag from its manifest).
orca_resolve_version() {
  case "${ORCA_VERSION:-latest}" in latest|"")
    local tag
    tag="$({ curl -fsSL --max-time 20 https://api.github.com/repos/stablyai/orca/releases/latest 2>/dev/null || true; } \
      | sed -n 's/^  *"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$tag" ]; then export ORCA_VERSION="$tag"; info "Orca: latest release is $tag"
    else warn "Orca: GitHub API unreachable, using the latest release asset"; fi ;;
  esac
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
# cwd = the workspace, mounted at the same absolute path as on the host (plus /workspace alias).
agent_exec() {
  compose exec -it -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home -w "$HERMES_WORKSPACE_DIR" hermes-agent "$@"
}

# Same, non-interactive (for scripts).
agent_run() {
  compose exec -T -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home -w "$HERMES_WORKSPACE_DIR" hermes-agent "$@"
}

# ensure_workspace — the shared project tree every tool works in (host: SSH / herdr / Orca;
# container: hermes-agent, same absolute path). Owned by HERMES_UID (= the operator user `hermes`
# and the agent's runtime uid), so both sides read and write it without ACLs. /workspace on the
# host is a symlink to it: paths written by the agent through its historical /workspace mount
# (git worktrees, kanban, handoffs) resolve on the host as well.
ensure_workspace() {
  local w="$HERMES_WORKSPACE_DIR" d
  no_symlink "$w"
  install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$w"
  for d in projects worktrees scratch db db/migrations; do
    [ -e "$w/$d" ] || install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$w/$d"
  done
  if [ -L /workspace ]; then
    [ "$(readlink /workspace)" = "$w" ] || ln -sfn "$w" /workspace
  elif [ ! -e /workspace ]; then
    ln -s "$w" /workspace
  else
    warn "/workspace exists on the host and is not a symlink — left alone (expected: symlink → $w)"
  fi
}

# as_op <cmd…> — run as the operator user (hermes) with its login HOME (herdr, helios deploy).
# HOME can be overridden: as_op_home <home> <cmd…>.
as_op_home() {
  local home="$1"; shift
  runuser -u "$OP_USER" -- env -i HOME="$home" USER="$OP_USER" LOGNAME="$OP_USER" SHELL=/bin/bash \
    PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" TERM="${TERM:-xterm}" LANG="${LANG:-C.UTF-8}" "$@"
}
as_op() { as_op_home "$OP_HOME" "$@"; }

# The Hermes agent as code (agent/, skills/, mcp/) is its own repo, cloned by the operator in the
# workspace: HERMES_CONFIG_DIR (github.com/LOUKASSS/hermes-config). The agent writes the workspace,
# so root never reads that checkout directly — hermes_config_snapshot exports its COMMITTED tree
# into a root-only temp dir, sets HCFG to it (removed on exit) and prints the commit applied:
#   - git runs as the operator: a repo's own .git/config (core.fsmonitor, hooks…) never runs as root;
#   - uncommitted changes to tracked files are refused, unless HERMES_CONFIG_ALLOW_DIRTY=1 (then
#     they are included, via `git stash create`: neither the tree nor the stash list is touched);
#   - untracked files are never applied.
#   hermes_config_snapshot [--diff]    --diff: warn instead of refusing a dirty checkout (HEAD shown)
hermes_config_snapshot() {
  local dir="$HERMES_CONFIG_DIR" ref=HEAD dirty head
  [ -d "$dir/.git" ] || die "missing $dir — clone it as $OP_USER: git clone $HERMES_CONFIG_REPO $dir"
  dirty="$(as_op git -C "$dir" status --porcelain --untracked-files=no)" || die "git status failed in $dir"
  head="$(as_op git -C "$dir" log -1 --format='%h %s' HEAD)" || die "no commit in $dir"
  if [ -n "$dirty" ]; then
    if [ "${1:-}" = --diff ]; then
      warn "$dir has uncommitted changes — compared: HEAD ($head)"
    elif [ "${HERMES_CONFIG_ALLOW_DIRTY:-0}" = 1 ]; then
      ref="$(as_op git -C "$dir" stash create)" || die "git stash create failed in $dir"
      warn "applying UNCOMMITTED changes of $dir on top of $head"
    else
      die "$dir has uncommitted changes — commit them first (or --allow-dirty to apply them for a test):"$'\n'"$dirty"
    fi
  fi
  HCFG="$(mktemp -d /tmp/hermes-config.XXXXXX)"
  # shellcheck disable=SC2064  # expand now: the path is fixed
  trap "rm -rf '$HCFG'" EXIT
  as_op git -C "$dir" archive --format=tar "$ref" | tar -x --no-same-owner -C "$HCFG" \
    || die "git archive of $dir failed"
  info "hermes-config $head${dirty:+ (+ uncommitted changes)}"
}

# hermes_config_ensure — clone HERMES_CONFIG_REPO as the operator when the checkout is missing
# (fresh VPS; a private repo needs the operator's gh login: sudo command-center herdr login gh).
hermes_config_ensure() {
  [ -d "$HERMES_CONFIG_DIR/.git" ] && return 0
  info "Cloning $HERMES_CONFIG_REPO → $HERMES_CONFIG_DIR (as $OP_USER)…"
  as_op git clone -q "$HERMES_CONFIG_REPO" "$HERMES_CONFIG_DIR" \
    || die "clone failed — log in as $OP_USER (gh auth login) and retry, or clone it yourself: git clone $HERMES_CONFIG_REPO $HERMES_CONFIG_DIR"
}

# One-off command in the Obsidian sync image (same HOME volume as the sidecar), interactive.
obsidian_exec() {
  compose --profile obsidian run --rm --no-deps -it obsidian-sync "$@"
}

# restic in a throwaway container. Backed-up host paths are mounted read-only at the same
# path inside the container so snapshot paths match the host. RESTIC_* / B2_* come from .env.
#   restic_run [--rw <hostdir>] <restic args…>     (--rw mounts <hostdir> at /restore, writable)
restic_run() {
  local tty=() rw=() orca=() helios=() discord=()
  # -t only when stdout is a terminal too: under a pty docker merges restic's stderr into
  # stdout, so a caller capturing stderr ($(… 2>&1 >/dev/null)) would get nothing.
  [ -t 0 ] && [ -t 1 ] && tty=(-it)
  if [ "${1:-}" = --rw ]; then rw=(-v "$2:/restore"); shift 2; fi
  [ -d "$ORCA_HOME" ] && orca=(-v "$ORCA_HOME:$ORCA_HOME:ro")   # Orca state + logins, when orca.sh installed it
  [ -d "$HELIOS_DIR" ] && helios=(-v "$HELIOS_DIR:$HELIOS_DIR:ro")   # Helios .env + tinyauth state
  [ -d "$DISCORD_BACKUP_DIR/var" ] && discord=(-v "$DISCORD_BACKUP_DIR/var:$DISCORD_BACKUP_DIR/var:ro")   # sealed Discord archives + bot state
  docker run --rm "${tty[@]}" "${rw[@]}" --name "hermes-restic-$$" --hostname hermes-vps \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
    -e RESTIC_CACHE_DIR=/cache -e TZ="${TZ:-UTC}" \
    -v hermes-restic-cache:/cache \
    -v "$HERMES_DATA_DIR:$HERMES_DATA_DIR:ro" \
    -v "$HERMES_WORKSPACE_DIR:$HERMES_WORKSPACE_DIR:ro" \
    -v "$TRAEFIK_DIR:$TRAEFIK_DIR:ro" \
    -v "$OBSIDIAN_DIR:$OBSIDIAN_DIR:ro" \
    -v "$POSTGRES_DIR/dumps:$POSTGRES_DIR/dumps:ro" \
    -v "$STACK_DIR/.env:$STACK_DIR/.env:ro" "${orca[@]}" "${helios[@]}" "${discord[@]}" \
    "$RESTIC_IMAGE" "$@"
}

# Recreate hermes-agent (new /opt/data/.env, new image…). Holds UPDATE_LOCK so heal.sh (every
# minute) does not "repair" it mid-recreate. The lock stays with the calling script until it
# exits (fd 8) — fine, these are short-lived commands.
# From a terminal, asks first when Hermes is working (the recreate cuts it); heal.sh (no terminal,
# container already sick) does not wait. The Hermes CLIs of herdr are resumed afterwards.
restart_agent() {
  [ "${UPDATE_LOCKED:-}" = 1 ] || lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
  local busy a
  if [ -t 0 ] && busy="$(hermes_busy)" && [ -n "$busy" ]; then
    warn "Hermes is working — recreating hermes-agent cuts it:"
    printf '%s\n' "$busy" | sed 's/^/  /' >&2
    read -r -p "Recreate hermes-agent anyway? [y/N] " a
    case "$a" in [yY]*) ;; *) die "cancelled — hermes-agent left running" ;; esac
  fi
  hermes_panes_snapshot
  compose up -d --force-recreate hermes-agent
  wait_healthy hermes-agent 180 || warn "hermes-agent not healthy after 3 min: docker compose logs hermes-agent"
  hermes_sessions_restore
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

# Hermes work / herdr sessions around a recreate of hermes-agent (update.sh, restart_agent).
# shellcheck source=lib/agent-sessions.sh
. "$STACK_DIR/lib/agent-sessions.sh"
