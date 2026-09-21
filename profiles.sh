#!/usr/bin/env bash
# Hermes agent profiles as code. Every directory under profiles/ is a Hermes *profile
# distribution* (`hermes profile install` / `hermes profile update`): the profile's SOUL.md,
# config.yaml, profile.yaml (the description the kanban orchestrator routes on), the skills it
# runs with — hub-installed and local ones alike, vendored so a fresh VPS needs neither the
# skills.sh registry nor GitHub — and the hub lock (skills/.hub/lock.json) that keeps
# `hermes skills check|update` aware of where each vendored skill came from.
#
# Two stack-side extras Hermes distributions do not cover, both optional per profile:
#   plugins.txt   one `hermes plugins install …` argument line per plugin (comments allowed)
#   setup.sh      run inside the container as the runtime user after install/update
#                 (PROFILE, PROFILE_DIR=/opt/data/profiles/<name>, DIST_DIR=/opt/data/distributions/<name>)
#
#   sudo ./profiles.sh install [name…]     # create missing profiles, update existing ones (default: all)
#   sudo ./profiles.sh export  [name…]     # live profile → profiles/<name>/ (review with git diff, then commit)
#   sudo ./profiles.sh status              # repo vs live: version, skills, plugins
#   sudo ./profiles.sh diff    [name…]     # files that export would change
#
# install options: --force-config   overwrite a live config.yaml with the repo one (default: preserved)
#                  --no-restart     do not restart the gateway afterwards (new profiles need it)
#
# Never touched: memories, sessions, auth.json, .env (only a missing API_SERVER_KEY is generated),
# skills/plugins you installed by hand that the repo does not ship.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"

PROFILES_DIR="$STACK_DIR/profiles"
LIVE_PROFILES="$HERMES_DATA_DIR/profiles"
DIST_HOST="$HERMES_DATA_DIR/distributions"     # staging, container side: /opt/data/distributions
DIST_CTR=/opt/data/distributions
# Bundled skills Hermes seeds itself (tools/skills_sync.py, ESSENTIAL_SKILLS: hermes-agent, also
# mirrored under autonomous-ai-agents/ with the category DESCRIPTION.md) — never vendored. Other
# bundled skills copied from the image (obsidian, claude-code…) are vendored like any local skill.
SKILL_EXCLUDES=(--exclude '/hermes-agent/' --exclude '/autonomous-ai-agents/hermes-agent/' --exclude '/autonomous-ai-agents/DESCRIPTION.md'
  --exclude '/.bundled_manifest' --exclude '/.usage.json' --exclude '/.usage.json.lock'
  --exclude '/.curator_state' --exclude '/.curator_ledger.jsonl' --exclude '/.locks/'
  --exclude '__pycache__/' --exclude '.git/' --exclude 'node_modules/' --exclude '.DS_Store'
  --include '/.hub/' --include '/.hub/lock.json' --include '/.hub/taps.json' --exclude '/.hub/*')

FORCE_CONFIG=0; NO_RESTART=0
cmd="${1:-install}"; [ $# -gt 0 ] && shift
names=()
for a in "$@"; do
  case "$a" in
    --force-config) FORCE_CONFIG=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --*) die "unknown option $a" ;;
    *) names+=("$a") ;;
  esac
done
if [ "${#names[@]}" -eq 0 ]; then
  for d in "$PROFILES_DIR"/*/; do [ -f "$d/distribution.yaml" ] && names+=("$(basename "$d")"); done
fi
[ "${#names[@]}" -gt 0 ] || die "no profile distribution found under $PROFILES_DIR (a directory with distribution.yaml)"

agent_running() { [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)" = true ]; }
need_agent() { agent_running || die "hermes-agent is not running. Run ./install.sh or: docker compose up -d"; }
repo_owner() { stat -c '%u:%g' "$STACK_DIR"; }
# hermes <args> inside the container, as the runtime user, pinned to the default profile's
# HOME so `gh auth token` (plugin installs from GitHub) and the hub caches are found.
hx() { agent_run hermes "$@"; }
hx_quiet() { agent_run hermes "$@" >/dev/null 2>&1; }

# ── install ───────────────────────────────────────────────────────────────

# stage <name> — copy profiles/<name>/ to the data dir where the container can read it.
# skills/.hub is left out (merged separately: the live dir also holds caches and the audit log).
stage() {
  local name="$1" src dst; src="$PROFILES_DIR/$name"; dst="$DIST_HOST/$name"
  no_symlink "$HERMES_DATA_DIR" "$DIST_HOST" "$dst"
  mkdir -p "$DIST_HOST"; chmod 700 "$DIST_HOST"
  rsync -a --delete --exclude '/skills/.hub/' --exclude '__pycache__/' --exclude '.git/' \
    --chown "$HERMES_UID:$HERMES_GID" "$src/" "$dst/"
  chown "$HERMES_UID:$HERMES_GID" "$DIST_HOST"
}

# merge_hub_lock <name> — repo lock entries win, entries for skills only installed live survive.
merge_hub_lock() {
  local name="$1"
  [ -f "$PROFILES_DIR/$name/skills/.hub/lock.json" ] || return 0
  agent_run python3 - "$name" <<'PY'
import json, os, sys
name = sys.argv[1]
hub = f"/opt/data/profiles/{name}/skills/.hub"
repo = f"/opt/data/distributions/{name}/.hub-lock"
os.makedirs(hub, exist_ok=True)
def load(p):
    try:
        with open(p, encoding="utf-8") as f: return json.load(f)
    except FileNotFoundError: return {"version": 1, "installed": {}}
shipped = load(repo + "/lock.json"); live = load(hub + "/lock.json")
live.setdefault("installed", {}).update(shipped.get("installed", {}))
live["version"] = shipped.get("version", live.get("version", 1))
import shutil
tmp = hub + "/lock.json.tmp"
if live == shipped:   # nothing live-only: keep the repo file byte for byte (clean `profiles.sh diff`)
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

# seed_essentials <name> — the bundled skills Hermes always expects (hermes-agent); fresh
# distributions never get them otherwise (profile create / hermes update do this).
seed_essentials() {
  agent_run env PYTHONPATH=/opt/hermes HERMES_HOME="/opt/data/profiles/$1" python3 -c \
    'from tools.skills_sync import sync_skills; r = sync_skills(quiet=True); r = r or {}; n = lambda v: v if isinstance(v, int) else len(v or []); print("  essentials: %d copied, %d updated, %d up to date" % (n(r.get("copied")), n(r.get("updated")), n(r.get("skipped"))))' \
    2>/dev/null || warn "$1: essential-skill seeding failed (hermes update will do it)"
}

# ensure_env <name> — the profile's .env: mode 600, owned by the runtime user, with the
# API_SERVER_KEY the multiplexing gateway requires for /p/<name>/v1 (16+ chars).
ensure_env() {
  local name="$1" envf key; envf="$LIVE_PROFILES/$name/.env"
  no_symlink "$LIVE_PROFILES" "$LIVE_PROFILES/$name" "$envf"
  if [ ! -f "$envf" ]; then
    printf '# Per-profile secrets for this Hermes profile.\n# API keys and tokens set here override the shell environment.\n# Behavioral settings belong in config.yaml, not here.\n' > "$envf"
  fi
  key="$(grep -E '^API_SERVER_KEY=' "$envf" | head -n1 | cut -d= -f2- || true)"
  [ "${#key}" -ge 16 ] || { set_env API_SERVER_KEY "$(openssl rand -hex 32)" "$envf"; info "  API_SERVER_KEY generated"; }
  chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
}

# report_env <name> — required env_requires entries (distribution.yaml) missing from the
# profile .env AND the root .env. Bitwarden-supplied secrets are declared optional there.
report_env() {
  local name="$1" missing
  missing="$(agent_run python3 - "$name" <<'PY'
import re, sys, yaml
name = sys.argv[1]
m = yaml.safe_load(open(f"/opt/data/profiles/{name}/distribution.yaml", encoding="utf-8")) or {}
def keys(p):
    try: return {l.split("=", 1)[0].strip() for l in open(p, encoding="utf-8") if "=" in l and not l.lstrip().startswith("#")}
    except FileNotFoundError: return set()
have = keys(f"/opt/data/profiles/{name}/.env") | keys("/opt/data/.env")
print(" ".join(e["name"] for e in m.get("env_requires") or [] if e.get("required", True) and e["name"] not in have))
PY
)"
  [ -z "$missing" ] || warn "$name: required keys not set ($LIVE_PROFILES/$name/.env.EXAMPLE describes them): $missing → add them to $LIVE_PROFILES/$name/.env"
}

# install_plugins <name> — plugins.txt lines are `hermes plugins install` arguments.
install_plugins() {
  local name="$1" f line args plug; f="$PROFILES_DIR/$name/plugins.txt"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(echo "$line" | xargs 2>/dev/null || true)"
    [ -n "$line" ] || continue
    read -r -a args <<<"$line"
    plug="$(basename "${args[0]%.git}")"
    if hx_quiet -p "$name" plugins show "$plug"; then
      info "  plugin $plug: already installed"
    else
      info "  plugin $plug: hermes plugins install ${args[*]}"
      hx -p "$name" plugins install "${args[@]}" || die "$name: plugin install failed: ${args[*]}"
    fi
  done < "$f"
}

run_setup() {
  local name="$1"
  [ -f "$PROFILES_DIR/$name/setup.sh" ] || return 0
  info "  setup.sh"
  agent_run env PROFILE="$name" PROFILE_DIR="/opt/data/profiles/$name" DIST_DIR="$DIST_CTR/$name" \
    bash "$DIST_CTR/$name/setup.sh" || die "$name: setup.sh failed"
}

install_profile() {
  local name="$1" live mode; live="$LIVE_PROFILES/$name"
  [ -f "$PROFILES_DIR/$name/distribution.yaml" ] || die "profiles/$name/distribution.yaml missing"
  no_symlink "$LIVE_PROFILES" "$live"
  stage "$name"
  # Repo lock next to the payload (skills/.hub is not part of the distribution copy).
  if [ -d "$PROFILES_DIR/$name/skills/.hub" ]; then
    rsync -a --delete --chown "$HERMES_UID:$HERMES_GID" "$PROFILES_DIR/$name/skills/.hub/" "$DIST_HOST/$name/.hub-lock/"
  fi
  if [ -f "$live/distribution.yaml" ]; then
    mode=update
    local opts=(-y); [ "$FORCE_CONFIG" = 1 ] && opts+=(--force-config)
    info "$name: hermes profile update (config.yaml $([ "$FORCE_CONFIG" = 1 ] && echo overwritten || echo preserved))"
    # The recorded source is this staging dir; re-point it if the data dir moved.
    hx -p default profile update "$name" "${opts[@]}" | sed 's/^/  /'
  elif [ -d "$live" ]; then
    mode=adopt
    warn "$name: exists but was not installed from profiles/ — adopting it (config.yaml, SOUL.md and the shipped skills are replaced by the repo copies; memories, sessions, .env, other skills untouched)"
    hx -p default profile install "$DIST_CTR/$name" --name "$name" --force -y | sed 's/^/  /'
  else
    mode=create
    info "$name: hermes profile install (new profile)"
    hx -p default profile install "$DIST_CTR/$name" --name "$name" -y | sed 's/^/  /'
  fi
  merge_hub_lock "$name"
  seed_essentials "$name"
  ensure_env "$name"
  report_env "$name"
  install_plugins "$name"
  run_setup "$name"
  [ "$mode" = update ] || NEEDS_RESTART=1
  # Everything the distribution wrote belongs to the runtime user (we run as root).
  chown -R "$HERMES_UID:$HERMES_GID" "$live"
}

do_install() {
  need_agent
  command -v rsync >/dev/null 2>&1 || die "rsync is required (apt install rsync)"
  [ "${UPDATE_LOCKED:-}" = 1 ] || lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
  NEEDS_RESTART=0
  for n in "${names[@]}"; do install_profile "$n"; done
  if [ "$NO_RESTART" = 1 ]; then
    warn "gateway not restarted: new profiles appear after: docker exec hermes-agent hermes -p default gateway restart"
  elif [ "$NEEDS_RESTART" = 1 ]; then
    info "Restarting the multiplexing gateway so it serves the new profiles…"
    hx -p default gateway restart >/dev/null || warn "gateway restart failed — docker compose logs hermes-agent"
    wait_healthy hermes-agent 180 || warn "hermes-agent not healthy after 3 min"
  else
    info "Profiles updated in place. Open a new session in each: running sessions keep their skill snapshot."
  fi
  do_status
}

# ── export ────────────────────────────────────────────────────────────────

export_profile() {
  local name="$1" live dst f; live="$LIVE_PROFILES/$name"; dst="$PROFILES_DIR/$name"
  [ -d "$live" ] || die "no live profile '$name' under $LIVE_PROFILES (hermes profile list)"
  no_symlink "$LIVE_PROFILES" "$live" "$live/skills" "$live/cron"
  mkdir -p "$dst"
  for f in SOUL.md config.yaml profile.yaml .no-bundled-skills mcp.json; do
    no_symlink "$live/$f"
    if [ -f "$live/$f" ]; then install -m 644 "$live/$f" "$dst/$f"; fi
  done
  mkdir -p "$dst/skills"
  rsync -rlt --safe-links --delete -m -O "${SKILL_EXCLUDES[@]}" "$live/skills/" "$dst/skills/"
  # Cron job definitions only (executions.db, output/, ticker files are runtime state).
  if compgen -G "$live/cron/*.json" >/dev/null || compgen -G "$live/cron/*.yaml" >/dev/null; then
    mkdir -p "$dst/cron"; rsync -rlt --safe-links --delete --include '*.json' --include '*.yaml' --exclude '*' "$live/cron/" "$dst/cron/"
  fi
  if [ ! -f "$dst/distribution.yaml" ]; then
    local desc; desc="$(agent_run python3 -c 'import sys,yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get("description",""))' "/opt/data/profiles/$name/profile.yaml" 2>/dev/null || true)"
    cat > "$dst/distribution.yaml" <<YAML
name: $name
version: $(date +%Y.%m.%d)
description: ${desc:-Hermes profile $name}
hermes_requires: ">=0.21.3"
# Paths hermes profile install/update replaces with the repo copies (config.yaml only on a
# fresh install or --force-config). Everything else in the live profile is left alone.
distribution_owned: [SOUL.md, config.yaml, profile.yaml, .no-bundled-skills, mcp.json, skills, cron, distribution.yaml]
env_requires:
  - name: API_SERVER_KEY
    description: Gateway API key for /p/$name/v1 (profiles.sh generates one when missing)
    required: false
YAML
    info "$name: distribution.yaml created — edit description / env_requires"
  fi
  # Keys in the live .env that the manifest does not describe.
  local live_keys man_keys k extra=()
  live_keys="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$live/.env" 2>/dev/null | cut -d= -f1 || true)"
  man_keys="$(grep -E '^\s*-\s*name:' "$dst/distribution.yaml" | sed -E 's/.*name:\s*//' || true)"
  for k in $live_keys; do grep -qx "$k" <<<"$man_keys" || extra+=("$k"); done
  [ "${#extra[@]}" -eq 0 ] || warn "$name: keys in the live .env not declared in distribution.yaml env_requires: ${extra[*]}"
  # Plugins the live profile has vs plugins.txt.
  local plugs
  plugs="$(ls "$live/plugins" 2>/dev/null | xargs 2>/dev/null || true)"
  [ -z "$plugs" ] || [ -f "$dst/plugins.txt" ] || warn "$name: live plugins ($plugs) — declare them in profiles/$name/plugins.txt"
  chown -R "$(repo_owner)" "$dst"
  info "$name: exported → profiles/$name/ ($(find "$dst/skills" -name SKILL.md | wc -l) skills). Review: git -C $STACK_DIR diff --stat profiles/$name"
}

do_export() {
  need_agent
  for n in "${names[@]}"; do export_profile "$n"; done
}

do_diff() {
  local name live dst
  for name in "${names[@]}"; do
    live="$LIVE_PROFILES/$name"; dst="$PROFILES_DIR/$name"
    [ -d "$live" ] || { warn "$name: not installed"; continue; }
    echo "== $name"
    for f in SOUL.md config.yaml profile.yaml; do
      [ -f "$live/$f" ] && [ -f "$dst/$f" ] && { diff -q "$live/$f" "$dst/$f" >/dev/null || echo "  M $f"; }
      [ -f "$live/$f" ] && [ ! -f "$dst/$f" ] && echo "  + $f (live only)"
    done
    rsync -rlt -n -i -m -O -c --delete "${SKILL_EXCLUDES[@]}" "$live/skills/" "$dst/skills/" | sed 's/^/  skills: /'
  done
}

# ── status ────────────────────────────────────────────────────────────────

do_status() {
  local name live rv lv sk pl
  printf '\n  %-11s %-12s %-12s %-8s %s\n' PROFILE REPO LIVE SKILLS PLUGINS
  for name in "${names[@]}"; do
    live="$LIVE_PROFILES/$name"
    [ -f "$PROFILES_DIR/$name/distribution.yaml" ] || { warn "$name: no profiles/$name/distribution.yaml"; continue; }
    rv="$(sed -n 's/^version:[[:space:]]*//p' "$PROFILES_DIR/$name/distribution.yaml" | tr -d '"' | head -n1)"
    if [ -d "$live" ]; then
      lv="$(sed -n 's/^version:[[:space:]]*//p' "$live/distribution.yaml" 2>/dev/null | tr -d "'\"" | head -n1 || true)"
      sk="$(find "$live/skills" -name SKILL.md -not -path '*/.hub/*' 2>/dev/null | wc -l)"
      pl="$(ls "$live/plugins" 2>/dev/null | xargs 2>/dev/null || true)"
      printf '  %-11s %-12s %-12s %-8s %s\n' "$name" "$rv" "${lv:-not a dist}" "$sk" "${pl:--}"
    else
      printf '  %-11s %-12s %-12s %-8s %s\n' "$name" "$rv" "absent" - -
    fi
  done
  echo
}

case "$cmd" in
  install|update) do_install ;;
  export) do_export ;;
  status) do_status ;;
  diff) do_diff ;;
  -h|--help|help) sed -n '2,23p' "$0" ;;
  *) die "usage: $0 {install|export|status|diff} [name…] [--force-config] [--no-restart]" ;;
esac
