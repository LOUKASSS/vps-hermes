#!/usr/bin/env bash
# Nightly update of the platform images, Hermes (host release) and the coding CLIs
# (hermes-update.timer, 04:00), arranged so that a bad release never leaves a service down:
#
#   1. preflight  no hold, enough disk → otherwise nothing is touched
#   2. images     public images are pulled (every tag put back on failure); same digests →
#                 nothing recreated; only the services whose image changed are recreated (what
#                 they ran becomes :previous); every service that was OK before must be healthy
#                 within UPDATE_VERIFY_TIMEOUT and still UPDATE_SETTLE s later → otherwise
#                 automatic rollback to :previous, the new versions remembered in .update-failed
#   3. Hermes     the release for HERMES_REF (default main) is built next to the running one
#                 (hermes-host.sh build: nothing restarts; smoke-tested) — skipped when it is the
#                 active one, or already failed here (a newer commit is tried)
#      busy gate  the switch waits until Hermes is not working (gateway turns, cron jobs, kanban
#                 runs, delegations — Hermes CLIs are never cut): up to UPDATE_BUSY_WAIT, then the
#                 night is skipped and notified. Once idle, Hermes is paused (no new gateway /
#                 cron / kanban work) until the switch is over
#      switch     /opt/hermes → the new release, services restarted; healthy within
#                 UPDATE_VERIFY_TIMEOUT and still UPDATE_SETTLE s later → otherwise back to the
#                 previous release, the commit remembered in .update-failed
#   4. host       orca.sh update (coding CLIs — the agent's too — + Orca release, each with its
#                 own rollback), herdr.sh update
#
#   sudo ./update.sh              # what hermes-update.timer runs (every night, 04:00)
#   sudo ./update.sh check        # pull + build, report what would change; restarts nothing
#   sudo ./update.sh rollback     # back to the images and the Hermes release that ran before, and hold
#   sudo ./update.sh resume       # lift the hold and forget the failed versions
#   sudo ./update.sh --force      # update even while on hold, retrying failed versions, without
#                                 # waiting for Hermes to be idle
#   sudo ./update.sh busy         # what Hermes is working on right now (exit 1 when busy)
#
# Result of the last run: state/last-update (shown by `command-center status`). Set
# UPDATE_NOTIFY_HERMES=telegram (Hermes' `hermes send`) and/or UPDATE_NOTIFY_URL (Discord webhook or
# ntfy topic) in .env to be told about skipped nights, failures and rollbacks.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"

UPDATE_FAILED="$STACK_DIR/.update-failed"    # "<image ref | hermes-release> <image id | commit sha> <date>"
UPDATE_STATUS="$STACK_DIR/state/last-update"
: "${UPDATE_VERIFY_TIMEOUT:=420}"   # obsidian-sync's healthcheck start_period is 300 s
: "${UPDATE_SETTLE:=60}"            # healthy must survive this long (crash loop after the first check)
: "${UPDATE_MIN_FREE_GB:=10}"
: "${UPDATE_BUSY_WAIT:=3600}"       # how long a busy Hermes may delay the switch before the night is skipped
HERMES_HOST_SH="$STACK_DIR/hermes-host.sh"
AGENT_KEY=hermes-release            # its key in .update-failed

# Every image reference the enabled services use (+ restic, which is not a compose service).
image_refs() {
  local refs; refs="$(compose config --images)" || die "docker compose config failed (bad .env?)"
  { printf '%s\n' "$refs"; echo "$RESTIC_IMAGE"; } | sort -u
}
# "<service> <image>" for every enabled service.
service_images() {
  compose config --format json | python3 -c 'import json, sys
for name, svc in json.load(sys.stdin)["services"].items(): print(name, svc.get("image", ""))'
}
# Suffix the shortest :* so 4km3/dnsmasq:2.90-r3 → 4km3/dnsmasq:previous and
# node:22-bookworm-slim → node:previous. node:22-bookworm-slim:previous is not a
# valid Docker ref (invalid reference format).
tag_as() { echo "${1%:*}:$2"; }
prev_tag() { tag_as "$1" previous; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

# One status line for the run (images · Hermes), rewritten as each step reports.
STATUS=()
record() {
  local line="" part
  STATUS+=("$*")
  for part in "${STATUS[@]}"; do line="${line:+$line · }$part"; done
  install -d -m 0755 "$STACK_DIR/state"; printf '%s %s\n' "$(date -Is)" "$line" > "$UPDATE_STATUS"
}

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

# Tag as <repo>:pre-update the image each container is actually RUNNING (docker inspect .Image),
# not whatever the ref resolves to now — a pull that failed half-way must not become the rollback
# target. Images with no running container (restic, a stopped profile) fall back to the tag.
# Only the refs that really change are promoted to :previous (swap): a night with nothing new must
# not overwrite the rollback point of the last real update.
snapshot_running() {
  local img id c ref
  declare -A seen=()
  while read -r c; do
    [ -n "$c" ] || continue
    ref="$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)" || continue
    id="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)" || continue
    { docker tag "$id" "$(tag_as "$ref" pre-update)" 2>/dev/null || docker tag "$ref" "$(tag_as "$ref" pre-update)"; } && seen["$ref"]=1
  done < <(compose ps -aq)
  for img in $(image_refs); do
    [ -n "${seen[$img]:-}" ] && continue
    docker image inspect "$img" >/dev/null 2>&1 || continue
    docker tag "$img" "$(tag_as "$img" pre-update)"
  done
}
# Every ref back to what ran before this run (stage failed, check mode, or a known-bad version).
restore_ref() { local pre; pre="$(tag_as "$1" pre-update)"; ! docker image inspect "$pre" >/dev/null 2>&1 || docker tag "$pre" "$1"; }
restore_refs() { local img; for img in $(image_refs); do restore_ref "$img"; done; }
# Drop the :pre-update tags (the images keep their other tags).
drop_staging() {
  local img
  for img in $(image_refs); do docker image rm "$(tag_as "$img" pre-update)" >/dev/null 2>&1 || true; done
}

is_failed() { [ "${FORCE:-0}" != 1 ] && grep -qsF "$1 $2 " "$UPDATE_FAILED"; }
mark_failed() { echo "$1 $2 $(date -Is)" >> "$UPDATE_FAILED"; }

# Enabled services that are not OK: no container, not running, or a healthcheck not (yet) healthy.
bad_services() {
  local s st h
  declare -A state=()
  while IFS=$'\t' read -r s st h; do state["$s"]="$st/$h"; done < <(compose ps -a --format '{{.Service}}\t{{.State}}\t{{.Health}}')
  for s in $(compose config --services); do
    case "${state[$s]:-missing/}" in running/|running/healthy) ;; *) echo "$s" ;; esac
  done
}
# which_bad <service…> — the listed services that are not OK right now.
which_bad() { local bad s; bad="$(bad_services)"; for s in "$@"; do grep -qx "$s" <<<"$bad" && echo "$s"; done; true; }
# wait_ok <secs> <service…> — all OK within <secs>, and still OK UPDATE_SETTLE s later. BAD = the culprits.
wait_ok() {
  local secs="$1"; shift
  local deadline=$((SECONDS + secs))
  while BAD="$(which_bad "$@")"; [ -n "$BAD" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
  sleep "$UPDATE_SETTLE"
  BAD="$(which_bad "$@")"
  [ -z "$BAD" ]
}

do_rollback() {
  local img prev n=0 fallback agent_prev=0 busy
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
  [ -e "$HERMES_RELEASES/previous/.release" ] && agent_prev=1
  [ "$n" -gt 0 ] || [ "$agent_prev" = 1 ] || die "nothing to roll back to (no :previous tags, no previous Hermes release)"
  busy="$(hermes_busy)"
  [ -z "$busy" ] || warn "rolling back although Hermes is working (cut): ${busy//$'\n'/; }"
  if [ "$n" -gt 0 ]; then
    info "Recreating containers on the previous images…"
    compose up -d --force-recreate --no-build --remove-orphans
  fi
  if [ "$agent_prev" = 1 ]; then
    info "Hermes: back to the previous release…"
    "$HERMES_HOST_SH" rollback || warn "Hermes not healthy after the rollback"
  fi
  date -Is > "$UPDATE_HOLD"
  compose ps
  record "manual rollback to :previous / previous Hermes release — automatic updates on hold"
  warn "Automatic updates are ON HOLD ($UPDATE_HOLD). When ready: sudo $0 resume"
}

# Automatic rollback of the services recreated by this run (CHANGED_*), called when they did not
# come back. The new versions are remembered so the next nights skip them until a newer one ships.
auto_rollback() {
  local why="$1" ref s
  warn "$why → rolling back: ${CHANGED_SVC[*]}"
  for s in $BAD; do compose logs --no-color --tail=30 "$s" 2>&1 | sed "s/^/  [$s] /" >&2 || true; done
  for ref in "${CHANGED_REFS[@]}"; do
    docker tag "$(prev_tag "$ref")" "$ref"
    mark_failed "$ref" "${NEW_KEY[$ref]}"
  done
  if compose up -d --no-build --no-deps --force-recreate "${CHANGED_SVC[@]}" && wait_ok "$UPDATE_VERIFY_TIMEOUT" "${CHECK_SVC[@]}"; then
    record "images ROLLED BACK ($why): ${SUMMARY[*]}"
    notify "update.sh: $why — rolled back to the previous images (${CHANGED_SVC[*]}). The failed versions are skipped until newer ones ship. journalctl -u hermes-update"
  else
    record "images ROLLBACK FAILED ($why) — not OK: ${BAD:-?}"
    notify "update.sh: $why, and the rollback did not bring back: ${BAD:-?}. Check the VPS: journalctl -u hermes-update, docker compose ps"
  fi
  NOTIFIED=1
  compose ps
  exit 1
}

# Busy gate before the Hermes switch. Waits (without UPDATE_LOCK, so heal.sh keeps watching)
# until idle or UPDATE_BUSY_WAIT is spent — then the switch is skipped for the night (return 1).
# Idle → pause Hermes (no new gateway / cron / kanban work) and check again: what started in
# between is let finish. --force: no wait.
gate_agent_idle() {
  local deadline=$((SECONDS + UPDATE_BUSY_WAIT)) busy
  while :; do
    if [ "${FORCE:-0}" != 1 ]; then
      flock -u 8; UPDATE_LOCKED=0
      if ! hermes_wait_idle "$deadline"; then
        record "Hermes skipped: still working after $((UPDATE_BUSY_WAIT / 60)) min — ${HERMES_BUSY//$'\n'/; }"
        NOTIFIED=1
        notify "update.sh: Hermes NOT updated tonight — it was still working after waiting $((UPDATE_BUSY_WAIT / 60)) min: ${HERMES_BUSY//$'\n'/; }. Next try: tomorrow 04:00, or now: sudo $STACK_DIR/update.sh --force"
        warn "Hermes still working after $((UPDATE_BUSY_WAIT / 60)) min — switch skipped"
        return 1
      fi
      lock_update -w 600 || die "heal.sh held $UPDATE_LOCK for 10 min after the wait — try again"
      if ! agent_healthy; then
        flock -u 8; UPDATE_LOCKED=0   # heal.sh must get the lock to repair it
        record "Hermes skipped: not healthy after waiting for it to be idle (heal.sh handles it)"
        warn "Hermes is not healthy any more — not switching a sick agent"
        return 1
      fi
    fi
    hermes_pause "Hermes is being updated (a few minutes)"
    busy="$(hermes_busy)"
    if [ -z "$busy" ] || [ "${FORCE:-0}" = 1 ]; then
      [ -z "$busy" ] || warn "--force: switching Hermes although it is working: ${busy//$'\n'/; }"
      return 0
    fi
    hermes_unpause
  done
}

on_exit() {
  local rc=$?
  if [ "${STAGED:-0}" = 1 ]; then
    restore_refs
    drop_staging
  fi
  hermes_unpause || true   # lift our pause (no-op when we did not set one)
  if [ "$rc" -ne 0 ] && [ "${NOTIFIED:-0}" != 1 ]; then
    [ "${STAGED:-0}" = 1 ] && record "FAILED before any change (exit $rc) — services untouched"
    notify "update.sh failed (exit $rc) — journalctl -u hermes-update"
  fi
}

# ── 2. images ──
update_images() {
  local mode="$1" before_bad ref s old new
  before_bad="$(bad_services)"
  [ -z "$before_bad" ] || warn "not OK before the update, so not verified after it: ${before_bad//$'\n'/ }"
  STAGED=1
  snapshot_running
  info "Pulling public images (traefik, postgres, dns, obsidian, proxy, restic)…"
  compose pull --ignore-buildable --ignore-pull-failures --quiet || warn "some images could not be pulled — they stay on their current version"
  docker pull -q "$RESTIC_IMAGE" >/dev/null || warn "could not pull $RESTIC_IMAGE"

  CHANGED_REFS=(); CHANGED_SVC=(); SUMMARY=(); declare -gA NEW_KEY=()
  local -a skipped=()
  for ref in $(image_refs); do
    old="$(image_id "$(tag_as "$ref" pre-update)")" || continue
    new="$(image_id "$ref")" || continue
    [ "$old" != "$new" ] || continue
    if is_failed "$ref" "$new"; then skipped+=("$ref"); restore_ref "$ref"; continue; fi
    NEW_KEY["$ref"]="$new"; CHANGED_REFS+=("$ref"); SUMMARY+=("$ref: ${old:7:12} → ${new:7:12}")
  done
  while read -r s ref; do
    for new in "${CHANGED_REFS[@]}"; do [ "$ref" = "$new" ] && CHANGED_SVC+=("$s"); done
  done < <(service_images)
  [ "${#skipped[@]}" -eq 0 ] || warn "already failed here, skipped until a newer version ships: ${skipped[*]} (retry: sudo $0 --force)"

  if [ "$mode" = check ]; then
    if [ "${#CHANGED_REFS[@]}" -eq 0 ]; then info "check: images: nothing to update"
    else info "check: images would update → ${SUMMARY[*]}"; info "check: would recreate → ${CHANGED_SVC[*]:-none}"; fi
    restore_refs; drop_staging; STAGED=0
    return 0
  fi
  if [ "${#CHANGED_REFS[@]}" -eq 0 ]; then
    info "Images: nothing new${skipped[*]:+ (skipped: ${skipped[*]})}"
    record "images unchanged${skipped[*]:+, skipped known-bad: ${skipped[*]}}"
    restore_refs; drop_staging; STAGED=0
    return 0
  fi
  # swap: what ran before becomes :previous (only for what changes)
  for ref in "${CHANGED_REFS[@]}"; do docker tag "$(tag_as "$ref" pre-update)" "$(prev_tag "$ref")"; done
  map_cutover_previous
  drop_staging; STAGED=0
  CHECK_SVC=()
  for s in $(compose config --services); do grep -qx "$s" <<<"$before_bad" || CHECK_SVC+=("$s"); done
  info "Updating: ${SUMMARY[*]}"
  if [ "${#CHANGED_SVC[@]}" -gt 0 ]; then
    info "Recreating ${CHANGED_SVC[*]} (the other services are left running)…"
    compose up -d --no-build --no-deps "${CHANGED_SVC[@]}" || { BAD="${CHANGED_SVC[*]}"; auto_rollback "docker compose up failed"; }
    info "Waiting for every service to be healthy (≤ ${UPDATE_VERIFY_TIMEOUT} s, then ${UPDATE_SETTLE} s stable)…"
    wait_ok "$UPDATE_VERIFY_TIMEOUT" "${CHECK_SVC[@]}" || auto_rollback "not healthy after the update: ${BAD//$'\n'/ }"
  fi
  record "images ok: ${SUMMARY[*]}"
  compose ps
}

# ── 3. Hermes (host release) ──
# agent_verify — healthy within UPDATE_VERIFY_TIMEOUT, and still UPDATE_SETTLE s later.
agent_verify() { agent_wait_healthy "$UPDATE_VERIFY_TIMEOUT" && sleep "$UPDATE_SETTLE" && agent_healthy; }

update_agent() {
  local mode="$1" sha short cur out busy
  hermes_installed || { warn "Hermes is not installed on the host — skipped (sudo command-center deploy hermes)"; return 0; }
  cur="$("$HERMES_HOST_SH" current)"
  if ! sha="$("$HERMES_HOST_SH" resolve)"; then
    record "Hermes: cannot resolve ${HERMES_REF:-main} — skipped"; warn "Hermes: cannot resolve ${HERMES_REF:-main}"; return 0
  fi
  short="${sha:0:12}"
  if [ "$short" = "$cur" ]; then info "Hermes: $cur is current"; record "Hermes $cur current"; return 0; fi
  if is_failed "$AGENT_KEY" "$sha"; then
    warn "Hermes $short already failed here — skipped until a newer commit (retry: sudo $0 --force)"
    record "Hermes $short skipped (known-bad)"; return 0
  fi
  if [ "$mode" != check ] && ! agent_healthy; then
    flock -u 8; UPDATE_LOCKED=0   # heal.sh must get the lock to repair it
    record "Hermes skipped: not healthy before the update (heal.sh handles it)"
    warn "Hermes is not healthy — not updating a sick agent"; return 0
  fi
  info "Hermes: building $short next to $cur (nothing restarts)…"
  if ! out="$("$HERMES_HOST_SH" build "$sha" 2>&1)"; then
    printf '%s\n' "$out" | tail -n 40 >&2
    record "Hermes FAILED: build of $short — $cur keeps running"; NOTIFIED=1
    notify "update.sh: the Hermes $short build failed — nothing was changed, $cur keeps running. journalctl -u hermes-update"
    return 0
  fi
  if [ "$mode" = check ]; then
    info "check: Hermes would switch $cur → $short"
    busy="$(hermes_busy)"
    if [ -z "$busy" ]; then info "check: Hermes is idle"
    else info "check: Hermes is working — the switch would wait (≤ $((UPDATE_BUSY_WAIT / 60)) min):"; printf '%s\n' "$busy" | sed 's/^/  /'; fi
    return 0
  fi
  gate_agent_idle || return 0
  info "Hermes: switching $cur → $short…"
  if "$HERMES_HOST_SH" activate "$short" && agent_verify; then
    rm -f "$UPDATE_HOLD"
    record "Hermes ok: $cur → $short"
    info "Hermes $short OK"
  else
    warn "Hermes $short not healthy → back to $cur"
    journalctl -u hermes-gateway -u hermes-dashboard -n 40 --no-pager -o cat >&2 || true
    mark_failed "$AGENT_KEY" "$sha"
    if "$HERMES_HOST_SH" rollback && agent_verify; then
      record "Hermes ROLLED BACK: $short not healthy — back on $cur"
      notify "update.sh: Hermes $short did not come up healthy — rolled back to $cur. That commit is skipped until a newer one. journalctl -u hermes-gateway"
    else
      record "Hermes ROLLBACK FAILED: $short not healthy, $cur not healthy either"
      notify "update.sh: Hermes $short did not come up, and the rollback to $cur is not healthy either. Check the VPS: sudo command-center hermes status"
    fi
    NOTIFIED=1
  fi
  hermes_unpause
}

do_update() {
  local mode="${1:-}" free_gb
  [ "$mode" = --force ] && FORCE=1
  if [ -e "$UPDATE_HOLD" ] && [ "$mode" = "" ]; then
    warn "updates on hold since $(cat "$UPDATE_HOLD"). Lift with: sudo $0 resume — or: sudo $0 --force"
    exit 0
  fi
  # heal.sh holds this lock for up to ~3 min while it restarts Hermes; wait, do not skip silently.
  lock_update -w 600 || die "heal.sh (or another update.sh) has held $UPDATE_LOCK for 10 min — try again"
  trap on_exit EXIT

  # ── 1. preflight ──
  free_gb="$(df --output=avail -BG "$(docker info -f '{{.DockerRootDir}}')" | tail -n1 | tr -dc 0-9)"
  if [ "${free_gb:-0}" -lt "$UPDATE_MIN_FREE_GB" ]; then
    record "skipped: only ${free_gb} GB free (< $UPDATE_MIN_FREE_GB)"
    die "only ${free_gb} GB free — not updating (UPDATE_MIN_FREE_GB=$UPDATE_MIN_FREE_GB)"
  fi

  update_images "$mode"
  update_agent "$mode"
  [ "$mode" != check ] || return 0
  docker image prune -f >/dev/null

  # ── 4. host tools: each has its own rollback; a failure there never undoes the rest ──
  if [ -e /opt/orca/current ]; then
    "$STACK_DIR/orca.sh" update || { warn "Orca update failed (stack update is fine): sudo $STACK_DIR/orca.sh update"; notify "update.sh: orca.sh update failed — journalctl -u hermes-update"; }
  fi
  # herdr (host, operator user): new binary + tode; the running server keeps its panes (no restart).
  if [ -e /etc/systemd/system/herdr.service ]; then
    "$STACK_DIR/herdr.sh" update || { warn "herdr update failed (stack update is fine): sudo $STACK_DIR/herdr.sh update"; notify "update.sh: herdr.sh update failed — journalctl -u hermes-update"; }
  fi
}

case "${1:-}" in
  rollback) lock_stack -w 600 || die "backup.sh or another update.sh is running"; lock_update || die "update.sh is running"; do_rollback ;;
  resume)   rm -f "$UPDATE_HOLD" "$UPDATE_FAILED"; info "hold lifted and failed versions forgotten — the next update.sh run tries the latest versions again" ;;
  ""|--force|check) lock_stack || die "could not take $STACK_LOCK (backup.sh running for 3 h?)"; do_update "${1:-}" ;;
  busy)     b="$(hermes_busy)"; [ -n "$b" ] || { info "Hermes is idle"; exit 0; }; info "Hermes is working:"; printf '%s\n' "$b" | sed 's/^/  /'; exit 1 ;;
  *) die "usage: $0 [check|busy|rollback|resume|--force]" ;;
esac
