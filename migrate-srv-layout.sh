#!/usr/bin/env bash
# Move a live install from the /srv/hermes/* layout to one folder per project under /srv:
#
#   /srv/hermes/stack                    → /srv/command-center           (this repo, .env)
#   /srv/hermes/traefik                  → /srv/command-center/state/traefik
#   /srv/hermes/projects                 → /srv/workspace                (shared projects)
#   /srv/hermes/helios (git repo)        → /srv/workspace/projects/helios  (code)
#       its .env, tinyauth/data          → /srv/helios/                  (deployment)
#   /srv/hermes/data/projects/<repo>     → /srv/workspace/projects/<repo>  (symlink left behind:
#                                          the agent's kanban worktrees point at /opt/data/projects/…)
#   /srv/hermes/orca                     → /srv/orca                     (Orca HOME)
#   /srv/hermes/{data,obsidian,postgres} stay: /srv/hermes is the Hermes agent project.
#
#   sudo ./migrate-srv-layout.sh --dry-run   # print the plan
#   sudo ./migrate-srv-layout.sh             # phase 1: everything but restarting Orca
#   sudo command-center migrate finalize     # phase 2: stop Orca, rewrite its paths, start it, drop compat links
#
# Phase 1 stops the compose stack and Helios (a few minutes of downtime), moves the directories,
# rewrites .env, re-renders the systemd units, and starts everything on the new paths. Orca keeps
# running (it may be the very session running this script): its HOME and the repos it has open are
# reached through compat symlinks left in /srv/hermes until phase 2. Phase 2 restarts Orca — every
# Orca session ends — so it runs detached (systemd-run) and only when you ask for it.
# Both phases are idempotent: each step checks whether it is already done.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root

OLD=/srv/hermes
NEW_STACK=/srv/command-center
NEW_WS=/srv/workspace
NEW_ORCA=/srv/orca
NEW_HELIOS=/srv/helios
NEW_HELIOS_SRC="$NEW_WS/projects/helios"
NEW_TRAEFIK="$NEW_STACK/state/traefik"
COMPAT_LINKS=("$OLD/stack" "$OLD/orca" "$OLD/projects" "$OLD/helios")

DRY=0
run() { if [ "$DRY" = 1 ]; then printf '    would: %s\n' "$*"; else "$@"; fi; }

# move_dir <src> <dst> [compat] — rename (same filesystem: atomic, open files keep working);
# compat=1 leaves <src> as a symlink to <dst> until `finalize`.
move_dir() {
  local src="$1" dst="$2" compat="${3:-0}"
  if [ -L "$src" ]; then
    [ "$(readlink "$src")" = "$dst" ] && { info "  $src → $dst (done)"; return 0; }
    die "$src is a symlink to $(readlink "$src"), expected $dst"
  fi
  if [ ! -e "$src" ]; then
    [ -e "$dst" ] && info "  $src → $dst (done, no compat link)" || warn "  $src absent — nothing to move"
    return 0
  fi
  [ ! -e "$dst" ] || die "both $src and $dst exist — merge them by hand first"
  info "  mv $src → $dst$([ "$compat" = 1 ] && echo ' (+ compat symlink)' || true)"
  run install -d -m 0755 "$(dirname "$dst")"
  run mv -T "$src" "$dst"
  [ "$compat" = 1 ] && run ln -s "$dst" "$src"
  return 0
}

in_orca_cgroup() { grep -q 'orca.service' /proc/self/cgroup 2>/dev/null; }

# ── phase 1 ─────────────────────────────────────────────────────────────
phase1() {
  local cur_stack; cur_stack="$STACK_DIR"
  load_env
  info "Migration to the /srv layout ($([ "$DRY" = 1 ] && echo DRY RUN || echo live))"
  [ -d "$NEW_STACK/.git" ] || [ -d "$OLD/stack/.git" ] || die "no checkout at $OLD/stack or $NEW_STACK"
  [ -f "$cur_stack/.env" ] || die "missing $cur_stack/.env"
  for d in "$OLD/stack" "$OLD/projects" "$OLD/orca"; do
    [ ! -e "$d" ] || [ -L "$d" ] || [ -d "$d" ] || die "$d is not a directory"
  done

  if [ "$DRY" = 0 ]; then
    lock_update -w 300 || die "heal.sh or update.sh is busy (lock $UPDATE_LOCK)"
    touch "$cur_stack/.maintenance"
  fi

  info "1. Stop Helios and the compose stack (Orca keeps running)"
  local helios_old="$OLD/helios" hp
  if [ -f "$helios_old/compose.yaml" ] && [ ! -L "$helios_old" ]; then
    run bash -c "cd '$helios_old' && docker compose --profile '*' down --remove-orphans"
  fi
  hp="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' hermes-agent 2>/dev/null || true)"
  if [ -n "$hp" ] && [ "$hp" != command-center ]; then
    info "  compose project '$hp' → down (networks are recreated by project command-center; proxy keeps 172.20.0.0/16)"
    run docker compose -p "$hp" --project-directory "$cur_stack" --profile '*' down --remove-orphans
  elif [ "$hp" = command-center ]; then
    info "  stack already runs as project command-center"
  fi

  info "2. Move directories"
  move_dir "$OLD/stack" "$NEW_STACK" 1
  install_state_traefik
  move_dir "$OLD/projects" "$NEW_WS" 1
  move_helios
  move_data_projects
  move_dir "$OLD/orca" "$NEW_ORCA" 1

  [ "$DRY" = 1 ] && { info "dry run: stopping here (next steps: .env, systemd units, workspace, start, helios, orca unit)"; return 0; }

  # From here on, work from the new checkout.
  STACK_DIR="$NEW_STACK"; MAINTENANCE_FLAG="$STACK_DIR/.maintenance"
  cd "$STACK_DIR"

  info "3. .env → new paths"
  set_env HERMES_WORKSPACE_DIR "$NEW_WS"
  set_env TRAEFIK_DIR "$NEW_TRAEFIK"
  sed -i 's|^# ORCA_HOME=.*$||' .env
  set_env ORCA_HOME "$NEW_ORCA"
  set_env HELIOS_DIR "$NEW_HELIOS"
  set_env HELIOS_SRC "$NEW_HELIOS_SRC"
  [ -n "$(env_val PROXY_SUBNET)" ] || set_env PROXY_SUBNET 172.20.0.0/16
  load_env

  info "4. Workspace ($HERMES_WORKSPACE_DIR, /workspace symlink, ownership)"
  ensure_workspace
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_WORKSPACE_DIR"

  info "5. Agent memory: host paths"
  local mem="$HERMES_DATA_DIR/MEMORY.md"
  if [ -f "$mem" ] && [ ! -L "$mem" ] && grep -q '/srv/hermes/workspace\|/srv/hermes/projects' "$mem"; then
    cp -p "$mem" "$mem.pre-srv-layout"
    sed -i -e 's|Cwd `/workspace` (hôte `/srv/hermes/workspace`)|Cwd `/srv/workspace` (même chemin sur l'"'"'hôte ; alias `/workspace`)|' \
           -e 's|/srv/hermes/workspace|/srv/workspace|g; s|/srv/hermes/projects|/srv/workspace|g' "$mem"
    info "  MEMORY.md updated (backup: MEMORY.md.pre-srv-layout)"
  fi

  info "6. systemd units + command-center on PATH"
  local unit
  for unit in "$STACK_DIR"/systemd/*; do
    sed "s|@STACK_DIR@|$STACK_DIR|g" "$unit" > "/etc/systemd/system/$(basename "$unit")"
  done
  systemctl daemon-reload
  ln -sfn "$STACK_DIR/command-center" /usr/local/bin/command-center
  if [ -e /etc/systemd/system/orca.service ]; then
    "$STACK_DIR/orca.sh" write-service   # HOME=/srv/orca, cwd /srv/workspace — applies at the next Orca restart
  fi

  info "7. Start the stack (project command-center)"
  compose up -d --remove-orphans
  wait_healthy hermes-agent 240 || { compose logs --tail=60 hermes-agent; die "hermes-agent not healthy — fix, then re-run this script"; }
  if [ "$(agent_run hermes config get terminal.cwd 2>/dev/null | tr -d '[:space:]')" != "$HERMES_WORKSPACE_DIR" ]; then
    agent_run hermes config set terminal.cwd "$HERMES_WORKSPACE_DIR" >/dev/null && info "  terminal.cwd = $HERMES_WORKSPACE_DIR"
  fi
  CUTOVER=1 UPDATE_LOCKED=1 "$STACK_DIR/agent.sh" sync-files
  agent_run sh -c 'test -w "$WORKSPACE_DIR" && test -w /workspace' || die "the agent cannot write $HERMES_WORKSPACE_DIR"
  info "  agent writes $HERMES_WORKSPACE_DIR (and /workspace alias)"

  info "8. Helios from $HELIOS_SRC with $HELIOS_DIR/.env"
  if [ -f "$HELIOS_DIR/.env" ] && [ -f "$HELIOS_SRC/compose.yaml" ]; then
    "$STACK_DIR/helios.sh" deploy || warn "helios deploy failed — sudo command-center helios deploy"
  else
    warn "  Helios not deployed ($HELIOS_DIR/.env or $HELIOS_SRC missing)"
  fi

  rm -f "$MAINTENANCE_FLAG"
  compose ps
  cat <<MSG

  Phase 1 done. /srv: command-center, hermes, orca, helios, workspace.
  Compat symlinks kept for the running Orca: ${COMPAT_LINKS[*]}
  Next:
    sudo command-center herdr install        # herdr + terminal-code
    sudo command-center migrate finalize     # restarts Orca (ends its sessions), rewrites its paths, drops the links
MSG
}

install_state_traefik() {
  local old="$OLD/traefik"
  if [ -d "$old" ] && [ ! -L "$old" ]; then
    [ ! -e "$NEW_TRAEFIK" ] || die "both $old and $NEW_TRAEFIK exist"
    info "  mv $old → $NEW_TRAEFIK"
    run install -d -m 0755 "$NEW_STACK/state"
    run mv -T "$old" "$NEW_TRAEFIK"
  else
    info "  traefik state: $NEW_TRAEFIK (done)"
  fi
}

# Helios: the git checkout becomes workspace code, its deployment state goes to /srv/helios.
move_helios() {
  local old="$OLD/helios"
  if [ -d "$old" ] && [ ! -L "$old" ]; then
    run install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$NEW_HELIOS" "$NEW_HELIOS/tinyauth"
    if [ -f "$old/.env" ]; then
      [ ! -e "$NEW_HELIOS/.env" ] || die "both $old/.env and $NEW_HELIOS/.env exist"
      info "  mv $old/.env → $NEW_HELIOS/.env"; run mv "$old/.env" "$NEW_HELIOS/.env"
    fi
    if [ -d "$old/tinyauth/data" ]; then
      [ ! -e "$NEW_HELIOS/tinyauth/data" ] || die "both $old/tinyauth/data and $NEW_HELIOS/tinyauth/data exist"
      info "  mv $old/tinyauth/data → $NEW_HELIOS/tinyauth/data"; run mv "$old/tinyauth/data" "$NEW_HELIOS/tinyauth/data"
    fi
  fi
  move_dir "$old" "$NEW_HELIOS_SRC" 1
  if [ -f "$NEW_HELIOS/.env" ] && [ "$DRY" = 0 ]; then
    set_env AGENT_DIR "$NEW_WS/helios" "$NEW_HELIOS/.env"
    chown "$HERMES_UID:$HERMES_GID" "$NEW_HELIOS" "$NEW_HELIOS/.env"; chmod 600 "$NEW_HELIOS/.env"
  fi
}

# Repos the agent created under its HOME (/opt/data/projects) join the workspace; an absolute
# symlink stays behind so /opt/data/projects/<repo> (kanban worktrees, sessions) still resolves in
# the container, where /srv/workspace is mounted at the same path.
move_data_projects() {
  local d="$HERMES_DATA_DIR/projects" r name
  [ -d "$d" ] || return 0
  for r in "$d"/*; do
    [ -e "$r" ] || continue
    name="$(basename "$r")"
    if [ -L "$r" ]; then info "  $r → $(readlink "$r") (done)"; continue; fi
    [ -d "$r" ] || continue
    [ ! -e "$NEW_WS/projects/$name" ] && [ ! -e "$OLD/projects/projects/$name" ] || die "$name exists both in $d and in the workspace"
    info "  mv $r → $NEW_WS/projects/$name (+ symlink for the agent's old paths)"
    if [ "$DRY" = 1 ]; then printf '    would: mv %s %s/projects/%s\n' "$r" "$NEW_WS" "$name"; continue; fi
    mv -T "$r" "$NEW_WS/projects/$name"
    ln -s "$NEW_WS/projects/$name" "$r"; chown -h "$HERMES_UID:$HERMES_GID" "$r"
  done
}

# ── phase 2: Orca ───────────────────────────────────────────────────────
# Rewrites absolute paths in Orca's (and the SSH user's) state, while Orca is stopped.
rewrite_paths() {
  python3 - "$@" <<'PY'
import os, sys
MAP = [
    ("/srv/hermes/data/projects/", "/srv/workspace/projects/"),
    ("/srv/hermes/helios", "/srv/workspace/projects/helios"),
    ("/srv/hermes/projects", "/srv/workspace"),
    ("/srv/hermes/workspace", "/srv/workspace"),
    ("/srv/hermes/stack", "/srv/command-center"),
    ("/srv/hermes/orca", "/srv/orca"),
]
for p in sys.argv[1:]:
    if not os.path.isfile(p) or os.path.islink(p):
        continue
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        s = f.read()
    t = s
    for a, b in MAP:
        t = t.replace(a, b)
    if t != s:
        st = os.stat(p)
        tmp = p + ".srv-tmp"
        with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(t)
        os.chown(tmp, st.st_uid, st.st_gid); os.chmod(tmp, st.st_mode & 0o7777)
        os.replace(tmp, p)
        print("    rewrote", p)
PY
}

# Claude Code keys its per-project dirs by path (/srv/hermes/stack → -srv-hermes-stack).
rename_claude_projects() {
  local base="$1/.claude/projects" d n
  [ -d "$base" ] || return 0
  for d in "$base"/-srv-hermes-*; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    case "$n" in
      -srv-hermes-data-projects-*) n="-srv-workspace-projects-${n#-srv-hermes-data-projects-}" ;;
      -srv-hermes-helios*)         n="-srv-workspace-projects-helios${n#-srv-hermes-helios}" ;;
      -srv-hermes-projects*)       n="-srv-workspace${n#-srv-hermes-projects}" ;;
      -srv-hermes-stack*)          n="-srv-command-center${n#-srv-hermes-stack}" ;;
      -srv-hermes-orca*)           n="-srv-orca${n#-srv-hermes-orca}" ;;
      *) continue ;;
    esac
    if [ -e "$base/$n" ]; then
      cp -an "$d/." "$base/$n/" && rm -rf "$d"
    else
      mv -T "$d" "$base/$n"
    fi
    echo "    $(basename "$d") → $n"
  done
}

finalize() {
  if in_orca_cgroup && [ "${1:-}" != --detached ]; then
    info "Running from an Orca session: finalize restarts Orca, which ends this very session."
    info "Launching it detached — follow with: journalctl -u command-center-finalize -f"
    systemd-run --unit=command-center-finalize --collect --quiet \
      "$(readlink -f "$0")" finalize --detached
    return 0
  fi
  load_env
  [ "$ORCA_HOME" = "$NEW_ORCA" ] || die "ORCA_HOME=$ORCA_HOME in .env — run phase 1 first"
  [ -d "$NEW_ORCA" ] && [ ! -L "$NEW_ORCA" ] || die "$NEW_ORCA missing — run phase 1 first"

  info "1. Stop Orca"
  systemctl stop orca 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -u "$HERMES_UID" -f '/opt/orca/' >/dev/null || break; sleep 2; done
  pgrep -u "$HERMES_UID" -f '/opt/orca/' >/dev/null && die "Orca processes still running after 60 s — not rewriting its state (systemctl start orca to undo)"

  info "2. Rewrite absolute paths in Orca's state and the SSH user's CLI state"
  local f files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$NEW_ORCA/.config/orca" -maxdepth 3 -type f -name '*.json' -print0 2>/dev/null)
  files+=("$NEW_ORCA/.claude.json" "$NEW_ORCA/.gitconfig" "$NEW_ORCA/.codex/config.toml" "$NEW_ORCA/.codex/hooks.json"
          "$OP_HOME/.claude.json" "$OP_HOME/.gitconfig" "$OP_HOME/.codex/config.toml")
  rewrite_paths "${files[@]}"
  rename_claude_projects "$NEW_ORCA"
  rename_claude_projects "$OP_HOME"
  # Orca worktrees in the shared workspace (visible to the agent and herdr at the same path).
  install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$HERMES_WORKSPACE_DIR/worktrees/orca"
  python3 - "$NEW_ORCA/.config/orca/profiles" "$HERMES_WORKSPACE_DIR/worktrees/orca" <<'PY'
import json, os, sys, glob
for p in glob.glob(os.path.join(sys.argv[1], "*", "orca-data.json")):
    with open(p) as f: d = json.load(f)
    s = d.setdefault("settings", {})
    if s.get("workspaceDir") != sys.argv[2]:
        s["workspaceDir"] = sys.argv[2]
        st = os.stat(p); tmp = p + ".srv-tmp"
        with open(tmp, "w") as f: json.dump(d, f)
        os.chown(tmp, st.st_uid, st.st_gid); os.chmod(tmp, st.st_mode & 0o7777); os.replace(tmp, p)
        print("    workspaceDir →", sys.argv[2], "in", p)
PY

  info "3. Drop the compat symlinks"
  local l
  for l in "${COMPAT_LINKS[@]}"; do
    if [ -L "$l" ]; then rm -f "$l"; echo "    removed $l"; fi
  done

  info "4. Start Orca (HOME=$NEW_ORCA, cwd $HERMES_WORKSPACE_DIR)"
  "$STACK_DIR/orca.sh" write-service
  systemctl start orca
  for _ in $(seq 1 24); do curl -sS -o /dev/null "http://127.0.0.1:${ORCA_PORT:-6768}/" 2>/dev/null && break; sleep 5; done
  systemctl is-active -q orca || { journalctl -u orca -n 30 --no-pager -o cat; die "orca did not start"; }
  info "Orca is back — paired devices keep their tokens. Phase 2 done."
}

case "${1:-}" in
  ""|run)    phase1 ;;
  --dry-run) DRY=1; phase1 ;;
  finalize)  finalize "${2:-}" ;;
  *) die "usage: $0 [--dry-run] | finalize" ;;
esac
