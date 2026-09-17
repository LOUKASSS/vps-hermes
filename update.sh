#!/usr/bin/env bash
# Update the stack: rebuild the derived images on the newest base, pull the other images, recreate.
# Keeps the previous images under a `:previous` tag and rolls back to them automatically when
# hermes-agent or hermes-workspace do not come back healthy.
#
#   sudo ./update.sh              # what hermes-update.timer runs (Sunday 03:30)
#   sudo ./update.sh rollback     # back to the images that ran before the last update, and hold
#   sudo ./update.sh resume       # lift the hold (next update pulls :latest again)
#   sudo ./update.sh --force      # update even while on hold
#
# Only one step back is kept: an update overwrites the previous `:previous` tags.
# Orca (host install) is updated at the end too; `orca.sh rollback` undoes that part.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"

# Every image reference the enabled services use (+ restic, which is not a compose service).
image_refs() { { compose config --images; echo "$RESTIC_IMAGE"; } | sort -u; }
prev_tag() { echo "${1%:*}:previous"; }

save_previous() {
  local img
  for img in $(image_refs); do
    docker image inspect "$img" >/dev/null 2>&1 || continue
    docker tag "$img" "$(prev_tag "$img")"
  done
  image_refs | while read -r img; do printf '%s %s\n' "$img" "$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null || echo -)"; done > "$STACK_DIR/.images.previous"
}

do_rollback() {
  local img prev n=0
  for img in $(image_refs); do
    prev="$(prev_tag "$img")"
    docker image inspect "$prev" >/dev/null 2>&1 || { warn "no previous image for $img"; continue; }
    docker tag "$prev" "$img"; n=$((n + 1))
  done
  [ "$n" -gt 0 ] || die "nothing to roll back to (no :previous tags)"
  info "Recreating containers on the previous images…"
  compose up -d --force-recreate --no-build --remove-orphans
  date -Is > "$UPDATE_HOLD"
  wait_healthy hermes-agent 180 || warn "hermes-agent still not healthy after the rollback"
  compose ps
  warn "Automatic updates are ON HOLD ($UPDATE_HOLD). When ready: sudo $0 resume"
}

do_update() {
  if [ -e "$UPDATE_HOLD" ] && [ "${1:-}" != --force ]; then
    warn "updates on hold since $(cat "$UPDATE_HOLD") (after a rollback). Lift with: sudo $0 resume — or: sudo $0 --force"
    exit 0
  fi
  # heal.sh holds this lock for up to ~5 min while it recreates the agent group; wait, do not skip silently.
  lock_update -w 600 || die "heal.sh (or another update.sh) has held $UPDATE_LOCK for 10 min — try again"
  info "Keeping the current images as :previous"
  save_previous
  info "Rebuilding derived images on the latest bases…"
  compose build --pull
  info "Pulling the other images…"
  compose pull --ignore-buildable
  docker pull -q "$RESTIC_IMAGE" >/dev/null
  info "Recreating containers…"
  compose up -d --remove-orphans
  if ! wait_healthy hermes-agent 180 || ! wait_healthy hermes-workspace 120; then
    compose logs --tail=40 hermes-agent hermes-workspace
    warn "stack not healthy after the update → rolling back"
    do_rollback
    exit 1
  fi
  rm -f "$UPDATE_HOLD"
  docker image prune -f >/dev/null
  docker builder prune -f --max-used-space 4g >/dev/null 2>&1 || docker builder prune -f --keep-storage 4g >/dev/null 2>&1 || true
  compose ps
  # Orca lives on the host (orca.sh); it has its own previous/rollback, independent of the images.
  if [ -e /opt/orca/current ]; then
    "$STACK_DIR/orca.sh" update || warn "Orca update failed (stack update is fine): sudo $STACK_DIR/orca.sh update"
  fi
}

case "${1:-}" in
  rollback) lock_stack -w 600 || die "backup.sh or another update.sh is running"; lock_update || die "update.sh is running"; do_rollback ;;
  resume)   rm -f "$UPDATE_HOLD"; info "hold lifted — next update.sh run pulls the latest images" ;;
  ""|--force) lock_stack || die "could not take $STACK_LOCK (backup.sh running for 3 h?)"; do_update "${1:-}" ;;
  *) die "usage: $0 [rollback|resume|--force]" ;;
esac
