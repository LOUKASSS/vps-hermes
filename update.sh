#!/usr/bin/env bash
# Nightly update of the Docker images and the coding CLIs (hermes-update.timer, 04:00), arranged
# so that a bad release never leaves a service down:
#
#   1. preflight  hermes-agent healthy, no hold, enough disk → otherwise nothing is touched
#   2. stage      the agent image is built as :candidate (never over :latest) and smoke-tested
#                 (hermes, claude, codex, grok, gh must start); public images are pulled. Any
#                 failure here puts every tag back — no container is recreated.
#   3. compare    same agent content (tool versions, OS and npm packages) and same digests →
#                 nothing is recreated; a version that already failed here is not retried
#                 (a newer one is)
#   3b. busy gate hermes-agent is recreated only when Hermes is not working (herdr panes where it
#                 is working/blocked, gateway turns, cron jobs, kanban runs, delegations): waits up
#                 to UPDATE_BUSY_WAIT, then skips the night and notifies. Once idle, Hermes is
#                 paused (no new gateway/cron/kanban work) until the swap is over, and the Hermes
#                 CLIs open in herdr are resumed in their panes (`hermes --resume <id>`) afterwards
#   4. swap       only the services whose image changed are recreated; the image each one ran
#                 before becomes :previous
#   5. verify     every service that was OK before must be running + healthy within
#                 UPDATE_VERIFY_TIMEOUT and still be UPDATE_SETTLE s later → otherwise automatic
#                 rollback to :previous, and the new versions are remembered in .update-failed
#   6. host       orca.sh update (CLIs + Orca release, each with its own rollback), herdr.sh update
#
#   sudo ./update.sh              # what hermes-update.timer runs (every night, 04:00)
#   sudo ./update.sh check        # steps 1–3 only: build, test, report what would change; recreates nothing
#   sudo ./update.sh rollback     # back to the images that ran before the last update, and hold
#   sudo ./update.sh resume       # lift the hold and forget the failed versions
#   sudo ./update.sh --force      # update even while on hold, retrying failed versions, without
#                                 # waiting for Hermes to be idle (its sessions are still resumed)
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

UPDATE_FAILED="$STACK_DIR/.update-failed"    # "<image ref> <image id | agent fingerprint> <date>"
UPDATE_STATUS="$STACK_DIR/state/last-update"
: "${UPDATE_VERIFY_TIMEOUT:=420}"   # obsidian-sync's healthcheck start_period is 300 s
: "${UPDATE_SETTLE:=60}"            # healthy must survive this long (crash loop after the first check)
: "${UPDATE_MIN_FREE_GB:=10}"
: "${UPDATE_BUSY_WAIT:=3600}"       # how long a busy Hermes may delay the recreate before the night is skipped
AGENT_SVC=hermes-agent

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

record() { install -d -m 0755 "$STACK_DIR/state"; printf '%s %s\n' "$(date -Is)" "$*" > "$UPDATE_STATUS"; }

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
# Drop the :pre-update / :candidate tags (the images keep their other tags).
drop_staging() {
  local img
  for img in $(image_refs); do docker image rm "$(tag_as "$img" pre-update)" >/dev/null 2>&1 || true; done
  docker image rm "$AGENT_CANDIDATE" >/dev/null 2>&1 || true
}

# probe_agent <image> — start every tool of the agent image once (smoke test) and hash what an
# update can change: upstream revision, tool versions, OS and global npm packages. Sets PROBE_FP
# (hash) and PROBE_VER (one-line summary). Offline, throwaway container, nothing mounted.
probe_agent() {
  local out
  if ! out="$(timeout 180 docker run --rm --network none --entrypoint sh "$1" -c \
      'set -e; hermes --version; claude --version; codex --version; grok --version; gh --version; dpkg-query -W; npm ls -g --depth=0' 2>&1)"; then
    printf '%s\n' "$out" | tail -n 20 >&2
    return 1
  fi
  PROBE_FP="$(printf '%s' "$out" | sha256sum | cut -c1-16)"
  PROBE_VER="$(printf '%s\n' "$out" | sed -n '1s/^Hermes Agent //p; /(Claude Code)$/p; /^codex-cli /p; /^grok /p; /^gh version /s/ (.*//p' | paste -sd'|' | sed 's/|/ · /g')"
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
  local busy; busy="$(hermes_busy)"
  [ -z "$busy" ] || warn "rolling back although Hermes is working (cut): ${busy//$'\n'/; }"
  hermes_panes_snapshot
  info "Recreating containers on the previous images…"
  compose up -d --force-recreate --no-build --remove-orphans
  date -Is > "$UPDATE_HOLD"
  wait_healthy hermes-agent 180 || warn "hermes-agent still not healthy after the rollback"
  compose ps
  hermes_sessions_restore
  record "manual rollback to :previous — automatic updates on hold"
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
    record "ROLLED BACK ($why): ${SUMMARY[*]}"
    notify "update.sh: $why — rolled back to the previous images (${CHANGED_SVC[*]}). The failed versions are skipped until newer ones ship. journalctl -u hermes-update"
  else
    record "ROLLBACK FAILED ($why) — not OK: ${BAD:-?}"
    notify "update.sh: $why, and the rollback did not bring back: ${BAD:-?}. Check the VPS: journalctl -u hermes-update, docker compose ps"
  fi
  NOTIFIED=1
  compose ps
  exit 1
}

# ── 3b. busy gate: hermes-agent is recreated only when no Hermes work would be cut. Waits (without
# UPDATE_LOCK, so heal.sh keeps watching the stack) until idle or UPDATE_BUSY_WAIT is spent — then
# the night is skipped: exit 0, on_exit puts every tag back. Idle → pause Hermes (no new gateway /
# cron / kanban work) and check again: what started in between is let finish. --force: no wait.
gate_agent_idle() {
  local deadline=$((SECONDS + UPDATE_BUSY_WAIT)) busy
  while :; do
    if [ "${FORCE:-0}" != 1 ]; then
      flock -u 8; UPDATE_LOCKED=0
      if ! hermes_wait_idle "$deadline"; then
        record "skipped: Hermes still working after $((UPDATE_BUSY_WAIT / 60)) min — ${HERMES_BUSY//$'\n'/; }"
        NOTIFIED=1
        notify "update.sh: night skipped, hermes-agent NOT updated — Hermes was still working after waiting $((UPDATE_BUSY_WAIT / 60)) min: ${HERMES_BUSY//$'\n'/; }. Next try: tomorrow 04:00, or now: sudo $STACK_DIR/update.sh --force"
        warn "Hermes still working after $((UPDATE_BUSY_WAIT / 60)) min — night skipped, nothing recreated"
        exit 0
      fi
      lock_update -w 600 || die "heal.sh held $UPDATE_LOCK for 10 min after the wait — try again"
      if [ -n "$(which_bad "$AGENT_SVC")" ]; then
        record "skipped: $AGENT_SVC not healthy after waiting for Hermes to be idle (heal.sh handles it)"
        warn "$AGENT_SVC is not healthy any more — not updating a stack that is sick"
        exit 0
      fi
    fi
    hermes_pause "hermes-agent is being updated (a few minutes)"
    busy="$(hermes_busy)"
    if [ -z "$busy" ] || [ "${FORCE:-0}" = 1 ]; then
      [ -z "$busy" ] || warn "--force: recreating $AGENT_SVC although Hermes is working: ${busy//$'\n'/; }"
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
  hermes_sessions_restore || true   # lift our pause, resume herdr's Hermes CLIs (no-op when nothing pending)
  if [ "$rc" -ne 0 ] && [ "${NOTIFIED:-0}" != 1 ]; then
    [ "${STAGED:-0}" = 1 ] && record "FAILED before any change (exit $rc) — services untouched"
    notify "update.sh failed (exit $rc) — journalctl -u hermes-update"
  fi
}

do_update() {
  local mode="${1:-}" ref s old new cur_fp
  [ "$mode" = --force ] && FORCE=1
  # This compose must not land on the live checkout before migrate-single-agent.sh
  # has removed data/active_profile. Recreating hermes-agent with `hermes gateway run`
  # while the sticky named profile is set steals 127.0.0.1:8642; /health stays 200
  # so wait_healthy would not roll back. --force does not bypass this.
  if [ -e "${HERMES_DATA_DIR}/active_profile" ]; then
    die "refusing update: ${HERMES_DATA_DIR}/active_profile exists — run migrate-single-agent.sh first (this compose must not recreate hermes-agent until the sticky profile is gone)"
  fi
  if [ -e "$UPDATE_HOLD" ] && [ "$mode" = "" ]; then
    warn "updates on hold since $(cat "$UPDATE_HOLD") (after a rollback). Lift with: sudo $0 resume — or: sudo $0 --force"
    exit 0
  fi
  # heal.sh holds this lock for up to ~3 min while it recreates hermes-agent; wait, do not skip silently.
  lock_update -w 600 || die "heal.sh (or another update.sh) has held $UPDATE_LOCK for 10 min — try again"
  trap on_exit EXIT

  # ── 1. preflight ──
  local before_bad free_gb
  before_bad="$(bad_services)"
  if grep -qx "$AGENT_SVC" <<<"$before_bad"; then
    record "skipped: $AGENT_SVC not healthy before the update (heal.sh handles it)"
    warn "$AGENT_SVC is not healthy — not updating a stack that is already sick"
    exit 0
  fi
  [ -z "$before_bad" ] || warn "not OK before the update, so not verified after it: ${before_bad//$'\n'/ }"
  free_gb="$(df --output=avail -BG "$(docker info -f '{{.DockerRootDir}}')" | tail -n1 | tr -dc 0-9)"
  if [ "${free_gb:-0}" -lt "$UPDATE_MIN_FREE_GB" ]; then
    record "skipped: only ${free_gb} GB free (< $UPDATE_MIN_FREE_GB)"
    die "only ${free_gb} GB free for Docker — not building (UPDATE_MIN_FREE_GB=$UPDATE_MIN_FREE_GB)"
  fi
  AGENT_IMAGE="$(service_images | awk -v s="$AGENT_SVC" '$1 == s { print $2 }')"
  [ -n "$AGENT_IMAGE" ] || die "no image for $AGENT_SVC in the compose config"
  AGENT_CANDIDATE="$(tag_as "$AGENT_IMAGE" candidate)"

  # ── 2. stage: nothing running is touched; any failure → on_exit restores every tag ──
  STAGED=1
  snapshot_running
  # --no-cache: re-run the npm layer even if the base image digest is unchanged, so unpinned
  # coding CLIs advance. Built under :candidate — :latest (what a recreate would use) stays put.
  info "Building the agent image (latest base + coding CLIs) as $AGENT_CANDIDATE…"
  local out
  if ! out="$(docker build --pull --no-cache --progress=plain -t "$AGENT_CANDIDATE" "$STACK_DIR/hermes" 2>&1)"; then
    printf '%s\n' "$out" | tail -n 40 >&2
    record "FAILED: agent image build — services untouched"; NOTIFIED=1
    notify "update.sh: the agent image build failed — nothing was changed, the current version keeps running. journalctl -u hermes-update"
    die "agent image build failed — nothing changed"
  fi
  info "Pulling public images (traefik, postgres, dns, obsidian, proxy, restic)…"
  compose pull --ignore-buildable --ignore-pull-failures --quiet || warn "some images could not be pulled — they stay on their current version"
  docker pull -q "$RESTIC_IMAGE" >/dev/null || warn "could not pull $RESTIC_IMAGE"

  # ── 3. compare + smoke test ──
  if ! probe_agent "$AGENT_CANDIDATE"; then
    record "FAILED: new agent image smoke test (a tool does not start) — services untouched"; NOTIFIED=1
    notify "update.sh: the new agent image fails its smoke test (hermes/claude/codex/grok/gh) — not deployed, the current version keeps running."
    die "the new agent image fails its smoke test — not deployed"
  fi
  local cand_fp="$PROBE_FP" cand_ver="$PROBE_VER"
  cur_fp=none; PROBE_VER="?"
  probe_agent "$(tag_as "$AGENT_IMAGE" pre-update)" 2>/dev/null && cur_fp="$PROBE_FP"
  local cur_ver="$PROBE_VER"

  CHANGED_REFS=(); CHANGED_SVC=(); SUMMARY=(); declare -gA NEW_KEY=()
  local -a skipped=()
  for ref in $(image_refs); do
    if [ "$ref" = "$AGENT_IMAGE" ]; then
      [ "$cand_fp" != "$cur_fp" ] || continue
      if is_failed "$ref" "$cand_fp"; then skipped+=("agent ($cand_ver)"); continue; fi
      NEW_KEY["$ref"]="$cand_fp"; CHANGED_REFS+=("$ref"); SUMMARY+=("agent: $cur_ver → $cand_ver")
      continue
    fi
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

  local recreate_agent=0
  for s in "${CHANGED_SVC[@]}"; do [ "$s" != "$AGENT_SVC" ] || recreate_agent=1; done
  if [ "$mode" = check ]; then
    info "check: agent now: $cur_ver"
    if [ "${#CHANGED_REFS[@]}" -eq 0 ]; then info "check: nothing to update"
    else info "check: would update → ${SUMMARY[*]}"; info "check: would recreate → ${CHANGED_SVC[*]:-none}"; fi
    local busy; busy="$(hermes_busy)"
    if [ -z "$busy" ]; then info "check: Hermes is idle"
    else
      if [ "$recreate_agent" = 1 ]; then info "check: Hermes is working — the update would wait (≤ $((UPDATE_BUSY_WAIT / 60)) min) before recreating $AGENT_SVC:"
      else info "check: Hermes is working ($AGENT_SVC would not be recreated, so it would not be cut):"; fi
      printf '%s\n' "$busy" | sed 's/^/  /'
    fi
    return 0   # on_exit puts every tag back
  fi
  [ "$recreate_agent" = 0 ] || gate_agent_idle
  if [ "${#CHANGED_REFS[@]}" -eq 0 ]; then
    info "Images: nothing new${skipped[*]:+ (skipped: ${skipped[*]})}"
    record "ok: images unchanged${skipped[*]:+, skipped known-bad: ${skipped[*]}}"
    restore_refs; drop_staging; STAGED=0
  else
    # ── 4. swap: what ran before becomes :previous (only for what changes) ──
    for ref in "${CHANGED_REFS[@]}"; do docker tag "$(tag_as "$ref" pre-update)" "$(prev_tag "$ref")"; done
    map_cutover_previous
    [ -z "${NEW_KEY[$AGENT_IMAGE]:-}" ] || docker tag "$AGENT_CANDIDATE" "$AGENT_IMAGE"
    drop_staging; STAGED=0
    CHECK_SVC=()
    for s in $(compose config --services); do grep -qx "$s" <<<"$before_bad" || CHECK_SVC+=("$s"); done
    info "Updating: ${SUMMARY[*]}"
    if [ "${#CHANGED_SVC[@]}" -gt 0 ]; then
      info "Recreating ${CHANGED_SVC[*]} (the other services are left running)…"
      [ "$recreate_agent" = 0 ] || hermes_panes_snapshot   # resumed by hermes_sessions_restore (here or on_exit)
      compose up -d --no-build --no-deps "${CHANGED_SVC[@]}" || { BAD="${CHANGED_SVC[*]}"; auto_rollback "docker compose up failed"; }
      # ── 5. verify ──
      info "Waiting for every service to be healthy (≤ ${UPDATE_VERIFY_TIMEOUT} s, then ${UPDATE_SETTLE} s stable)…"
      wait_ok "$UPDATE_VERIFY_TIMEOUT" "${CHECK_SVC[@]}" || auto_rollback "not healthy after the update: ${BAD//$'\n'/ }"
    fi
    rm -f "$UPDATE_HOLD"
    record "ok: ${SUMMARY[*]}"
    info "Update OK"
    compose ps
    hermes_sessions_restore
  fi
  docker image prune -f >/dev/null
  docker builder prune -f --max-used-space 4g >/dev/null 2>&1 || docker builder prune -f --keep-storage 4g >/dev/null 2>&1 || true

  # ── 6. host tools: each has its own rollback; a failure there never undoes the images ──
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
  resume)   rm -f "$UPDATE_HOLD" "$UPDATE_FAILED"; info "hold lifted and failed versions forgotten — the next update.sh run tries the latest images again" ;;
  ""|--force|check) lock_stack || die "could not take $STACK_LOCK (backup.sh running for 3 h?)"; do_update "${1:-}" ;;
  busy)     b="$(hermes_busy)"; [ -n "$b" ] || { info "Hermes is idle"; exit 0; }; info "Hermes is working:"; printf '%s\n' "$b" | sed 's/^/  /'; exit 1 ;;
  *) die "usage: $0 [check|busy|rollback|resume|--force]" ;;
esac
