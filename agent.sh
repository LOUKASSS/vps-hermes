#!/usr/bin/env bash
# Default Hermes agent as code. Replaces profiles.sh at cut-over (install.sh wiring is PR8).
# Seeds /opt/data (HERMES_HOME) from this repo: union skills, SOUL.md, .no-bundled-skills,
# health MCP sources, and (when missing) USER.md / config.yaml.
#
#   sudo ./agent.sh sync-files                         # host only, agent stopped OK
#   sudo ./agent.sh sync [--force-config] [--force-soul]
#   sudo ./agent.sh diff | status
#
# --force-soul is a no-op: SOUL.md is always distribution-owned and overwritten.
# --force-config copies agent/config.yaml only when live config still looks like the
# upstream Hermes seed (no mcp_servers:, multiplex_profiles absent/true, no project_id:,
# no orchestrator_profile: chief, empty plugins.enabled). A customized live default
# must never match.
#
# Guard: if $HERMES_DATA_DIR/profiles/chief exists and CUTOVER is unset, sync and
# sync-files die ("wait for migrate-single-agent.sh (CUTOVER=1)"). diff/status stay
# readable. Migrate / install.sh cut-over export CUTOVER=1.
#
# Callers that already hold UPDATE_LOCK (migrate-single-agent.sh, install.sh) must
# export UPDATE_LOCKED=1 so this script does not wait on its own flock:
#   sudo UPDATE_LOCKED=1 CUTOVER=1 ./agent.sh sync
# Bare invocations still take the lock. Do not skip it unconditionally.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"

# Bundled skills Hermes seeds itself (tools/skills_sync.py, ESSENTIAL_SKILLS: hermes-agent, also
# mirrored under autonomous-ai-agents/ with the category DESCRIPTION.md) — never vendored. Other
# bundled skills copied from the image (obsidian, claude-code…) are vendored like any local skill.
SKILL_EXCLUDES=(--exclude '/hermes-agent/' --exclude '/autonomous-ai-agents/hermes-agent/' --exclude '/autonomous-ai-agents/DESCRIPTION.md'
  --exclude '/.bundled_manifest' --exclude '/.usage.json' --exclude '/.usage.json.lock'
  --exclude '/.curator_state' --exclude '/.curator_ledger.jsonl' --exclude '/.locks/'
  --exclude '__pycache__/' --exclude '.git/' --exclude 'node_modules/' --exclude '.DS_Store'
  --include '/.hub/' --include '/.hub/lock.json' --include '/.hub/taps.json' --exclude '/.hub/*')

FORCE_CONFIG=0
FORCE_SOUL=0
cmd="${1:-}"
[ $# -gt 0 ] && shift
for a in "$@"; do
  case "$a" in
    --force-config) FORCE_CONFIG=1 ;;
    --force-soul) FORCE_SOUL=1 ;;
    --*) die "unknown option $a" ;;
    *) die "unexpected argument $a" ;;
  esac
done

agent_running() { [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)" = true ]; }
need_agent() { agent_running || die "hermes-agent is not running. Run ./install.sh or: docker compose up -d"; }
hx() { agent_run hermes "$@"; }
hx_quiet() { agent_run hermes "$@" >/dev/null 2>&1; }

require_cutover() {
  if [ -d "$HERMES_DATA_DIR/profiles/chief" ] && [ -z "${CUTOVER:-}" ]; then
    die "wait for migrate-single-agent.sh (CUTOVER=1)"
  fi
}

require_rsync() { command -v rsync >/dev/null 2>&1 || die "rsync is required (apt install rsync)"; }

# Live config still looks like the image's first-boot seed (not this repo's, not a customized live).
# Live default currently has no mcp_servers and multiplex_profiles: true — those two checks
# alone would treat it as a seed and --force-config would drop Bitwarden project_id.
config_is_upstream_seed() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE '^mcp_servers:' "$f" && return 1
  grep -qE '^[[:space:]]*multiplex_profiles:[[:space:]]*false' "$f" && return 1
  grep -qE '^[[:space:]]*project_id:' "$f" && return 1
  grep -qE '^[[:space:]]*orchestrator_profile:[[:space:]]*chief[[:space:]]*$' "$f" && return 1
  # Non-empty plugins.enabled (`- item` or `enabled: [foo]`), not `enabled: []`.
  awk '
    /^plugins:[[:space:]]*$/ { p=1; next }
    p && /^[^[:space:]#]/ { p=0 }
    p && /^[[:space:]]*enabled:[[:space:]]*$/ { e=1; next }
    p && /^[[:space:]]*enabled:[[:space:]]*\[\][[:space:]]*$/ { next }
    p && /^[[:space:]]*enabled:[[:space:]]*\[.+\]/ { found=1; exit }
    e && /^[[:space:]]*disabled:/ { e=0 }
    e && /^[[:space:]]+-[[:space:]]+/ { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$f" && return 1
  return 0
}

sync_config() {
  local src="$STACK_DIR/agent/config.yaml" dst="$HERMES_DATA_DIR/config.yaml"
  [ -f "$src" ] || return 0
  no_symlink "$dst"
  if [ ! -f "$dst" ]; then
    info "  seeding config.yaml (absent)"
    install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$src" "$dst"
    return 0
  fi
  [ "$FORCE_CONFIG" = 1 ] || return 0
  if config_is_upstream_seed "$dst"; then
    info "  --force-config: replacing upstream seed config.yaml"
    install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$src" "$dst"
  else
    warn "  --force-config ignored: live config.yaml is not an upstream seed (mcp_servers, multiplex=false, project_id, orchestrator chief, or plugins.enabled)"
  fi
}

# ── sync-files (host only) ─────────────────────────────────────────────

do_sync_files() {
  require_cutover
  require_rsync
  [ "${UPDATE_LOCKED:-}" = 1 ] || lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
  no_symlink "$HERMES_DATA_DIR"
  [ -d "$STACK_DIR/skills" ] || die "missing $STACK_DIR/skills"
  [ -f "$STACK_DIR/agent/SOUL.md" ] || die "missing $STACK_DIR/agent/SOUL.md"

  info "sync-files → $HERMES_DATA_DIR"
  mkdir -p "$HERMES_DATA_DIR/skills" "$HERMES_DATA_DIR/mcp-src" "$HERMES_DATA_DIR/.hub-lock"
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR/skills" "$HERMES_DATA_DIR/mcp-src" "$HERMES_DATA_DIR/.hub-lock"

  # Live .hub caches/lock stay; lock is merged later from .hub-lock (same as profiles.sh stage).
  rsync -a --delete --exclude '/.hub/' "${SKILL_EXCLUDES[@]}" \
    --chown "$HERMES_UID:$HERMES_GID" \
    "$STACK_DIR/skills/" "$HERMES_DATA_DIR/skills/"
  info "  skills rsync --delete ($(find "$STACK_DIR/skills" -name SKILL.md | wc -l) SKILL.md in repo)"

  # SOUL is distribution-owned: always overwritten. --force-soul is a documented no-op.
  : "$FORCE_SOUL"
  no_symlink "$HERMES_DATA_DIR/SOUL.md"
  install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$STACK_DIR/agent/SOUL.md" "$HERMES_DATA_DIR/SOUL.md"
  info "  SOUL.md"

  no_symlink "$HERMES_DATA_DIR/.no-bundled-skills"
  install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$STACK_DIR/agent/.no-bundled-skills" "$HERMES_DATA_DIR/.no-bundled-skills"
  info "  .no-bundled-skills"

  no_symlink "$HERMES_DATA_DIR/USER.md"
  if [ ! -f "$HERMES_DATA_DIR/USER.md" ]; then
    install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$STACK_DIR/agent/USER.md" "$HERMES_DATA_DIR/USER.md"
    info "  USER.md seeded (was absent)"
  else
    info "  USER.md left in place"
  fi

  if [ -d "$STACK_DIR/mcp" ]; then
    rsync -a --delete \
      --exclude 'node_modules/' --exclude 'dist/' --exclude '.built-from' --exclude 'setup.sh' \
      --chown "$HERMES_UID:$HERMES_GID" \
      "$STACK_DIR/mcp/" "$HERMES_DATA_DIR/mcp-src/"
    info "  mcp-src (sources + lockfiles, no node_modules/dist)"
  else
    warn "  repo mcp/ missing — skip mcp-src rsync"
  fi
  # Repo is not mounted in the container; profiles.sh did the same via distributions/<name>/setup.sh.
  install -m 755 -o "$HERMES_UID" -g "$HERMES_GID" "$STACK_DIR/agent/setup.sh" "$HERMES_DATA_DIR/mcp-src/setup.sh"
  info "  mcp-src/setup.sh"

  if [ -d "$STACK_DIR/skills/.hub" ]; then
    rsync -a --delete --chown "$HERMES_UID:$HERMES_GID" \
      "$STACK_DIR/skills/.hub/" "$HERMES_DATA_DIR/.hub-lock/"
  fi

  sync_config
}

# ── sync (sync-files + container steps) ────────────────────────────────

# Repo lock entries win; entries for skills only installed live survive.
merge_hub_lock() {
  [ -f "$STACK_DIR/skills/.hub/lock.json" ] || return 0
  agent_run python3 - <<'PY'
import json, os, shutil
hub = "/opt/data/skills/.hub"
repo = "/opt/data/.hub-lock"
os.makedirs(hub, exist_ok=True)
def load(p):
    try:
        with open(p, encoding="utf-8") as f: return json.load(f)
    except FileNotFoundError: return {"version": 1, "installed": {}}
shipped = load(repo + "/lock.json"); live = load(hub + "/lock.json")
live.setdefault("installed", {}).update(shipped.get("installed", {}))
live["version"] = shipped.get("version", live.get("version", 1))
tmp = hub + "/lock.json.tmp"
if live == shipped:
    shutil.copy2(repo + "/lock.json", tmp)
else:
    with open(tmp, "w", encoding="utf-8") as f: json.dump(live, f, indent=2); f.write("\n")
os.replace(tmp, hub + "/lock.json")
if not os.path.exists(hub + "/taps.json"):
    try: shutil.copy2(repo + "/taps.json", hub + "/taps.json")
    except OSError:
        with open(hub + "/taps.json", "w") as f: f.write('{"taps": []}\n')
print(f"  hub lock: {len(shipped.get('installed', {}))} shipped, {len(live['installed'])} tracked")
PY
}

seed_essentials() {
  agent_run env PYTHONPATH=/opt/hermes HERMES_HOME=/opt/data python3 -c \
    'from tools.skills_sync import sync_skills; r = sync_skills(quiet=True); r = r or {}; n = lambda v: v if isinstance(v, int) else len(v or []); print("  essentials: %d copied, %d updated, %d up to date" % (n(r.get("copied")), n(r.get("updated")), n(r.get("skipped"))))' \
    2>/dev/null || warn "essential-skill seeding failed (hermes update will do it)"
}

assert_no_cli_skills() {
  local hits
  hits="$(find "$HERMES_DATA_DIR/skills" \( -name claude-code -o -name codex \) -type d ! -path '*/hermes-agent/*' 2>/dev/null || true)"
  [ -z "$hits" ] || die "refusing to leave claude-code/codex under $HERMES_DATA_DIR/skills (image bundled skills). Hits:"$'\n'"$hits"
}

install_plugins() {
  local f line args plug
  f="$STACK_DIR/agent/plugins.txt"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(echo "$line" | xargs 2>/dev/null || true)"
    [ -n "$line" ] || continue
    read -r -a args <<<"$line"
    plug="$(basename "${args[0]%.git}")"
    if hx_quiet plugins show "$plug"; then
      info "  plugin $plug: already installed"
    else
      info "  plugin $plug: hermes plugins install ${args[*]}"
      hx plugins install "${args[@]}" || die "plugin install failed: ${args[*]}"
    fi
  done < "$f"
}

run_setup() {
  info "  setup.sh (MCP build)"
  if agent_run env PROFILE_DIR=/opt/data DIST_DIR=/opt/data/mcp-src bash /opt/data/mcp-src/setup.sh; then
    return 0
  fi
  warn "compose exec failed, falling back to compose run --entrypoint bash"
  compose run --rm --no-deps --entrypoint bash \
    -u "$HERMES_UID:$HERMES_GID" -e HOME=/opt/data/home -w /workspace hermes-agent \
    -lc 'PROFILE_DIR=/opt/data DIST_DIR=/opt/data/mcp-src bash /opt/data/mcp-src/setup.sh' \
    || die "setup.sh failed"
}

do_sync() {
  do_sync_files
  need_agent
  info "merge hub lock"
  merge_hub_lock
  run_setup
  install_plugins
  seed_essentials
  assert_no_cli_skills
  info "Restarting the gateway so it picks up skills/plugins/MCP…"
  hx gateway restart >/dev/null || warn "gateway restart failed — docker compose logs hermes-agent"
  wait_healthy hermes-agent 180 || warn "hermes-agent not healthy after 3 min"
  do_status
}

# ── diff / status (no CUTOVER required) ────────────────────────────────

do_diff() {
  local live="$HERMES_DATA_DIR"
  require_rsync
  echo "== default ($live)"
  if [ ! -d "$live" ]; then
    echo "  live data dir absent"
    return 0
  fi
  for f in SOUL.md USER.md .no-bundled-skills config.yaml; do
    if [ -f "$live/$f" ] && [ -f "$STACK_DIR/agent/$f" ]; then
      diff -q "$live/$f" "$STACK_DIR/agent/$f" >/dev/null || echo "  M $f"
    elif [ -f "$STACK_DIR/agent/$f" ] && [ ! -f "$live/$f" ]; then
      echo "  + $f (repo only)"
    elif [ -f "$live/$f" ] && [ ! -f "$STACK_DIR/agent/$f" ]; then
      echo "  + $f (live only)"
    fi
  done
  if [ -d "$live/skills" ]; then
    rsync -rlt -n -i -m -O -c --delete --exclude '/.hub/' "${SKILL_EXCLUDES[@]}" \
      "$STACK_DIR/skills/" "$live/skills/" | sed 's/^/  skills: /'
  else
    echo "  skills: (live absent)"
  fi
  if [ -d "$STACK_DIR/mcp" ]; then
    rsync -rlt -n -i -c --delete \
      --exclude 'node_modules/' --exclude 'dist/' --exclude '.built-from' --exclude 'setup.sh' \
      "$STACK_DIR/mcp/" "$live/mcp-src/" | sed 's/^/  mcp-src: /'
  fi
  if [ -f "$STACK_DIR/agent/setup.sh" ] && [ -f "$live/mcp-src/setup.sh" ]; then
    diff -q "$STACK_DIR/agent/setup.sh" "$live/mcp-src/setup.sh" >/dev/null || echo "  M mcp-src/setup.sh"
  elif [ -f "$STACK_DIR/agent/setup.sh" ] && [ ! -f "$live/mcp-src/setup.sh" ]; then
    echo "  + mcp-src/setup.sh (repo only)"
  fi
}

do_status() {
  local live="$HERMES_DATA_DIR" sk soul pl stamps chief
  echo
  if [ -f "$live/SOUL.md" ] && [ -f "$STACK_DIR/agent/SOUL.md" ]; then
    if diff -q "$live/SOUL.md" "$STACK_DIR/agent/SOUL.md" >/dev/null; then soul="in sync"
    else soul="differs from repo"; fi
  elif [ -f "$live/SOUL.md" ]; then soul="live only"
  else soul="absent"; fi
  printf '  SOUL.md:              %s\n' "$soul"

  if [ -f "$live/.no-bundled-skills" ]; then
    printf '  .no-bundled-skills:   present\n'
  else
    printf '  .no-bundled-skills:   absent\n'
  fi

  if [ -d "$live/skills" ]; then
    sk="$(find "$live/skills" -name SKILL.md -not -path '*/.hub/*' 2>/dev/null | wc -l)"
  else
    sk=0
  fi
  printf '  skills:               %s SKILL.md\n' "$sk"

  if agent_running; then
    if hx_quiet plugins show superpowers; then pl="superpowers"
    else pl="superpowers not installed"; fi
  else
    pl="(agent not running)"
  fi
  printf '  plugin:               %s\n' "$pl"

  stamps=""
  for d in node renpho-mcp-server; do
    if [ -f "$live/mcp/$d/.built-from" ]; then
      stamps="${stamps:+$stamps, }$d=$(cat "$live/mcp/$d/.built-from")"
    fi
  done
  printf '  MCP .built-from:      %s\n' "${stamps:-missing}"

  if [ -d "$live/profiles/chief" ]; then chief="profiles/chief still present (need CUTOVER=1 to sync)"
  else chief="ok"; fi
  printf '  cutover:              %s\n' "$chief"
  echo
}

case "$cmd" in
  sync-files) do_sync_files ;;
  sync) do_sync ;;
  diff) do_diff ;;
  status) do_status ;;
  -h|--help|help|"") sed -n '2,23p' "$0" ;;
  *) die "usage: $0 {sync-files|sync|diff|status} [--force-config] [--force-soul]" ;;
esac
