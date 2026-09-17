#!/usr/bin/env bash
# Orca remote server (https://www.onorca.dev/docs/remote-servers) installed ON THE HOST, not in a
# container: `orca serve` runs as its own system user `orca` (systemd orca.service, docker group +
# passwordless sudo, so sessions can `docker compose up` for real on this VPS) with its own HOME
# (ORCA_HOME, default /srv/hermes/orca). That HOME is NOT shared with the agent container on
# purpose: the container writes /srv/hermes/data/home and /srv/hermes/workspace as uid HERMES_UID,
# and a dotfile planted there (~/.claude/settings.json hooks, ~/.gitconfig core.hooksPath,
# ~/.codex/config.toml MCP commands, .git/hooks of a checkout…) would run as a sudo user the next
# time an Orca session touched it. Only the credential FILES of the agent's claude / codex / grok /
# gh logins are copied over (`orca.sh creds`); config files never are.
#
#   sudo ./orca.sh install            # user orca, deps (Xvfb + Electron libs, Node 22, claude/codex/grok/gh), Orca, service, creds
#   sudo ./orca.sh update [--force]   # new release? download, verify, switch (previous kept), restart
#   sudo ./orca.sh rollback           # back to the previous release
#   sudo ./orca.sh pair [desktop|mobile]   # restart + print the pairing link / mobile QR
#   sudo ./orca.sh creds              # re-copy the agent's login files into ORCA_HOME (after auth.sh)
#   sudo ./orca.sh login <claude|codex|grok|gh>   # log in as user orca instead (separate account)
#   sudo ./orca.sh status | logs | remove
#
# Layout: /opt/orca/<tag>/ (extracted AppImage) · /opt/orca/current, /opt/orca/previous (symlinks)
#         /usr/local/bin/orca · /etc/orca.env (from .env) · /etc/systemd/system/orca.service
#         ORCA_HOME/ (0700 orca: .config/orca state, logins, work/ = default cwd of sessions)
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
: "${ORCA_PORT:=6768}" "${ORCA_MEM_LIMIT:=3g}" "${ORCA_HOME:=/srv/hermes/orca}"

ORCA_USER=orca
ORCA_WORKDIR="$ORCA_HOME/work"
ORCA_ROOT=/opt/orca
ORCA_ENV=/etc/orca.env
ORCA_UNIT=/etc/systemd/system/orca.service
ORCA_SUDOERS=/etc/sudoers.d/91-orca
AGENT_HOME="$HERMES_DATA_DIR/home"
RELEASES=https://github.com/stablyai/orca/releases
TMP_DIR=""; trap 'rm -rf "$TMP_DIR"' EXIT

installed_version() { cat "$ORCA_ROOT/current/VERSION" 2>/dev/null || true; }

# ── user ─────────────────────────────────────────────────────────────────
# System user with a login shell (sessions are interactive shells), docker group, passwordless
# sudo. Its HOME is 0700 and owned by orca only: nothing the agent container can write.
ensure_user() {
  if ! id "$ORCA_USER" >/dev/null 2>&1; then
    info "Creating user $ORCA_USER (HOME=$ORCA_HOME)…"
    groupadd -f docker
    useradd --system --create-home --home-dir "$ORCA_HOME" --shell /bin/bash --user-group "$ORCA_USER"
  fi
  usermod -aG docker "$ORCA_USER"
  install -d -m 0700 -o "$ORCA_USER" -g "$ORCA_USER" "$ORCA_HOME" "$ORCA_WORKDIR"
  local tmp; tmp="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ORCA_USER" > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers fragment for $ORCA_USER did not validate"; }
  install -m 0440 -o root -g root "$tmp" "$ORCA_SUDOERS"; rm -f "$tmp"
}

# Copy the agent's credential files (auth.sh logins) into ORCA_HOME — data only, never a config
# file. Symlinks in the container-controlled source are skipped. Both sides refresh their tokens
# independently; if one side ever logs out, `orca.sh creds` again or `orca.sh login <cli>`.
CRED_FILES=(.claude/.credentials.json .codex/auth.json .grok/auth.json .config/gh/hosts.yml)
sync_creds() {
  local f src dst n=0 missing=()
  for f in "${CRED_FILES[@]}"; do
    src="$AGENT_HOME/$f"; dst="$ORCA_HOME/$f"
    if [ -f "$src" ] && [ ! -L "$src" ]; then
      install -D -m 0600 -o "$ORCA_USER" -g "$ORCA_USER" "$src" "$dst"; n=$((n + 1))
    else
      missing+=("$f")
    fi
  done
  chown -R "$ORCA_USER:$ORCA_USER" "$ORCA_HOME/.claude" "$ORCA_HOME/.codex" "$ORCA_HOME/.grok" "$ORCA_HOME/.config" 2>/dev/null || true
  info "Copied $n login file(s) from $AGENT_HOME to $ORCA_HOME${missing[*]:+ (not logged in on the agent: ${missing[*]})}"
}

# Run a command as user orca with a clean environment (interactive: keeps the terminal).
as_orca() {
  runuser -u "$ORCA_USER" -- env -i HOME="$ORCA_HOME" USER="$ORCA_USER" LOGNAME="$ORCA_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin TERM="${TERM:-xterm}" LANG="${LANG:-C.UTF-8}" "$@"
}

# ── host dependencies ────────────────────────────────────────────────────
# First package name apt knows (Ubuntu 24.04 uses t64 names, 22.04 does not).
apt_pick() { local n; for n in "$@"; do apt-cache show "$n" >/dev/null 2>&1 && { echo "$n"; return; }; done; die "no apt candidate for $1 (unsupported Ubuntu release?)"; }

install_deps() {
  info "Installing Xvfb + Electron headless libraries…"
  apt-get update -q
  local pkgs=(xvfb file zlib1g curl ca-certificates git libnss3 libgbm1 libxtst6 libdrm2 libxkbcommon0
    libpango-1.0-0 libcairo2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 libxcb-dri3-0 libxss1)
  local p
  for p in "libgtk-3-0t64 libgtk-3-0" "libatk1.0-0t64 libatk1.0-0" "libatk-bridge2.0-0t64 libatk-bridge2.0-0" \
           "libasound2t64 libasound2" "libcups2t64 libcups2" "libatspi2.0-0t64 libatspi2.0-0"; do
    # shellcheck disable=SC2086
    p="$(apt_pick $p)"; [ -n "$p" ] && pkgs+=("$p")
  done
  apt-get install -y -q --no-install-recommends "${pkgs[@]}"

  # Node 22 (NodeSource) for the coding CLIs — Ubuntu's nodejs is too old for them.
  if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
    info "Installing Node.js 22 (NodeSource)…"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
    apt-get install -y -q nodejs
  fi
  if ! command -v gh >/dev/null 2>&1; then
    info "Installing GitHub CLI…"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list
    apt-get update -q && apt-get install -y -q --no-install-recommends gh
  fi
  install_clis
}

# Same set and flags as hermes/Dockerfile; global under /usr/local (npm prefix), on PATH for the service.
install_clis() {
  info "Installing/updating claude, codex, grok CLIs (npm -g)…"
  npm install -g --no-audit --no-fund --fetch-retries=5 \
    --allow-scripts=@anthropic-ai/claude-code,@xai-official/grok \
    @anthropic-ai/claude-code @openai/codex @xai-official/grok >/dev/null
  npm cache clean --force >/dev/null 2>&1 || true
  echo "  $(claude --version 2>/dev/null | head -n1) · codex $(codex --version 2>/dev/null | head -n1) · $(grok --version 2>/dev/null | head -n1) · $(gh --version | head -n1)"
}

# ── release download: verify sha512 from the electron-builder manifest, extract (no FUSE) ──
# fetch_release <tag|latest> → sets FETCHED_TAG (downloads only if that tag is not there yet)
fetch_release() {
  local want="$1" base tmp tag sum_want sum_got
  case "$want" in latest|"") base="$RELEASES/latest/download" ;; *) base="$RELEASES/download/$want" ;; esac
  mkdir -p "$ORCA_ROOT"
  TMP_DIR="$(mktemp -d -p "$ORCA_ROOT" .dl.XXXXXX)"; tmp="$TMP_DIR"   # same filesystem: the final mv is an atomic rename
  info "Downloading Orca ($want)…"
  curl -fsSL "$base/latest-linux.yml" -o "$tmp/latest-linux.yml"
  tag="v$(sed -n 's/^version: *//p' "$tmp/latest-linux.yml" | head -n1)"
  [ "$tag" != v ] || die "cannot read the version from latest-linux.yml"
  FETCHED_TAG="$tag"
  if [ -f "$ORCA_ROOT/$tag/VERSION" ]; then info "Orca $tag already downloaded"; return 0; fi
  rm -rf "${ORCA_ROOT:?}/$tag"   # a leftover without VERSION = interrupted install
  curl -fL --progress-bar "$base/orca-linux.AppImage" -o "$tmp/orca.AppImage"
  sum_want="$(sed -n '/url: orca-linux.AppImage/{n;s/^ *sha512: *//p}' "$tmp/latest-linux.yml" | head -n1 | base64 -d | od -An -tx1 -v | tr -d ' \n')"
  sum_got="$(sha512sum "$tmp/orca.AppImage" | cut -d' ' -f1)"
  [ -n "$sum_want" ] && [ "$sum_want" = "$sum_got" ] || die "orca-linux.AppImage: sha512 mismatch (want ${sum_want:-?} got $sum_got)"
  chmod +x "$tmp/orca.AppImage"
  (cd "$tmp" && ./orca.AppImage --appimage-extract >/dev/null)
  rm -f "$tmp/orca.AppImage"
  chown -R root:root "$tmp/squashfs-root"
  chmod 4755 "$tmp/squashfs-root/chrome-sandbox"          # Electron's setuid helper
  echo "$tag" > "$tmp/squashfs-root/VERSION"                # written last: marks a complete tree
  mv "$tmp/squashfs-root" "$ORCA_ROOT/$tag"
}

# activate <tag> — current → tag, previous → old current; prune anything else.
activate() {
  local tag="$1" cur d
  cur="$(installed_version)"
  [ "$cur" = "$tag" ] && return 0
  [ -n "$cur" ] && ln -sfn "$ORCA_ROOT/$cur" "$ORCA_ROOT/previous"
  ln -sfn "$ORCA_ROOT/$tag" "$ORCA_ROOT/current"
  ln -sfn "$ORCA_ROOT/current/AppRun" /usr/local/bin/orca
  for d in "$ORCA_ROOT"/v*/; do
    d="${d%/}"; [ -d "$d" ] || continue
    case "$(basename "$d")" in "$tag"|"$cur") ;; *) rm -rf "$d" ;; esac
  done
}

# ── service ──────────────────────────────────────────────────────────────
write_service() {
  case "${DESKTOP_BIND:-}" in
    ""|0.0.0.0|"::"|127.0.0.1) warn "DESKTOP_BIND=${DESKTOP_BIND:-unset}: Orca will advertise that address to its clients. Set it to the Tailscale IP (install.sh does when Tailscale is up)." ;;
  esac
  cat > "$ORCA_ENV" <<EOF
# Generated by orca.sh from $STACK_DIR/.env — re-run \`orca.sh pair\` / \`orca.sh update --force\` after editing .env.
HOME=$ORCA_HOME
PATH=/usr/local/bin:/usr/bin:/bin
DESKTOP_BIND=${DESKTOP_BIND:-127.0.0.1}
ORCA_PORT=$ORCA_PORT
ORCA_PAIRING=${ORCA_PAIRING:-}
LIBGL_ALWAYS_SOFTWARE=1
DISABLE_AUTOUPDATER=1
CODEX_DISABLE_UPDATE_CHECK=1
EOF
  chmod 644 "$ORCA_ENV"
  sed -e "s|@USER@|$ORCA_USER|g" -e "s|@GROUP@|$ORCA_USER|g" -e "s|@WORKDIR@|$ORCA_WORKDIR|g" \
      -e "s|@MEM@|${ORCA_MEM_LIMIT^^}|g" "$STACK_DIR/orca/orca.service" > "$ORCA_UNIT"
  systemctl daemon-reload
}

wait_up() {
  for _ in $(seq 1 24); do
    curl -sS -o /dev/null "http://127.0.0.1:$ORCA_PORT/" 2>/dev/null && return 0   # any HTTP answer = up
    systemctl is-active -q orca || { journalctl -u orca -n 30 --no-pager -o cat; die "orca.service died"; }
    sleep 5
  done
  return 1
}

# Orca prints ONE pairing link per run: runtime link (desktop app) or, with --mobile-pairing, a
# mobile-scoped QR/link. Already-paired devices keep their tokens, switching modes is safe.
print_pairing() {
  local since="$1" log url web
  log="$(journalctl -u orca --since "$since" --no-pager -o cat 2>/dev/null || true)"
  url="$(printf '%s\n' "$log" | { grep -o 'orca://pair[^ ]*' || true; } | tail -n1)"
  web="$(printf '%s\n' "$log" | { grep -o 'http://[^ ]*web-index.html[^ ]*' || true; } | tail -n1)"
  printf '%s\n' "$log" | sed -n '/pairing QR:/I,/^Pairing URL:/{/^Pairing URL:/!p}' | tail -n 60 || true
  local mode=desktop; [ -n "${ORCA_PAIRING:-}" ] && mode=mobile
  cat <<MSG

  Orca $(installed_version) on the host — orca.service ($(systemctl is-active orca 2>/dev/null)), ${DESKTOP_BIND:-?}:$ORCA_PORT (tailnet)
  Mode          : $mode pairing   (other device type: sudo $0 pair $([ "$mode" = mobile ] && echo desktop || echo mobile))
  Pairing link  : ${url:-<not found yet — journalctl -u orca -o cat | grep orca://pair>}
  Browser client: ${web:-n/a}
  Desktop app   : Settings → Remote Orca Servers → Add Server → paste the link
  Mobile app    : scan the QR above / open the link on the phone (must be on the tailnet)
  Sessions run as user $ORCA_USER (HOME=$ORCA_HOME, cwd $ORCA_WORKDIR) with docker and sudo — this being
  the host. Treat the link like a root password. Logins: copies of the agent's (sudo $0 creds), or
  your own (sudo $0 login claude|codex|grok|gh). Share code with the agent through git remotes, not
  by opening $HERMES_WORKSPACE_DIR (owned by the container's uid; git refuses it as "dubious ownership").
MSG
}

restart_and_pair() {
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl restart orca
  info "Waiting for Orca (up to 2 min)…"
  wait_up || { journalctl -u orca -n 40 --no-pager -o cat; die "orca did not come up on :$ORCA_PORT"; }
  sleep 3
  # Unattended (update.sh timer): do not copy the pairing link into another unit's journal.
  if [ -t 1 ]; then print_pairing "$since"; else info "Orca restarted; paired devices keep working. New link: sudo $0 pair"; fi
}

# ── commands ─────────────────────────────────────────────────────────────
do_install() {
  ensure_user
  install_deps
  orca_resolve_version
  fetch_release "${ORCA_VERSION:-latest}"
  activate "$FETCHED_TAG"
  sync_creds
  write_service
  systemctl enable -q orca
  if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is not active: port $ORCA_PORT is reachable from wherever this host is (harden.sh sets up the firewall)."
  fi
  restart_and_pair
}

# The CLIs are refreshed every time (new sessions pick them up, no restart needed); Orca itself
# is switched and restarted only on a new release (or --force).
do_update() {
  [ -e "$ORCA_ROOT/current" ] || die "Orca is not installed: sudo $0 install"
  if [ -e "$ORCA_ROOT/.hold" ] && [ "${1:-}" != --force ]; then
    warn "Orca updates on hold since $(cat "$ORCA_ROOT/.hold") (after orca.sh rollback). Lift with: sudo $0 update --force"
    return 0
  fi
  [ "${1:-}" = --force ] && rm -f "$ORCA_ROOT/.hold"
  install_clis
  orca_resolve_version
  local cur; cur="$(installed_version)"
  fetch_release "${ORCA_VERSION:-latest}"
  if [ "$FETCHED_TAG" = "$cur" ] && [ "${1:-}" != --force ]; then
    info "Orca $cur is current"
    return 0
  fi
  activate "$FETCHED_TAG"
  write_service
  restart_and_pair
}

do_rollback() {
  [ -e "$ORCA_ROOT/previous" ] || die "no previous Orca release kept"
  local prev cur; prev="$(readlink -f "$ORCA_ROOT/previous")"; cur="$(readlink -f "$ORCA_ROOT/current")"
  ln -sfn "$cur" "$ORCA_ROOT/previous"; ln -sfn "$prev" "$ORCA_ROOT/current"
  date -Is > "$ORCA_ROOT/.hold"   # the weekly update.sh → orca.sh update must not re-activate $cur
  info "Orca: $(basename "$cur") → $(basename "$prev") — updates on hold until: sudo $0 update --force"
  restart_and_pair
}

do_pair() {
  [ -e "$ORCA_UNIT" ] || die "Orca is not installed: sudo $0 install"
  local pairing
  case "${1:-desktop}" in desktop) pairing="" ;; mobile) pairing="--mobile-pairing" ;; *) die "usage: $0 pair [desktop|mobile]" ;; esac
  set_env ORCA_PAIRING "$pairing"; export ORCA_PAIRING="$pairing"
  write_service
  restart_and_pair
}

# login <cli> — interactive login as user orca (own account, independent of the agent's).
do_login() {
  case "${1:-}" in claude|codex|grok|gh) ;; *) die "usage: $0 login claude|codex|grok|gh" ;; esac
  id "$ORCA_USER" >/dev/null 2>&1 || die "user $ORCA_USER does not exist: sudo $0 install"
  [ -t 0 ] || die "login needs a terminal"
  case "$1" in
    claude) as_orca claude auth login ;;
    codex)  as_orca codex login --device-auth ;;
    grok)   as_orca grok login --device-auth ;;
    gh)     as_orca gh auth login --web --git-protocol https && as_orca gh auth setup-git ;;
  esac
}

do_status() {
  if [ -e "$ORCA_ROOT/current" ]; then
    echo "orca $(installed_version) (previous: $(cat "$ORCA_ROOT/previous/VERSION" 2>/dev/null || echo none))  orca.service: $(systemctl is-active orca 2>/dev/null)$([ -e "$ORCA_ROOT/.hold" ] && echo "  UPDATES ON HOLD (update --force)")"
    echo "listening: $(ss -ltnH "sport = :$ORCA_PORT" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')  advertised: ${DESKTOP_BIND:-?}:$ORCA_PORT  pairing: $([ -n "${ORCA_PAIRING:-}" ] && echo mobile || echo desktop)"
    echo "user $ORCA_USER · HOME=$ORCA_HOME · cwd $ORCA_WORKDIR"
    local f; for f in "${CRED_FILES[@]}"; do [ -f "$ORCA_HOME/$f" ] && echo "  login: $f" || echo "  no login: $f"; done
  else
    echo "not installed (sudo $0 install)"
  fi
}

do_remove() {
  systemctl disable --now orca 2>/dev/null || true
  rm -f "$ORCA_UNIT" "$ORCA_ENV" "$ORCA_SUDOERS" /usr/local/bin/orca
  systemctl daemon-reload
  rm -rf "$ORCA_ROOT"
  info "Orca removed. Kept: Node + claude/codex/grok/gh on the host, user $ORCA_USER and $ORCA_HOME (state, logins, work/): sudo userdel -r $ORCA_USER"
}

case "${1:-}" in
  install)  do_install ;;
  update)   do_update "${2:-}" ;;
  rollback) do_rollback ;;
  pair)     do_pair "${2:-desktop}" ;;
  creds)    id "$ORCA_USER" >/dev/null 2>&1 || die "user $ORCA_USER does not exist: sudo $0 install"; sync_creds ;;
  login)    do_login "${2:-}" ;;
  status)   do_status ;;
  logs)     journalctl -u orca -f -o cat ;;
  remove)   do_remove ;;
  *) die "usage: $0 install | update [--force] | rollback | pair [desktop|mobile] | creds | login <claude|codex|grok|gh> | status | logs | remove" ;;
esac
