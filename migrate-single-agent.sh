#!/usr/bin/env bash
# In-place cut-over from six named Hermes profiles + user `orca` to one default agent
# and uid `hermes`. Spec = design table d'étapes. Does not remove .maintenance.
#
#   touch /srv/hermes/stack/.maintenance    # BEFORE checkout of this compose
#   sudo ./migrate-single-agent.sh          # refuses unless that flag exists
#   sudo ./migrate-single-agent.sh --dry-run
#
# Do not run against a live VPS from a worktree. Child agent.sh:
#   UPDATE_LOCKED=1 CUTOVER=1 ./agent.sh …
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
cd "$STACK_DIR"

DRY=0
case "${1:-}" in
  --dry-run) DRY=1; shift ;;
  -h|--help|help)
    sed -n '2,12p' "$0"
    exit 0
    ;;
  "" ) ;;
  *) die "usage: $0 [--dry-run]" ;;
esac
[ -z "${1:-}" ] || die "usage: $0 [--dry-run]"

[ -f "$STACK_DIR/.maintenance" ] || die "refusing to run: $STACK_DIR/.maintenance is absent. Touch it before checkout of this compose, then re-run."

load_env

PROJECTS_DIR=/srv/hermes/projects
WORKSPACE_OLD=/srv/hermes/workspace
HELIOS_DIR=/srv/hermes/helios
ORCA_HOME="${ORCA_HOME:-/srv/hermes/orca}"
REQUIRED_KEYS=(HEVY_API_KEY YAZIO_USERNAME YAZIO_PASSWORD RENPHO_EMAIL RENPHO_PASSWORD)
OLD_PROFILES=(chief engineer seo researcher health markets)

REPORT=()
note() { REPORT+=("$*"); info "$*"; }
skip() { note "skip: $*"; }
fail() { note "FAIL: $*"; die "$*"; }

if [ "$DRY" = 0 ]; then
  lock_update -w 300 || die "heal.sh or update.sh is busy with the stack (lock $UPDATE_LOCK) — try again"
else
  info "dry-run: not taking UPDATE_LOCK, not writing"
fi

# Load write_service / unit_user from orca.sh without running its CLI dispatcher.
# Drop orca.sh's EXIT trap (rm -rf "$TMP_DIR" with TMP_DIR empty would fail the migrate).
load_orca_fns() {
  local tmp
  tmp="$(mktemp)"
  sed '/^case "\${1:-}" in/,$d' "$STACK_DIR/orca.sh" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"
  rm -f "$tmp"
  trap - EXIT
}

agent_running() { [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)" = true ]; }

agent_sh() {
  UPDATE_LOCKED=1 CUTOVER=1 "$STACK_DIR/agent.sh" "$@"
}

env_has_key() {
  local f="$1" k="$2"
  [ -f "$f" ] || return 1
  grep -qE "^${k}=" "$f"
}

all_mcp_keys_present() {
  local k
  for k in "${REQUIRED_KEYS[@]}"; do
    env_has_key "$HERMES_DATA_DIR/.env" "$k" || return 1
  done
  return 0
}

# ── 0. maintenance (already checked) + agent running ────────────────────
step0() {
  info "0. .maintenance present; agent must be running unless MCP keys already in data/.env"
  if all_mcp_keys_present; then
    if agent_running; then
      note "0. ok (.maintenance, MCP keys already in data/.env, agent up)"
    else
      skip "0 agent running (MCP keys already in data/.env — resume without health profile)"
    fi
    return 0
  fi
  if ! agent_running; then
    fail "start hermes-agent first (secrets 0b need the health profile on a running agent)"
  fi
  note "0. ok (.maintenance, hermes-agent up)"
}

# ── 0b. secrets BEFORE compose stop ─────────────────────────────────────
step0b() {
  info "0b. MCP secrets into data/.env (names only; fail-closed before stop)"
  if all_mcp_keys_present; then
    skip "0b HEVY_API_KEY YAZIO_* RENPHO_* already in data/.env"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "0b dry-run: would fetch Bitwarden EU health project and append missing MCP keys to data/.env"
    return 0
  fi
  [ -d "$HERMES_DATA_DIR/profiles/health" ] \
    || fail "0b: $HERMES_DATA_DIR/profiles/health missing and MCP keys are not in data/.env"
  # Exact fetch_bitwarden_secrets block (EU server_url, 5 MCP keys). Values never logged.
  agent_run python3 - <<'PY'
from pathlib import Path
import os, re, sys, yaml
from agent.secret_sources.bitwarden import fetch_bitwarden_secrets

health = Path("/opt/data/profiles/health")
root_env = Path("/opt/data/.env")
cfg = yaml.safe_load((health / "config.yaml").read_text(encoding="utf-8")) or {}
bw = (cfg.get("secrets") or {}).get("bitwarden") or {}
project_id = bw["project_id"]          # live: c32ad2e8-7cae-492d-9c6a-b4ca012dae35
server_url = bw.get("server_url") or "https://vault.bitwarden.eu"
token = ""
for line in (health / ".env").read_text(encoding="utf-8").splitlines():
    if line.startswith("BWS_ACCESS_TOKEN=") and not line.lstrip().startswith("#"):
        token = line.split("=", 1)[1].strip().strip("'\"")
        break
if not token:
    sys.exit("health .env: BWS_ACCESS_TOKEN missing")

secrets, warnings = fetch_bitwarden_secrets(
    access_token=token,
    project_id=project_id,
    server_url=server_url,
    home_path=health,
    use_cache=False,
)
required = (
    "HEVY_API_KEY",
    "YAZIO_USERNAME",
    "YAZIO_PASSWORD",
    "RENPHO_EMAIL",
    "RENPHO_PASSWORD",
)
missing = [k for k in required if not secrets.get(k)]
if missing:
    sys.exit(f"BWS health project missing {missing}")  # fail BEFORE compose stop

have = set()
if root_env.is_file():
    data = root_env.read_text(encoding="utf-8")
    for line in data.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            have.add(line.split("=", 1)[0].strip())
    if data and not data.endswith("\n"):
        with root_env.open("a", encoding="utf-8") as fh:
            fh.write("\n")
added = []
with root_env.open("a", encoding="utf-8") as fh:
    for k in required:
        if k in have:
            continue
        fh.write(f"{k}={secrets[k]}\n")
        added.append(k)
os.chmod(root_env, 0o600)
print("bws keys present:", " ".join(required))
print("appended:", " ".join(added) or "(none)")
for w in warnings:
    print("warn:", w, file=sys.stderr)
PY
  all_mcp_keys_present || fail "0b: MCP keys still missing from data/.env after BWS fetch"
  note "0b. ok (MCP key names in data/.env, mode 600)"
}

# ── 1. stop agent ───────────────────────────────────────────────────────
step1() {
  info "1. compose stop hermes-agent"
  if ! agent_running; then
    skip "1 hermes-agent already stopped"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "1 dry-run: would compose stop hermes-agent"
    return 0
  fi
  compose stop hermes-agent
  agent_running && fail "1: hermes-agent still running"
  note "1. ok (hermes-agent stopped)"
}

# ── 2. mv workspace → projects (no flatten, no symlink) ─────────────────
step2() {
  info "2. mv $WORKSPACE_OLD → $PROJECTS_DIR (no flatten, no symlink)"
  if [ -d "$PROJECTS_DIR" ] && [ ! -e "$WORKSPACE_OLD" ]; then
    skip "2 $PROJECTS_DIR exists and $WORKSPACE_OLD is absent"
    HERMES_WORKSPACE_DIR="$PROJECTS_DIR"
    return 0
  fi
  if [ -d "$WORKSPACE_OLD" ] && [ -e "$PROJECTS_DIR" ]; then
    fail "2: both $WORKSPACE_OLD and $PROJECTS_DIR exist — not flattening, not merging, no symlink"
  fi
  if [ ! -d "$WORKSPACE_OLD" ]; then
    fail "2: $WORKSPACE_OLD missing"
  fi
  [ ! -L "$WORKSPACE_OLD" ] || fail "2: $WORKSPACE_OLD is a symlink — refusing"
  if [ "$DRY" = 1 ]; then
    note "2 dry-run: would mv $WORKSPACE_OLD $PROJECTS_DIR"
    return 0
  fi
  mv "$WORKSPACE_OLD" "$PROJECTS_DIR"
  [ ! -e "$WORKSPACE_OLD" ] || fail "2: $WORKSPACE_OLD still present after mv"
  [ -d "$PROJECTS_DIR" ] || fail "2: $PROJECTS_DIR missing after mv"
  if [ ! -d "$PROJECTS_DIR/projects/hermes-agent" ]; then
    warn "2: $PROJECTS_DIR/projects/hermes-agent not present (live clone may live elsewhere; no flatten)"
  fi
  HERMES_WORKSPACE_DIR="$PROJECTS_DIR"
  note "2. ok ($PROJECTS_DIR)"
}

# ── 3. kanban SQL on table tasks (agent stopped) ────────────────────────
step3() {
  info "3. kanban SQL (tasks / task_runs / kanban_notify_subs) → assignee/profile default"
  local db="$HERMES_DATA_DIR/kanban.db"
  if [ ! -f "$db" ]; then
    skip "3 $db absent"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "3 dry-run: would UPDATE tasks/task_runs/kanban_notify_subs old profile names → default"
    return 0
  fi
  no_symlink "$db"
  python3 - "$db" <<'PY'
import sqlite3, sys
db = sys.argv[1]
names = ("chief", "engineer", "seo", "researcher", "health", "markets")
con = sqlite3.connect(db)
cur = con.cursor()

def count(sql):
    try:
        return cur.execute(sql, names).fetchone()[0]
    except sqlite3.OperationalError as e:
        print(f"warn: {e}")
        return 0

n_tasks = count("SELECT COUNT(*) FROM tasks WHERE assignee IN (?,?,?,?,?,?)")
n_runs = count("SELECT COUNT(*) FROM task_runs WHERE profile IN (?,?,?,?,?,?)")
n_subs = count("SELECT COUNT(*) FROM kanban_notify_subs WHERE notifier_profile IN (?,?,?,?,?,?)")
if n_tasks == 0 and n_runs == 0 and n_subs == 0:
    print("skip: assignees already default")
else:
    for sql, n in (
        ("UPDATE tasks SET assignee = 'default' WHERE assignee IN (?,?,?,?,?,?)", n_tasks),
        ("UPDATE task_runs SET profile = 'default' WHERE profile IN (?,?,?,?,?,?)", n_runs),
        ("UPDATE kanban_notify_subs SET notifier_profile = 'default' WHERE notifier_profile IN (?,?,?,?,?,?)", n_subs),
    ):
        try:
            cur.execute(sql, names)
            print(f"updated {cur.rowcount} rows ({n} matched): {sql.split()[1]}")
        except sqlite3.OperationalError as e:
            print(f"warn: {e}")
    con.commit()

print("in-progress tasks:")
try:
    rows = cur.execute(
        "SELECT id, title, assignee, status FROM tasks WHERE status NOT IN ('done','completed')"
    ).fetchall()
    for r in rows:
        print(f"  {r[0]}\t{r[3]}\t{r[2]}\t{r[1]}")
    if not rows:
        print("  (none)")
except sqlite3.OperationalError as e:
    print(f"warn: {e}")
con.close()
PY
  note "3. ok (kanban SQL)"
}

# ── 4. copy sqlite/json → data/private (leave originals) ────────────────
copy_private() {
  local name="$1" rel="$2"
  local dst="$HERMES_DATA_DIR/private/$name"
  if [ -s "$dst" ]; then
    skip "4 $name already in data/private"
    return 0
  fi
  local src
  for src in "$HERMES_DATA_DIR/$rel" "$HERMES_DATA_DIR/archive/$rel"; do
    if [ -f "$src" ]; then
      if [ "$DRY" = 1 ]; then
        note "4 dry-run: would cp -a $src $dst"
        return 0
      fi
      mkdir -p "$HERMES_DATA_DIR/private"
      chown "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR/private"
      cp -a "$src" "$dst"
      [ -s "$dst" ] || fail "4: $dst empty after copy"
      chown "$HERMES_UID:$HERMES_GID" "$dst"
      note "4. copied $name (original left in place)"
      return 0
    fi
  done
  skip "4 $name source absent"
}

step4() {
  info "4. cp -a sqlite/json → data/private/"
  if [ "$DRY" = 0 ]; then
    mkdir -p "$HERMES_DATA_DIR/private"
    chown "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR/private" 2>/dev/null || true
  fi
  copy_private health.sqlite3 profiles/health/data/health.sqlite3
  copy_private markets.sqlite3 profiles/markets/data/markets.sqlite3
  copy_private watch-topics.json profiles/researcher/data/watch-topics.json
}

# ── 5. archive profiles + distributions ─────────────────────────────────
archive_dir() {
  local src="$HERMES_DATA_DIR/$1" dst="$HERMES_DATA_DIR/archive/$1"
  if [ -d "$dst" ]; then
    skip "5 archive/$1 already exists"
    return 0
  fi
  if [ ! -d "$src" ]; then
    skip "5 $1 absent (nothing to archive)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "5 dry-run: would mv $src $dst"
    return 0
  fi
  mkdir -p "$HERMES_DATA_DIR/archive"
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR/archive"
  mv "$src" "$dst"
  [ -d "$dst" ] || fail "5: $dst missing after mv"
  note "5. archived $1"
}

step5() {
  info "5. mv data/profiles + data/distributions → data/archive/"
  archive_dir profiles
  archive_dir distributions
}

# ── 6. rm active_profile ────────────────────────────────────────────────
step6() {
  info "6. rm -f data/active_profile"
  if [ ! -e "$HERMES_DATA_DIR/active_profile" ]; then
    skip "6 active_profile already absent"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "6 dry-run: would rm -f $HERMES_DATA_DIR/active_profile"
    return 0
  fi
  no_symlink "$HERMES_DATA_DIR/active_profile"
  rm -f "$HERMES_DATA_DIR/active_profile"
  [ ! -e "$HERMES_DATA_DIR/active_profile" ] || fail "6: active_profile still present"
  note "6. ok (active_profile removed)"
}

# ── 7. patch config.yaml allow-list ─────────────────────────────────────
config_already_patched() {
  local f="$HERMES_DATA_DIR/config.yaml"
  [ -f "$f" ] || return 1
  grep -qE '^[[:space:]]*multiplex_profiles:[[:space:]]*false' "$f" || return 1
  grep -qE '^mcp_servers:' "$f" || return 1
  return 0
}

# Allow-list patch. Host PyYAML, else the agent image (container is stopped).
# Does not clobber max_turns, secrets.bitwarden, platform_toolsets, compression, model.
patch_config_yaml() {
  local py='
import sys, yaml
from pathlib import Path
live_p, seed_p = Path(sys.argv[1]), Path(sys.argv[2])
cfg = yaml.safe_load(live_p.read_text(encoding="utf-8")) or {}
seed = yaml.safe_load(seed_p.read_text(encoding="utf-8")) or {}
gw = cfg.setdefault("gateway", {})
gw["multiplex_profiles"] = False
gw["auto_multiplex_migration"] = False
kanban = cfg.setdefault("kanban", {})
kanban["orchestrator_profile"] = ""
kanban["default_assignee"] = ""
agent = cfg.setdefault("agent", {})
agent["image_input_mode"] = "native"
cfg["mcp_servers"] = seed.get("mcp_servers") or {}
plugins = cfg.setdefault("plugins", {})
enabled = list(plugins.get("enabled") or [])
if "superpowers" not in enabled:
    enabled.append("superpowers")
plugins["enabled"] = enabled
term = cfg.setdefault("terminal", {})
term["cwd"] = "/workspace"
live_p.write_text(
    yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True, default_flow_style=False),
    encoding="utf-8",
)
print("patched multiplex_profiles=false mcp_servers plugins.union image_input_mode=native kanban empty")
'
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "$py" "$HERMES_DATA_DIR/config.yaml" "$STACK_DIR/agent/config.yaml"
    return
  fi
  docker image inspect hermes-agent-vps:latest >/dev/null 2>&1 \
    || fail "7: python3 yaml missing and hermes-agent-vps:latest is not present"
  docker run --rm --entrypoint python3 \
    -v "$HERMES_DATA_DIR/config.yaml:/cfg.yaml" \
    -v "$STACK_DIR/agent/config.yaml:/seed.yaml:ro" \
    hermes-agent-vps:latest -c "$py" /cfg.yaml /seed.yaml
}

step7() {
  info "7. patch data/config.yaml allow-list (do not clobber max_turns / bitwarden / platform_toolsets)"
  if config_already_patched; then
    skip "7 multiplex_profiles already false and mcp_servers present"
    return 0
  fi
  [ -f "$HERMES_DATA_DIR/config.yaml" ] || fail "7: $HERMES_DATA_DIR/config.yaml missing"
  [ -f "$STACK_DIR/agent/config.yaml" ] || fail "7: missing agent/config.yaml seed"
  if [ "$DRY" = 1 ]; then
    note "7 dry-run: would patch multiplex/mcp_servers/kanban/image_input_mode/plugins"
    return 0
  fi
  no_symlink "$HERMES_DATA_DIR/config.yaml"
  patch_config_yaml
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_DATA_DIR/config.yaml"
  config_already_patched || fail "7: patch did not set multiplex_profiles false + mcp_servers"
  note "7. ok (config.yaml allow-list)"
}

# ── 8. rewrite projects/HERMES.md (+ USER.md six-profile paragraph) ─────
step8() {
  info "8. rewrite $PROJECTS_DIR/HERMES.md from agent/HERMES.md"
  local dest="$PROJECTS_DIR/HERMES.md" src="$STACK_DIR/agent/HERMES.md"
  [ -f "$src" ] || fail "8: missing $src"
  if [ -f "$dest" ] && diff -q "$dest" "$src" >/dev/null 2>&1; then
    skip "8 HERMES.md already matches agent/HERMES.md"
  elif [ -f "$dest" ] && ! grep -qE 'claude -p|codex exec|hermes -p health' "$dest" \
      && ! grep -qE 'profiles/(chief|engineer|seo|researcher|health|markets)' "$dest"; then
    skip "8 HERMES.md already conforme (no claude -p / six-profile paths)"
  else
    if [ "$DRY" = 1 ]; then
      note "8 dry-run: would install agent/HERMES.md → $dest"
    else
      mkdir -p "$PROJECTS_DIR"
      install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$src" "$dest"
      note "8. wrote $dest"
    fi
  fi

  local user_live="$HERMES_DATA_DIR/USER.md" user_src="$STACK_DIR/agent/USER.md"
  if [ -f "$user_src" ] && [ -f "$user_live" ]; then
    if grep -qiE 'six profiles|profile (chief|engineer)|profiles/chief' "$user_live"; then
      if [ "$DRY" = 1 ]; then
        note "8 dry-run: would rewrite USER.md six-profile paragraph"
      else
        no_symlink "$user_live"
        install -m 644 -o "$HERMES_UID" -g "$HERMES_GID" "$user_src" "$user_live"
        note "8. rewrote data/USER.md (six-profile routing)"
      fi
    fi
  fi
}

# ── 9. agent.sh sync-files (host, agent stopped OK) ─────────────────────
step9() {
  info "9. CUTOVER=1 UPDATE_LOCKED=1 agent.sh sync-files"
  if [ "$DRY" = 1 ]; then
    note "9 dry-run: would UPDATE_LOCKED=1 CUTOVER=1 ./agent.sh sync-files"
    return 0
  fi
  agent_sh sync-files
  [ -f "$HERMES_DATA_DIR/SOUL.md" ] || fail "9: SOUL.md missing after sync-files"
  [ -f "$HERMES_DATA_DIR/.no-bundled-skills" ] || fail "9: .no-bundled-skills missing"
  [ -f "$HERMES_DATA_DIR/mcp-src/setup.sh" ] || fail "9: mcp-src/setup.sh missing"
  note "9. ok (SOUL + .no-bundled-skills + mcp-src/setup.sh)"
}

# ── 10. Orca User=hermes ────────────────────────────────────────────────
wait_orca_gone() {
  local i
  id orca >/dev/null 2>&1 || return 0
  for i in $(seq 1 30); do
    if ! ps -u orca -o pid= 2>/dev/null | grep -q '[0-9]'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

step10() {
  info "10. Orca: stop uid 999 → chown → write_service User=hermes → userdel orca"
  local unit_u
  unit_u="$(systemctl show orca -p User --value 2>/dev/null || true)"

  if ! id orca >/dev/null 2>&1 && [ "$unit_u" != orca ]; then
    if [ ! -f /etc/systemd/system/orca.service ]; then
      skip "10 orca never installed"
    elif [ "$unit_u" = hermes ]; then
      skip "10 orca.service already User=hermes (user orca absent)"
    else
      skip "10 user orca already absent (unit User=${unit_u:-none})"
    fi
    if [ "$DRY" = 0 ]; then
      rm -f /etc/sudoers.d/91-orca
      if command -v setfacl >/dev/null 2>&1; then
        setfacl -R -b "$STACK_DIR" "$HERMES_DATA_DIR" || warn "setfacl -b failed"
      fi
    fi
    return 0
  fi

  if [ "$DRY" = 1 ]; then
    note "10 dry-run: would warn sessions, systemctl stop orca, wait ps -u orca, chown, set_env, write_service, enable --now, rm 91-orca, userdel orca"
    return 0
  fi

  warn "Orca sessions (claude/codex/grok as uid 999) will die now"
  systemctl stop orca 2>/dev/null || true
  if ! wait_orca_gone; then
    warn "ps -u orca still not empty after 60s — continuing; userdel may skip"
  fi

  [ -d "$ORCA_HOME" ] && chown -R hermes:hermes "$ORCA_HOME"
  [ -d "$HELIOS_DIR" ] && chown -R hermes:hermes "$HELIOS_DIR"

  # write_service reads HERMES_WORKSPACE_DIR at source time (ORCA_WORKDIR).
  set_env HERMES_WORKSPACE_DIR "$PROJECTS_DIR"
  export HERMES_WORKSPACE_DIR="$PROJECTS_DIR"
  load_env
  mkdir -p "$PROJECTS_DIR"
  [ -d "$PROJECTS_DIR" ] || fail "10: $PROJECTS_DIR missing (write_service WorkingDirectory)"

  load_orca_fns
  write_service
  systemctl enable --now orca
  unit_u="$(systemctl show orca -p User --value 2>/dev/null || true)"
  [ "$unit_u" = hermes ] || fail "10: orca.service User=$unit_u (expected hermes)"

  rm -f /etc/sudoers.d/91-orca

  if id orca >/dev/null 2>&1; then
    if ps -u orca -o pid= 2>/dev/null | grep -q '[0-9]'; then
      skip "10 userdel orca: processes remain (report only, not abort)"
    elif ! userdel orca; then
      skip "10 userdel orca refused (report only, not abort)"
    else
      note "10. userdel orca (home kept)"
    fi
  else
    skip "10 userdel: user orca already absent"
  fi

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -b "$STACK_DIR" "$HERMES_DATA_DIR" || warn "setfacl -b failed"
    note "10. setfacl -R -b stack + data"
  else
    warn "setfacl not installed — leftover user:orca ACLs may remain"
  fi
  note "10. ok (orca.service User=hermes)"
}

# ── 11. rollback tags for the DNS/Obsidian image switch ─────────────────
tag_prev() {
  local src="$1" dst="$2"
  if docker image inspect "$dst" >/dev/null 2>&1; then
    skip "11 tag $dst exists"
    return 0
  fi
  if ! docker image inspect "$src" >/dev/null 2>&1; then
    skip "11 no image $src (cannot tag $dst)"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    note "11 dry-run: would docker tag $src $dst"
    return 0
  fi
  docker tag "$src" "$dst"
  note "11. tagged $dst"
}

step11() {
  info "11. tag hermes-dns/obsidian-sync + 4km3/dnsmasq:previous + node:previous"
  tag_prev hermes-dns:latest hermes-dns:previous
  tag_prev obsidian-sync:latest obsidian-sync:previous
  tag_prev hermes-dns:latest 4km3/dnsmasq:previous
  tag_prev obsidian-sync:latest node:previous
}

# ── 12. .env cwd + compose up --force-recreate ──────────────────────────
already_new_stack() {
  [ "$(docker inspect -f '{{.State.Health.Status}}' hermes-agent 2>/dev/null || echo no)" = healthy ] || return 1
  local cmd mounts
  cmd="$(docker inspect -f '{{json .Config.Cmd}}' hermes-agent 2>/dev/null || true)"
  echo "$cmd" | grep -q 'gateway' || return 1
  echo "$cmd" | grep -q -- '"-p"' && return 1
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' hermes-agent 2>/dev/null || true)"
  echo "$mounts" | grep -q "$PROJECTS_DIR" || return 1
  return 0
}

step12() {
  info "12. set_env HERMES_WORKSPACE_DIR + OBSIDIAN_HEADLESS_VERSION; compose up -d --force-recreate"
  if [ "$DRY" = 1 ]; then
    note "12 dry-run: would set_env HERMES_WORKSPACE_DIR=$PROJECTS_DIR, pin OBSIDIAN_HEADLESS_VERSION=0.0.14, compose up -d --force-recreate"
    return 0
  fi
  set_env HERMES_WORKSPACE_DIR "$PROJECTS_DIR"
  export HERMES_WORKSPACE_DIR="$PROJECTS_DIR"
  case "$(env_val OBSIDIAN_HEADLESS_VERSION)" in
    0.0.14) ;;
    *) set_env OBSIDIAN_HEADLESS_VERSION 0.0.14; note "12. pinned OBSIDIAN_HEADLESS_VERSION=0.0.14" ;;
  esac
  load_env

  if already_new_stack; then
    skip "12 already healthy on new image+cwd"
    wait_healthy hermes-agent 180 || fail "12: hermes-agent not healthy"
    return 0
  fi
  compose up -d --force-recreate --remove-orphans
  wait_healthy hermes-agent 180 || {
    compose logs --tail=50 hermes-agent
    fail "12: hermes-agent not healthy after 180s"
  }
  note "12. ok (hermes-agent healthy, cwd $PROJECTS_DIR)"
}

# ── 13. agent.sh sync + MCP tests fail-closed ───────────────────────────
step13() {
  info "13. CUTOVER=1 UPDATE_LOCKED=1 agent.sh sync; hermes mcp test hevy|yazio|renpho"
  if [ "$DRY" = 1 ]; then
    note "13 dry-run: would agent.sh sync then hermes mcp test hevy yazio renpho (fail-closed)"
    return 0
  fi
  agent_running || fail "13: hermes-agent is not running"
  agent_sh sync
  local s rc=0
  for s in hevy yazio renpho; do
    if agent_run hermes mcp test "$s"; then
      note "13. mcp test $s ok"
    else
      warn "13. mcp test $s FAILED"
      rc=1
    fi
  done
  [ "$rc" = 0 ] || fail "13: hermes mcp test hevy|yazio|renpho failed — migrate abort"
  note "13. ok (sync + MCP tests)"
}

# ── 14. cron / gateway / kanban experiment ──────────────────────────────
pause_scoped_crons() {
  local out name
  out="$(agent_run hermes cron list 2>&1 || true)"
  printf '%s\n' "$out"
  for name in "${OLD_PROFILES[@]}"; do
    if printf '%s\n' "$out" | grep -qiE "(^|[[:space:]/=])${name}([[:space:]/]|$)"; then
      warn "cron list mentions archived profile '$name' — pause those jobs by hand if they are still scheduled"
    fi
  done
}

step14() {
  info "14. hermes cron list; gateway status; kanban experiment"
  if [ "$DRY" = 1 ]; then
    note "14 dry-run: would dump cron list, gateway status, kanban orchestrator + list"
    return 0
  fi
  echo "── cron list ──"
  pause_scoped_crons || true
  echo "── gateway status ──"
  agent_run hermes gateway status 2>&1 || warn "gateway status failed"
  echo "── kanban.orchestrator_profile (expected empty) ──"
  local orch
  orch="$(agent_run hermes config get kanban.orchestrator_profile 2>/dev/null | tr -d '[:space:]' || true)"
  note "14. kanban.orchestrator_profile=${orch:-<empty>}"
  echo "── kanban list (assignee=default) ──"
  if ! agent_run hermes kanban list 2>&1; then
    warn "hermes kanban list failed — SQL fallback (do not create data/profiles/default/)"
    python3 - "$HERMES_DATA_DIR/kanban.db" <<'PY' || true
import sqlite3, sys
db = sys.argv[1]
try:
    con = sqlite3.connect(db)
    rows = con.execute(
        "SELECT id, title, assignee, status FROM tasks WHERE assignee = 'default' AND status NOT IN ('done','completed')"
    ).fetchall()
    for r in rows:
        print(f"  {r[0]}\t{r[3]}\t{r[2]}\t{r[1]}")
    if not rows:
        print("  (no in-progress tasks with assignee=default)")
    con.close()
except Exception as e:
    print("warn:", e)
PY
  fi
  # Profile-only messaging tokens: list names, not blocking.
  if [ -d "$HERMES_DATA_DIR/archive/profiles" ]; then
    python3 - "$HERMES_DATA_DIR/.env" "$HERMES_DATA_DIR/archive/profiles" <<'PY' || true
import sys
from pathlib import Path
root, arch = Path(sys.argv[1]), Path(sys.argv[2])
have = set()
if root.is_file():
    for line in root.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            have.add(line.split("=", 1)[0].strip())
only = []
for env in arch.glob("*/.env"):
    for line in env.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k = line.split("=", 1)[0].strip()
            if k and k not in have and k != "API_SERVER_KEY":
                only.append(f"{env.parent.name}:{k}")
if only:
    print("profile .env keys not in data/.env (re-run auth.sh messaging if needed):", " ".join(sorted(set(only))))
PY
  fi
  note "14. dumped cron/gateway/kanban"
}

# ── 15. rg fail-closed ──────────────────────────────────────────────────
# Operator-owned cut-over surfaces only. Do not walk the hermes-agent clone, vault,
# sessions, logs, backups — third-party skills there still contain `claude -p`.
step15() {
  info "15. rg fail-closed: STACK_DIR (excludes) + HERMES.md + data/{SOUL,USER,config,skills}"
  if [ "$DRY" = 1 ]; then
    note "15 dry-run: would rg STACK_DIR (excludes), HERMES.md, data/{SOUL.md,USER.md,config.yaml,skills}"
    return 0
  fi
  local hits="" ws="${HERMES_WORKSPACE_DIR:-$PROJECTS_DIR}" f
  local -a paths=("$STACK_DIR")
  [ -f "$ws/HERMES.md" ] && paths+=("$ws/HERMES.md")
  for f in SOUL.md USER.md config.yaml; do
    [ -f "$HERMES_DATA_DIR/$f" ] && paths+=("$HERMES_DATA_DIR/$f")
  done
  [ -d "$HERMES_DATA_DIR/skills" ] && paths+=("$HERMES_DATA_DIR/skills")
  if command -v rg >/dev/null 2>&1; then
    hits="$(rg -n -F -e 'claude -p' -e 'codex exec' -e 'hermes -p health' \
      --glob '!.git/**' --glob '!profiles/**' --glob '!docs/**' \
      --glob '!migrate-single-agent.sh' --glob '!node_modules/**' --glob '!.venv/**' \
      "${paths[@]}" 2>/dev/null || true)"
  else
    hits="$(grep -RIn -E 'claude -p|codex exec|hermes -p health' \
      --exclude-dir=.git --exclude-dir=profiles --exclude-dir=docs \
      --exclude-dir=node_modules --exclude-dir=.venv \
      --exclude=migrate-single-agent.sh \
      "${paths[@]}" 2>/dev/null || true)"
  fi
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    fail "15: leftover claude -p / codex exec / hermes -p health (list above)"
  fi
  note "15. ok (zero hits)"
}

# ── 16. report; do not rm .maintenance ──────────────────────────────────
step16() {
  cat <<MSG

════════════════════════════════════════════════════════════════════
 migrate-single-agent.sh report${DRY:+ (dry-run)}
════════════════════════════════════════════════════════════════════
MSG
  local line
  for line in "${REPORT[@]}"; do
    printf '  %s\n' "$line"
  done
  cat <<MSG

  .maintenance is still at $STACK_DIR/.maintenance
  heal.sh stays idle until you remove it, after verifying:
    dashboard https://\${HERMES_HOST} (one agent)
    curl 127.0.0.1:8642/health
    hermes mcp test hevy|yazio|renpho
    hermes gateway status
    sudo ./orca.sh status   (User=hermes)
    git -C $PROJECTS_DIR/projects/hermes-agent status
    nslookup \$HERMES_HOST \$DESKTOP_BIND

  Rollback (migrate, not images; only if archive is intact < 24 h):
    mv $HERMES_DATA_DIR/archive/profiles $HERMES_DATA_DIR/profiles
    restore active_profile, orchestrator_profile: chief, compose -p default

  Image rollback: sudo ./update.sh rollback
════════════════════════════════════════════════════════════════════
MSG
}

step0
step0b
step1
step2
step3
step4
step5
step6
step7
step8
step9
step10
step11
step12
step13
step14
step15
step16
