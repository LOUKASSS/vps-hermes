#!/usr/bin/env bash
# Discord backup bot (github.com/LOUKASSS/discord-backup-bot) — encrypted snapshots of the
# Discord guild, on the host as system units running as the operator (User=hermes):
# discord-backup-bot.service (gateway bot + 04:00 capture) and discord-backup-verify.timer (05:00).
#
#   DISCORD_BACKUP_DIR = /srv/discord-backup      root 0711, NOT mounted in the agent container
#   ├── app/src.git                 bare mirror of the repo (hermes: fetched with its gh credentials)
#   ├── app/releases/<sha>/         git archive + npm ci + npm run check as hermes, then frozen root:root
#   ├── app/current, app/previous   what the units execute / the rollback target
#   ├── bws.env                     BWS_ACCESS_TOKEN only (root 0600, read by systemd), from $HELIOS_CLI_HOME/.hermes/.env
#   ├── hooks/                      root: optional off-host-replicate executable (the bot's fixed path)
#   ├── log/                        root: service.log, verify.log (opened by systemd as root)
#   └── var/                        hermes 0700, the ONLY hermes-writable part: backups/ (*.dsnap,
#                                   legacy v1 *.json), automation state, checkpoints, backup.lock
#
# Root never writes inside var/ or src.git (hermes-owned): what root touches is root-owned, so the
# service user (or an npm postinstall at build time) cannot redirect a root write with a symlink.
#
# The bot reads DISCORD_BACKUP_BOT_TOKEN and DISCORD_BACKUP_ARCHIVE_KEY from Bitwarden Secrets
# Manager at every start (bin/run-with-bws.py); neither is ever written on this host, and this
# script never writes to BWS. NEVER replace DISCORD_BACKUP_ARCHIVE_KEY: every archive is sealed with it.
#
#   sudo ./discord-backup.sh install            # bws + tree + bws.env + release + units (nothing started)
#   sudo ./discord-backup.sh import <dir>       # copy an old var/ (backups, state) in, as hermes, bot stopped
#   sudo ./discord-backup.sh start              # bot + 05:00 verify timer; only once the old host's bot is stopped
#   sudo ./discord-backup.sh deploy [ref]       # new release (default DISCORD_BACKUP_REF), restart, rollback on failure
#   sudo ./discord-backup.sh rollback | status | logs | verify | stop | restart | uninstall
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
: "${HELIOS_CLI_HOME:=$ORCA_HOME}"
: "${DISCORD_BACKUP_REPO:=https://github.com/LOUKASSS/discord-backup-bot.git}"
: "${DISCORD_BACKUP_REF:=ops/discordjs14-production}"

DB_DIR="$DISCORD_BACKUP_DIR"
DB_APP="$DB_DIR/app"
DB_VAR="$DB_DIR/var"
DB_ENV="$DB_DIR/bws.env"
DB_LOGS="$DB_DIR/log"
DB_LOG="$DB_LOGS/service.log"
DB_VLOG="$DB_LOGS/verify.log"
LOCK_FILE=/run/lock/discord-backup.lock
BOT_UNIT="discord-backup-bot.service"
VERIFY_UNIT="discord-backup-verify.service"
VERIFY_TIMER="discord-backup-verify.timer"
KEEP_RELEASES=3
READY_TIMEOUT=90

# bws: pinned release; zip sha256 from the release's bws-sha256-checksums-2.0.0.txt.
BWS_BIN=/usr/local/bin/bws
BWS_VERSION=2.0.0
declare -A BWS_ZIP_SHA256=(
  [x86_64]=a8340ce01da609200441f2eca0e591173e124f012c88a16afda574279c052013
  [aarch64]=49a250d4f3121c67155c195afbad4ced90a92a878c3256ca091276b82e7ad131
)

# ── bws ─────────────────────────────────────────────────────────────────
install_bws() {
  if [ -x "$BWS_BIN" ] && "$BWS_BIN" --version 2>/dev/null | grep -qx "bws $BWS_VERSION"; then return 0; fi
  local arch sum tmp
  arch="$(uname -m)"; sum="${BWS_ZIP_SHA256[$arch]:-}"
  [ -n "$sum" ] || die "no pinned bws build for $arch"
  tmp="$(mktemp -d)"
  info "bws $BWS_VERSION → $BWS_BIN (sha256-pinned)"
  curl -fsSL -o "$tmp/bws.zip" \
    "https://github.com/bitwarden/sdk-sm/releases/download/bws-v$BWS_VERSION/bws-$arch-unknown-linux-gnu-$BWS_VERSION.zip" \
    || { rm -rf "$tmp"; die "bws download failed"; }
  echo "$sum  $tmp/bws.zip" | sha256sum -c --quiet - || { rm -rf "$tmp"; die "bws zip checksum mismatch — refusing to install"; }
  python3 -m zipfile -e "$tmp/bws.zip" "$tmp/x"
  install -m 0755 -o root -g root "$tmp/x/bws" "$BWS_BIN"
  rm -rf "$tmp"
}

# bws.env holds BWS_ACCESS_TOKEN and nothing else (the units' EnvironmentFile, read by systemd as
# root): root 0600, the service user cannot read it. Kept if present.
write_bws_env() {
  no_symlink "$DB_ENV"
  if ! { [ -s "$DB_ENV" ] && grep -q '^BWS_ACCESS_TOKEN=.' "$DB_ENV"; }; then
    local src="$HELIOS_CLI_HOME/.hermes/.env" line
    line="$(grep -m1 '^BWS_ACCESS_TOKEN=.' "$src" 2>/dev/null || true)"
    [ -n "$line" ] || die "no BWS_ACCESS_TOKEN in $src — put one in $DB_ENV (root 0600, that line only)"
    ( umask 077; printf '%s\n' "$line" > "$DB_ENV" )
    info "bws.env: BWS_ACCESS_TOKEN copied from $src"
  fi
  chown root:root "$DB_ENV"; chmod 600 "$DB_ENV"
}

# ── tree ────────────────────────────────────────────────────────────────
# Everything root touches is root-owned; var/ (hermes) is only ever written by hermes itself.
ensure_tree() {
  no_symlink "$DB_DIR"
  install -d -m 0711 -o root -g root "$DB_DIR"
  no_symlink "$DB_APP" "$DB_APP/releases" "$DB_LOGS" "$DB_DIR/hooks" "$DB_VAR"
  install -d -m 0755 -o root -g root "$DB_APP" "$DB_APP/releases" "$DB_DIR/hooks"
  install -d -m 0700 -o root -g root "$DB_LOGS"
  install -d -m 0700 -o "$HERMES_UID" -g "$HERMES_GID" "$DB_VAR"
  as_op mkdir -p -m 0700 "$DB_VAR/backups"
  local f
  for f in "$DB_LOG" "$DB_VLOG"; do [ -e "$f" ] || install -m 0600 -o root -g root /dev/null "$f"; done
}

# One mutating run at a time (deploy vs rollback vs import vs start).
lock() { exec 7>"$LOCK_FILE"; flock -n 7 || die "another discord-backup.sh run holds $LOCK_FILE"; }

# ── releases ────────────────────────────────────────────────────────────
# Fetched as the operator (gh credential helper in its HOME): the mirror is operator-owned.
fetch_src() {
  local git_dir="$DB_APP/src.git"
  if [ ! -d "$git_dir" ]; then
    install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$git_dir"
    as_op git clone -q --bare "$DISCORD_BACKUP_REPO" "$git_dir"
  fi
  as_op git -C "$git_dir" fetch -q --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
}

# build_release <ref> — prints the release dir. Built and tested as the operator, then frozen root:root.
build_release() {
  local ref="$1" sha rel tmp
  sha="$(as_op git -C "$DB_APP/src.git" rev-parse --verify -q "$ref^{commit}")" || die "unknown ref: $ref"
  rel="$DB_APP/releases/$sha"
  if [ -f "$rel/.built" ]; then echo "$rel"; return 0; fi
  tmp="$DB_APP/releases/.$sha.tmp"
  rm -rf "$tmp"; install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$tmp"
  info "release ${sha:0:12} ($ref): npm ci + npm run check" >&2
  # shellcheck disable=SC2016  # expanded by the inner bash
  as_op bash -c 'set -e; git -C "$1" -c safe.directory="*" archive "$2" | tar -x -C "$3"; cd "$3"
    npm ci --omit=dev --no-audit --no-fund --loglevel=error >/dev/null
    out="$(npm run check 2>&1)" || { grep -E "^not ok|^# (pass|fail)" <<<"$out" >&2; exit 1; }' \
    _ "$DB_APP/src.git" "$sha" "$tmp" || { rm -rf "$tmp"; die "release ${sha:0:12} failed its tests — not activated"; }
  as_op sh -c 'printf "%s %s\n" "$1" "$(date -Is)" > "$2/.built"' _ "$ref" "$tmp"
  chown -R root:root "$tmp"; chmod -R go-w "$tmp"   # -R never follows symlinks the build left behind
  mv -T "$tmp" "$rel"
  echo "$rel"
}

# release_of <link> — the release dir a link points to, or "" (readlink -f alone echoes a missing path back).
release_of() { [ -L "$1" ] && [ -d "$1" ] && readlink -f "$1" || true; }
current_release() { release_of "$DB_APP/current"; }

# activate <release dir> — current → it, previous → the old current. Atomic swaps.
activate() {
  local rel="$1" old; old="$(current_release)"
  [ "$old" = "$rel" ] && return 0
  if [ -n "$old" ]; then ln -sfn "$old" "$DB_APP/.previous.tmp"; mv -T "$DB_APP/.previous.tmp" "$DB_APP/previous"; fi
  ln -sfn "$rel" "$DB_APP/.current.tmp"; mv -T "$DB_APP/.current.tmp" "$DB_APP/current"
  info "current → $(basename "$rel" | cut -c1-12)"
}

prune_releases() {
  local cur prev r
  cur="$(current_release)"; prev="$(release_of "$DB_APP/previous")"
  find "$DB_APP/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- \
    | tail -n +$((KEEP_RELEASES + 1)) | while read -r r; do
      [ "$r" = "$cur" ] || [ "$r" = "$prev" ] || rm -rf "$r"
    done
}

# The units ship in the release (deploy/): the repo's own tests guard their hardening.
# verify_units <release> runs before activation, so a bad unit never replaces a working one.
verify_units() {
  systemd-analyze verify "$1/deploy/$BOT_UNIT" "$1/deploy/$VERIFY_UNIT" "$1/deploy/$VERIFY_TIMER" \
    || { warn "systemd-analyze verify failed on the units of $(basename "$1" | cut -c1-12)"; return 1; }
}

install_units() {
  local u
  for u in "$BOT_UNIT" "$VERIFY_UNIT" "$VERIFY_TIMER"; do
    install -m 0644 "$DB_APP/current/deploy/$u" "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
}

# ── bot lifecycle ───────────────────────────────────────────────────────
bot_active() { systemctl is-active -q "$BOT_UNIT"; }

# restart_and_check — (re)start the bot, wait for READY + ENCRYPTED_V2_READY in the new log bytes.
restart_and_check() {
  local offset i new
  offset="$(stat -c %s "$DB_LOG" 2>/dev/null || echo 0)"
  systemctl reset-failed "$BOT_UNIT" 2>/dev/null || true
  systemctl restart "$BOT_UNIT"
  for ((i = 0; i < READY_TIMEOUT; i++)); do
    new="$(tail -c +$((offset + 1)) "$DB_LOG" 2>/dev/null || true)"
    if grep -q '^READY bot=' <<<"$new" && grep -q 'ENCRYPTED_V2_READY' <<<"$new"; then
      info "bot READY, encrypted v2 armed"; return 0
    fi
    if grep -qE 'ENCRYPTED_V2_UNAVAILABLE|SENSITIVE_SCOPE_REFUSED' <<<"$new" || ! bot_active; then break; fi
    sleep 1
  done
  warn "bot not READY with encryption — last log lines:"
  tail -c +$((offset + 1)) "$DB_LOG" 2>/dev/null | tail -n 15 >&2
  return 1
}

confirm_single_instance() {
  [ "${DISCORD_BACKUP_CONFIRM:-}" = yes ] && return 0
  warn "One instance per bot token: the OLD host's discord-backup-bot must be stopped and disabled,"
  warn "or both answer /backup and both run the 04:00 capture."
  [ -t 0 ] || die "non-interactive: re-run with DISCORD_BACKUP_CONFIRM=yes once the old bot is stopped"
  local a; read -r -p "Old host's bot stopped and disabled? [y/N] " a
  [[ "$a" =~ ^[yYoO] ]] || die "not started"
}

# ── commands ────────────────────────────────────────────────────────────
do_install() {
  command -v node >/dev/null || die "node not found (/usr/bin/node, >= 20)"
  install_bws; ensure_tree; write_bws_env
  fetch_src
  local rel; rel="$(build_release "$DISCORD_BACKUP_REF")"
  verify_units "$rel" || die "not activated"
  activate "$rel"; install_units
  info "installed; nothing is started. Once the old host's bot is stopped:"
  info "  sudo $0 import <copy of the old var/>   (optional: existing archives and state)"
  info "  sudo $0 start"
}

do_deploy() {
  [ -e "$DB_APP/current" ] || die "not installed: sudo $0 install"
  fetch_src
  local ref="${1:-$DISCORD_BACKUP_REF}" rel old
  old="$(current_release)"
  rel="$(build_release "$ref")"
  if [ "$rel" = "$old" ]; then info "already on $(basename "$rel" | cut -c1-12)"; return 0; fi
  verify_units "$rel" || die "deploy of $ref aborted — still on $(basename "$old" | cut -c1-12)"
  activate "$rel"; install_units
  if bot_active; then
    if restart_and_check; then prune_releases; return 0; fi
    warn "rolling back to $(basename "$old" | cut -c1-12)"
    activate "$old"; install_units; restart_and_check || true
    die "deploy of $ref failed — rolled back"
  fi
  prune_releases
  info "bot not running: the new release is used at the next start"
}

do_rollback() {
  local prev; prev="$(release_of "$DB_APP/previous")"
  [ -n "$prev" ] || die "no previous release"
  verify_units "$prev" || die "previous release's units no longer verify"
  activate "$prev"; install_units
  if bot_active; then restart_and_check || die "rolled-back release did not come up READY"; fi
}

do_start() {
  [ -e "/etc/systemd/system/$BOT_UNIT" ] || die "not installed: sudo $0 install"
  confirm_single_instance
  systemctl enable -q "$BOT_UNIT"
  restart_and_check || die "$BOT_UNIT did not come up READY (sudo $0 logs)"
  # Enabled with the bot, not at install: before archives exist the verifier exits 4 every day.
  systemctl enable -q --now "$VERIFY_TIMER"
  info "verify timer: next $(systemctl show "$VERIFY_TIMER" -p NextElapseUSecRealtime --value)"
}

# import <dir> — an old var/ (backups/, automation-state.json, restore-checkpoints/…) into var/.
do_import() {
  local src="${1:-}"
  [ -n "$src" ] && [ -d "$src/backups" ] || die "usage: $0 import <dir containing backups/> (a copy of the old /opt/hermes/var/discord-backup-bot)"
  ! bot_active || die "stop the bot first: sudo $0 stop"
  command -v rsync >/dev/null || die "rsync not installed"
  ensure_tree
  # As hermes: root never writes into var/. The copy must therefore be readable by hermes.
  as_op test -r "$src/backups" -a -x "$src/backups" || die "$src/backups is not readable by $OP_USER (chown -R $OP_USER the copy)"
  info "import $src → $DB_VAR as $OP_USER (existing files kept; 0700/0600; logs and lock skipped)"
  as_op rsync -a --ignore-existing --no-links --exclude backup.lock --exclude '*.log' \
    --chmod=D0700,F0600 "${src%/}/" "$DB_VAR/"
  info "backups/: $(find "$DB_VAR/backups" -maxdepth 1 -name '*.dsnap' | wc -l) .dsnap, $(find "$DB_VAR/backups" -maxdepth 1 -name '*.json' | wc -l) legacy v1"
  info "check them now: sudo $0 verify"
}

do_verify() {
  if systemctl start "$VERIFY_UNIT"; then info "verification passed"
  else warn "verification FAILED (exit code: systemctl status $VERIFY_UNIT)"; fi
  grep 'VERIFY_SUMMARY' "$DB_VLOG" 2>/dev/null | tail -n 1 || true
}

do_status() {
  local cur code enabled b="$DB_VAR/backups"
  cur="$(current_release)"
  if [ -n "$cur" ]; then code="$(basename "$cur" | cut -c1-12) ($(cut -d' ' -f1 "$cur/.built" 2>/dev/null))"; else code="not installed"; fi
  enabled="$(systemctl is-enabled "$BOT_UNIT" 2>/dev/null || true)"
  echo "code     : $code · bws $("$BWS_BIN" --version 2>/dev/null | awk '{print $2}' || echo missing)"
  echo "bot      : $(systemctl is-active "$BOT_UNIT" 2>/dev/null || true) (${enabled:-not installed}) · restarts $(systemctl show "$BOT_UNIT" -p NRestarts --value 2>/dev/null || echo '?')"
  echo "last log : $(grep -E '^READY |ENCRYPTED_V2_(READY|UNAVAILABLE)|SCHEDULER_ARMED_V2|AUTO_BACKUP_V2_(SUCCESS|FAILED)' "$DB_LOG" 2>/dev/null | tail -n 1 | cut -c1-110)"
  echo "archives : $(find "$b" -maxdepth 1 -name '*.dsnap' 2>/dev/null | wc -l) .dsnap, $(find "$b" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l) legacy v1 · $(du -sh "$b" 2>/dev/null | cut -f1) · newest $(find "$b" -maxdepth 1 -name '*.dsnap' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -n1)"
  echo "verify   : timer $(systemctl is-active "$VERIFY_TIMER" 2>/dev/null || true), next $(systemctl show "$VERIFY_TIMER" -p NextElapseUSecRealtime --value 2>/dev/null) · $(grep VERIFY_SUMMARY "$DB_VLOG" 2>/dev/null | tail -n1 | cut -c1-90)"
}

do_uninstall() {
  systemctl disable -q --now "$VERIFY_TIMER" "$BOT_UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$BOT_UNIT" "/etc/systemd/system/$VERIFY_UNIT" "/etc/systemd/system/$VERIFY_TIMER"
  systemctl daemon-reload
  info "units removed. Kept: $DB_DIR (archives, state, releases) and $BWS_BIN"
}

case "${1:-}" in
  install|deploy|rollback|start|stop|restart|import|uninstall) lock ;;
esac
case "${1:-}" in
  install)   do_install ;;
  deploy)    shift; do_deploy "$@" ;;
  rollback)  do_rollback ;;
  start)     do_start ;;
  stop)      systemctl disable -q --now "$BOT_UNIT" "$VERIFY_TIMER"; info "bot and verify timer stopped and disabled" ;;
  restart)   restart_and_check || die "$BOT_UNIT did not come up READY" ;;
  import)    shift; do_import "$@" ;;
  verify)    do_verify ;;
  status)    do_status ;;
  logs)      tail -n 100 -F "$DB_LOG" ;;
  uninstall) do_uninstall ;;
  *) die "usage: $0 install | import <dir> | start | deploy [ref] | rollback | status | logs | verify | stop | restart | uninstall" ;;
esac
