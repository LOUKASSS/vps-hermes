#!/usr/bin/env bash
# Encrypted, deduplicated backups of the Hermes stack to a Backblaze B2 bucket with restic.
#
#   sudo ./backup.sh setup                 # B2 creds → .env, init repo, enable the nightly timer
#   sudo ./backup.sh run                   # what the timer runs: hermes backup zip + restic backup + forget
#   sudo ./backup.sh snapshots             # list snapshots
#   sudo ./backup.sh restore <id|latest> <dir>   # restore a snapshot under <dir> (host paths preserved)
#   sudo ./backup.sh check                 # verify repository integrity (reads a data sample)
#   sudo ./backup.sh restic <args…>        # raw restic against the repo
#
# What is backed up: $HERMES_DATA_DIR (config, auth.json, state.db, memory, skills, CLI creds under
# home/, plus the consistent `hermes backup` zip under backups/), $HERMES_WORKSPACE_DIR (your files,
# minus dependency dirs), $OBSIDIAN_DIR, $TRAEFIK_DIR/acme.json, the stack .env and, when Orca is
# installed on the host, $ORCA_HOME (Orca state, pairings, its copies of the logins, work/).
# Retention: 7 daily, 4 weekly, 6 monthly; prune runs on Sundays.
#
# Keep RESTIC_PASSWORD + the B2 credentials somewhere safe (password manager): without them the
# repository is unreadable and a fresh VPS cannot restore anything.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

KEEP_ARGS=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
EXCLUDES=(
  --exclude-caches
  --exclude '**/node_modules' --exclude '**/.venv' --exclude '**/venv' --exclude '**/__pycache__'
  --exclude '**/.cache' --exclude '**/.npm' --exclude '**/checkpoints'
  --exclude '**/browser-profiles' --exclude '**/browser-profile'
)

configured() { [ -n "${B2_ACCOUNT_ID:-}" ] && [ -n "${B2_ACCOUNT_KEY:-}" ] && [ -n "${RESTIC_PASSWORD:-}" ]; }
require_configured() { configured || die "Backups not configured. Run: sudo $0 setup"; }

do_setup() {
  need_root
  info "Backblaze B2: create a bucket (private) and an application key restricted to it"
  info "(capabilities: listBuckets, listFiles, readFiles, writeFiles, deleteFiles)."
  ask B2_BUCKET      "B2 bucket name"
  ask B2_ACCOUNT_ID  "B2 application keyID"
  ask B2_ACCOUNT_KEY "B2 application key" secret
  if [ -z "$(env_val RESTIC_PASSWORD)" ]; then
    set_env RESTIC_PASSWORD "$(openssl rand -base64 32 | tr -d '/+=')"
    info "Generated RESTIC_PASSWORD (encryption key of the repository)."
  fi
  [ -n "$(env_val RESTIC_REPOSITORY)" ] || set_env RESTIC_REPOSITORY "b2:$(env_val B2_BUCKET):hermes"
  chmod 600 "$STACK_DIR/.env"
  load_env

  if restic_run cat config >/dev/null 2>&1; then
    info "Repository $RESTIC_REPOSITORY already initialised — reusing it."
  else
    info "Initialising repository $RESTIC_REPOSITORY…"
    restic_run init
  fi

  if [ -f /etc/systemd/system/hermes-backup.timer ]; then
    systemctl enable --now hermes-backup.timer
    info "Nightly timer enabled: $(systemctl show hermes-backup.timer -p NextElapseUSecRealtime --value)"
  else
    warn "systemd units not installed yet — run ./install.sh (it installs and enables the timer)."
  fi

  cat <<MSG

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  SAVE THESE (password manager). Needed to restore on a fresh VPS:        │
  │    RESTIC_REPOSITORY=$(env_val RESTIC_REPOSITORY)
  │    RESTIC_PASSWORD=$(env_val RESTIC_PASSWORD)
  │    B2_ACCOUNT_ID=$(env_val B2_ACCOUNT_ID)
  │    B2_ACCOUNT_KEY=$(env_val B2_ACCOUNT_KEY)
  └──────────────────────────────────────────────────────────────────────────┘

  First backup: sudo $0 run      Status later: journalctl -u hermes-backup
MSG
}

do_run() {
  require_configured
  lock_stack -n || die "another backup.sh or update.sh is running"

  # 1. Consistent application-level snapshot (sqlite backup API for state.db), kept under
  #    $HERMES_DATA_DIR/backups so `hermes import <zip>` works on any Hermes install.
  if [ "$(docker inspect -f '{{.State.Health.Status}}' hermes-agent 2>/dev/null)" = healthy ]; then
    info "hermes backup → /opt/data/backups/"
    agent_run sh -c 'mkdir -p /opt/data/backups && hermes backup -o "/opt/data/backups/hermes-backup-$(date +%Y%m%d-%H%M%S).zip" -k 2' \
      || warn "hermes backup failed — continuing with the raw data dir"
  else
    warn "hermes-agent not healthy: skipping the hermes backup zip (raw data dir is still backed up)"
  fi

  # 2. Encrypted, deduplicated upload of the host paths.
  info "restic backup → $RESTIC_REPOSITORY"
  local paths=("$HERMES_DATA_DIR" "$HERMES_WORKSPACE_DIR" "$OBSIDIAN_DIR" "$TRAEFIK_DIR/acme.json" "$STACK_DIR/.env")
  [ -d "$ORCA_HOME" ] && paths+=("$ORCA_HOME")
  restic_run backup --tag hermes-stack "${EXCLUDES[@]}" "${paths[@]}"

  # 3. Retention. Prune (actual deletion, B2 API-call heavy) once a week.
  prune=()
  [ "$(date +%u)" = 7 ] && prune=(--prune)
  restic_run forget --tag hermes-stack "${KEEP_ARGS[@]}" "${prune[@]}"
  info "done"
}

do_restore() {
  require_configured
  local snap="${1:-}" target="${2:-}"
  [ -n "$snap" ] && [ -n "$target" ] || die "usage: $0 restore <snapshot-id|latest> <target-dir>"
  mkdir -p "$target"
  info "Restoring snapshot $snap under $target (host paths are preserved, e.g. $target$HERMES_DATA_DIR)…"
  restic_run --rw "$target" restore "$snap" --target /restore
  cat <<MSG

Restored under $target. To put it back in place with the stack stopped (as root — restic kept the original owners/modes):
  sudo docker compose --project-directory $STACK_DIR down
  sudo rsync -a $target$HERMES_DATA_DIR/ $HERMES_DATA_DIR/
  sudo rsync -a $target$HERMES_WORKSPACE_DIR/ $HERMES_WORKSPACE_DIR/
  sudo rsync -a $target$OBSIDIAN_DIR/ $OBSIDIAN_DIR/
  sudo cp $target$TRAEFIK_DIR/acme.json $TRAEFIK_DIR/acme.json && sudo chmod 600 $TRAEFIK_DIR/acme.json
  sudo cp $target$STACK_DIR/.env $STACK_DIR/.env
  sudo $STACK_DIR/install.sh     # re-chowns, re-applies DESKTOP_BIND/HERMES_UID for this host, recreates
$( [ -d "$target$ORCA_HOME" ] && printf '  sudo %s/orca.sh install && sudo rsync -a %s/ %s/ && sudo chown -R orca:orca %s && sudo systemctl restart orca   # Orca state + pairings\n' "$STACK_DIR" "$target$ORCA_HOME" "$ORCA_HOME" "$ORCA_HOME" )
  sudo rm -rf $target            # it holds every secret in clear
Alternative (Hermes state only, into a running agent): sudo ./auth.sh shell → hermes import /opt/data/backups/hermes-backup-<ts>.zip
MSG
}

case "${1:-}" in
  setup)     do_setup ;;
  run)       do_run ;;
  snapshots) require_configured; restic_run snapshots --tag hermes-stack ;;
  restore)   do_restore "${2:-}" "${3:-}" ;;
  check)     require_configured; restic_run check --read-data-subset=5% ;;
  restic)    require_configured; shift; restic_run "$@" ;;
  *) die "usage: $0 setup|run|snapshots|restore <id|latest> <dir>|check|restic <args…>" ;;
esac
