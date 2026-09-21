#!/usr/bin/env bash
# Update the stack: rebuild the thin agent image on the newest base, pull public images, recreate.
# Keeps the previous images under a `:previous` tag and rolls back to them automatically when
# hermes-agent does not come back healthy.
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
image_refs() {
  local refs; refs="$(compose config --images)" || die "docker compose config failed (bad .env?)"
  { printf '%s\n' "$refs"; echo "$RESTIC_IMAGE"; } | sort -u
}
# Suffix the shortest :* so 4km3/dnsmasq:2.90-r3 → 4km3/dnsmasq:previous and
# node:22-bookworm-slim → node:previous. node:22-bookworm-slim:previous is not a
# valid Docker ref (invalid reference format).
prev_tag() { echo "${1%:*}:previous"; }

# First cut-over only: custom hermes-dns / obsidian-sync images must be reachable
# as the public images' :previous tags so do_rollback can retag
# 4km3/dnsmasq:previous → 4km3/dnsmasq:2.90-r3 (and node:previous → node:22-bookworm-slim)
# without a compose override. Later weeks: the running container already uses the
# public ref and save_previous tagged it; do not clobber that with the stale custom image.
map_cutover_previous() {
  local running
  running="$(docker inspect -f '{{.Config.Image}}' hermes-dns 2>/dev/null || true)"
  case "$running" in
    4km3/dnsmasq:*) ;;  # already on the public image; save_previous owns :previous
    hermes-dns:*)
      if docker image inspect hermes-dns:latest >/dev/null 2>&1; then
        docker tag hermes-dns:latest hermes-dns:previous
        docker tag hermes-dns:latest 4km3/dnsmasq:previous
      fi
      ;;
    "")
      if docker image inspect hermes-dns:latest >/dev/null 2>&1; then
        docker tag hermes-dns:latest hermes-dns:previous
        docker image inspect 4km3/dnsmasq:previous >/dev/null 2>&1 || \
          docker tag hermes-dns:latest 4km3/dnsmasq:previous
      fi
      ;;
  esac
  running="$(docker inspect -f '{{.Config.Image}}' obsidian-sync 2>/dev/null || true)"
  case "$running" in
    node:*) ;;
    obsidian-sync:*)
      if docker image inspect obsidian-sync:latest >/dev/null 2>&1; then
        docker tag obsidian-sync:latest obsidian-sync:previous
        docker tag obsidian-sync:latest node:previous
      fi
      ;;
    "")
      if docker image inspect obsidian-sync:latest >/dev/null 2>&1; then
        docker tag obsidian-sync:latest obsidian-sync:previous
        docker image inspect node:previous >/dev/null 2>&1 || \
          docker tag obsidian-sync:latest node:previous
      fi
      ;;
  esac
}

# Tag as :previous the image each container is actually RUNNING (docker inspect .Image), not
# whatever :latest resolves to now — a pull that failed half-way must not become the rollback
# target. Images with no running container (restic, a stopped profile) fall back to the tag.
save_previous() {
  local img id c ref
  declare -A seen=()
  while read -r c; do
    [ -n "$c" ] || continue
    ref="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)" || continue
    id="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)" || continue
    # containerd image store: .Image is a config digest `docker tag` cannot resolve → the ref
    # (what `compose up` would start again anyway) is the next best thing.
    { docker tag "$id" "$(prev_tag "$ref")" 2>/dev/null || docker tag "$ref" "$(prev_tag "$ref")"; } && seen["$ref"]=1
  done < <(compose ps -aq)
  for img in $(image_refs); do
    [ -n "${seen[$img]:-}" ] && continue
    docker image inspect "$img" >/dev/null 2>&1 || continue
    docker tag "$img" "$(prev_tag "$img")"
  done
}

do_rollback() {
  local img prev n=0 fallback
  for img in $(image_refs); do
    prev="$(prev_tag "$img")"
    if ! docker image inspect "$prev" >/dev/null 2>&1; then
      fallback=""
      case "$img" in
        4km3/dnsmasq:*) fallback=hermes-dns:previous ;;
        node:22-bookworm-slim) fallback=obsidian-sync:previous ;;
      esac
      if [ -n "$fallback" ] && docker image inspect "$fallback" >/dev/null 2>&1; then
        docker tag "$fallback" "$prev"
      fi
    fi
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
  # This compose must not land on the live checkout before migrate-single-agent.sh
  # has removed data/active_profile. Recreating hermes-agent with `hermes gateway run`
  # while the sticky named profile is set steals 127.0.0.1:8642; /health stays 200
  # so wait_healthy would not roll back. --force does not bypass this.
  if [ -e "${HERMES_DATA_DIR}/active_profile" ]; then
    die "refusing update: ${HERMES_DATA_DIR}/active_profile exists — run migrate-single-agent.sh first (this compose must not recreate hermes-agent until the sticky profile is gone)"
  fi
  if [ -e "$UPDATE_HOLD" ] && [ "${1:-}" != --force ]; then
    warn "updates on hold since $(cat "$UPDATE_HOLD") (after a rollback). Lift with: sudo $0 resume — or: sudo $0 --force"
    exit 0
  fi
  # heal.sh holds this lock for up to ~3 min while it recreates hermes-agent; wait, do not skip silently.
  lock_update -w 600 || die "heal.sh (or another update.sh) has held $UPDATE_LOCK for 10 min — try again"
  info "Keeping the current images as :previous"
  save_previous
  map_cutover_previous
  # Thin agent image only. Cache allowed: no npm CLIs in the image.
  # Base digest change (FROM latest) invalidates the apt layer naturally.
  info "Building thin agent image on the latest base…"
  compose build --pull hermes-agent
  info "Pulling public images (traefik, postgres, dns, obsidian, proxy, restic)…"
  compose pull --ignore-buildable
  docker pull -q "$RESTIC_IMAGE" >/dev/null
  info "Recreating containers…"
  if ! compose up -d --remove-orphans; then
    warn "docker compose up failed mid-way → rolling back"
    do_rollback
    exit 1
  fi
  if ! wait_healthy hermes-agent 180; then
    compose logs --tail=40 hermes-agent
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
