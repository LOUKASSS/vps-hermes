#!/usr/bin/env bash
# herdr (https://herdr.dev) — terminal workspace manager for coding agents — installed ON THE HOST
# for the operator user `hermes` (the SSH user), with the terminal-code plugin
# (https://github.com/zenbu-labs/terminal-code: VS Code in the terminal, `tode`).
#
#   ssh hermes@<vps>  →  herdr            (TUI; attaches to the persistent herdr.service server)
#   herdr --remote hermes@<vps>           (from a laptop that has herdr: local UI, remote panes)
#
# Panes start in the shared workspace (/srv/workspace — the same path the Hermes agent and Orca
# use), herdr worktrees go to /srv/workspace/worktrees/herdr. HOME is the login HOME of `hermes`
# (/home/hermes), separate from the agent's (/srv/hermes/data/home) and Orca's (/srv/orca): only
# grok / gh credential FILES are copied between them (`herdr.sh creds`), never config files — same
# rule as orca.sh. Claude and Codex rotate their refresh token: own login (`herdr.sh login`).
#
#   sudo ./herdr.sh install        # herdr + config + terminal-code plugin (tode) + integrations + herdr.service
#   sudo ./herdr.sh update         # herdr update + tode --upgrade (server restarted only when idle-safe: --restart);
#                                  # previous binary kept, restored automatically if the new one does not start
#   sudo ./herdr.sh rollback       # back to the binary that ran before the last update
#   sudo ./herdr.sh creds          # copy the agent's grok / gh logins into /home/hermes
#   sudo ./herdr.sh login <claude|codex|grok|gh>   # or log in separately as hermes
#   sudo ./herdr.sh apply [all|config|workspaces [--dry-run]|plugins|diff]
#                                  # the operator's herdr-config repo (cloned when missing): committed
#                                  # config.toml, one workspace per repo, pinned plugins — run as hermes
#   sudo ./herdr.sh status | logs | restart | remove
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
: "${HERDR_MEM_LIMIT:=4g}"
: "${HERDR_CONFIG_DIR:=$HERMES_WORKSPACE_DIR/projects/herdr-config}" "${HERDR_CONFIG_REPO:=https://github.com/LOUKASSS/herdr-config.git}"

HERDR_BIN="$OP_HOME/.local/bin/herdr"
HERDR_CFG_DIR="$OP_HOME/.config/herdr"
HERDR_UNIT=/etc/systemd/system/herdr.service
TODE_PLUGIN=zenbu-labs/terminal-code/herdr-plugin
TODE_PLUGIN_ID=zenbu-labs.tode
INTEGRATIONS=(claude codex grok)
CRED_FILES=(.claude/.credentials.json .codex/auth.json .grok/auth.json .config/gh/hosts.yml)
# Claude and Codex OAuth rotate a single-use refresh token: a copied login and its original
# refresh independently and one of them gets revoked. Only static tokens are copied (orca.sh: same).
COPY_CRED_FILES=(.grok/auth.json .config/gh/hosts.yml)
AGENT_HOME="$HERMES_DATA_DIR/home"

id "$OP_USER" >/dev/null 2>&1 || die "user $OP_USER does not exist (harden.sh creates it)"

hd() { as_op "$HERDR_BIN" "$@"; }
installed() { [ -x "$HERDR_BIN" ]; }
server_up() { installed && hd status server 2>/dev/null | grep -q 'status: running'; }

apt_pick() { local n; for n in "$@"; do apt-cache show "$n" >/dev/null 2>&1 && { echo "$n"; return; }; done; }

# tode vendors Electron (terminal-browser) + code-server: Chromium's usual system libraries.
install_deps() {
  local pkgs=(curl ca-certificates git libnss3 libgbm1 libxkbcommon0 libdrm2) p
  for p in "libgtk-3-0t64 libgtk-3-0" "libasound2t64 libasound2" "libatk-bridge2.0-0t64 libatk-bridge2.0-0" "libcups2t64 libcups2"; do
    # shellcheck disable=SC2086
    p="$(apt_pick $p)"; [ -z "$p" ] || pkgs+=("$p")
  done
  local missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Installing ${missing[*]}…"
    apt-get update -q && apt-get install -y -q --no-install-recommends "${missing[@]}"
  fi
}

install_herdr() {
  install -d -m 0755 -o "$OP_USER" -g "$OP_USER" "$OP_HOME/.local" "$OP_HOME/.local/bin" "$OP_HOME/.config" "$HERDR_CFG_DIR"
  if installed; then
    info "herdr $(hd --version 2>/dev/null | awk '{print $2}') already installed at $HERDR_BIN (update: sudo $0 update)"
    return 0
  fi
  info "Installing herdr for $OP_USER (official installer, sha256-verified)…"
  as_op env HERDR_INSTALL_DIR="$OP_HOME/.local/bin" sh -c 'curl -fsSL --retry 3 https://herdr.dev/install.sh | sh' >/dev/null
  installed || die "herdr install failed"
  info "  $(hd --version)"
}

# config.toml is seeded once (then it is the operator's file, managed from the herdr-config repo:
# `herdr.sh apply config` installs its committed copy — never a symlink into the workspace).
write_config() {
  local f="$HERDR_CFG_DIR/config.toml"
  no_symlink "$f"
  if [ ! -f "$f" ]; then
    cat > "$f" <<EOF
# herdr config — seeded by $STACK_DIR/herdr.sh; source of truth: $HERDR_CONFIG_REPO (herdr.sh apply config).
# Full reference: herdr --default-config
onboarding = false

[terminal]
# New panes and tabs inherit the cwd of their workspace (one workspace per repo: herdr.sh apply workspaces).
new_cwd = "follow"

[worktrees]
# Worktrees live in the workspace too, so the agent container and Orca see them at the same path.
directory = "$HERMES_WORKSPACE_DIR/worktrees/herdr"

[session]
resume_agents_on_restore = true
EOF
    chown "$OP_USER:$OP_USER" "$f"; chmod 644 "$f"
    info "  wrote $f"
  fi
  install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$HERMES_WORKSPACE_DIR/worktrees/herdr"
}

# Managed block in ~/.bashrc: PATH, $WORKSPACE, `ws` shortcut. Login shells over SSH land in the workspace.
write_bashrc() {
  local f="$OP_HOME/.bashrc" tmp
  no_symlink "$f"
  touch "$f"
  tmp="$(mktemp)"
  sed '/^# >>> command-center >>>$/,/^# <<< command-center <<<$/d' "$f" > "$tmp"
  cat >> "$tmp" <<EOF
# >>> command-center >>>
# Managed by $STACK_DIR/herdr.sh — edits inside this block are overwritten.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
export WORKSPACE="$HERMES_WORKSPACE_DIR"
alias ws='cd "\$WORKSPACE"'
# Interactive SSH logins start in the shared workspace (run \`herdr\` from there).
if [ -n "\${SSH_CONNECTION:-}" ] && [ -z "\${HERDR_ENV:-}" ] && [ "\$PWD" = "\$HOME" ]; then cd "\$WORKSPACE"; fi
# <<< command-center <<<
EOF
  cat "$tmp" > "$f"; rm -f "$tmp"
  chown "$OP_USER:$OP_USER" "$f"
  info "  ~/.bashrc block (PATH, WORKSPACE, ws)"
}

# Copy credential files only (never settings.json / config.toml / hooks): the agent container
# writes $AGENT_HOME, and a config planted there must not run as this sudoer.
sync_creds() {
  local f src dst n=0 missing=() force="${1:-}"
  for f in "${COPY_CRED_FILES[@]}"; do
    src="$AGENT_HOME/$f"; dst="$OP_HOME/$f"
    if [ -f "$dst" ] && [ "$force" != --force ]; then continue; fi
    if [ -f "$src" ] && [ ! -L "$src" ]; then
      no_symlink "$dst"
      install -D -m 0600 -o "$OP_USER" -g "$OP_USER" "$src" "$dst"; n=$((n + 1))
    else
      missing+=("$f")
    fi
  done
  local d; for d in .claude .codex .grok .config/gh; do [ ! -d "$OP_HOME/$d" ] || chown "$OP_USER:$OP_USER" "$OP_HOME/$d"; done
  info "  copied $n login file(s) from the agent into $OP_HOME${missing[*]:+ (absent on the agent: ${missing[*]})}"
  for f in .claude/.credentials.json .codex/auth.json; do
    [ -f "$OP_HOME/$f" ] || info "  ${f%%/*}: not copied (rotating OAuth) — own login: sudo $0 login $(basename "${f%%/*}" | tr -d .)"
  done
}

install_plugin() {
  if hd plugin list 2>/dev/null | grep -q "$TODE_PLUGIN_ID"; then
    info "  plugin $TODE_PLUGIN_ID already installed"
  else
    info "Installing the terminal-code plugin ($TODE_PLUGIN — downloads tode, ~140 MB)…"
    hd plugin install "$TODE_PLUGIN" --yes || die "herdr plugin install $TODE_PLUGIN failed"
  fi
  as_op sh -c 'command -v tode >/dev/null' || die "tode not on PATH after the plugin build ($OP_HOME/.local/bin/tode)"
  local missing
  missing="$(ldd "$OP_HOME/.local/lib/tode/vendor/terminal-browser/electron/electron" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')"
  [ -z "$missing" ] || warn "  tode: missing system libraries: $missing"
}

install_integrations() {
  local i dir
  for i in "${INTEGRATIONS[@]}"; do
    case "$i" in claude) dir=.claude ;; codex) dir=.codex ;; grok) dir=.grok ;; esac
    install -d -m 0755 -o "$OP_USER" -g "$OP_USER" "$OP_HOME/$dir"
    command -v "$i" >/dev/null 2>&1 || { warn "  integration $i skipped ($i CLI not on the host — sudo $STACK_DIR/orca.sh install puts claude/codex/grok in /usr/local/bin)"; continue; }
    hd integration install "$i" >/dev/null 2>&1 && info "  integration $i" || warn "  integration $i failed (herdr integration install $i as $OP_USER)"
  done
}

write_service() {
  sed -e "s|@USER@|$OP_USER|g" -e "s|@HOME@|$OP_HOME|g" -e "s|@WORKDIR@|$HERMES_WORKSPACE_DIR|g" \
      -e "s|@MEM@|${HERDR_MEM_LIMIT^^}|g" "$STACK_DIR/herdr/herdr.service" > "$HERDR_UNIT"
  systemctl daemon-reload
  systemctl enable -q herdr
}

start_server() {
  if systemctl is-active -q herdr; then
    info "herdr.service already running (panes kept)"
  else
    # A server started by hand from an SSH session owns the socket: let it be.
    if server_up; then warn "a herdr server is already running outside systemd — kept (stop it with: herdr server stop, then sudo systemctl start herdr)"; return 0; fi
    systemctl start herdr
    for _ in $(seq 1 10); do server_up && break; sleep 1; done
    server_up || { journalctl -u herdr -n 30 --no-pager -o cat; die "herdr server did not come up"; }
    info "herdr.service started"
  fi
}

do_install() {
  install_deps
  install_herdr
  write_config
  write_bashrc
  sync_creds
  install_plugin
  install_integrations
  write_service
  start_server
  # herdr-config: committed config, one workspace per repo, pinned plugins. Without it (not
  # cloned yet: needs the operator's gh login), one workspace rooted at the shared workspace.
  if clone_config; then
    as_op "$HERDR_CONFIG_DIR/bin/herdr-apply" all || warn "herdr-apply failed: sudo $0 apply"
  elif [ "$(hd workspace list 2>/dev/null | grep -o '"workspace_id"' | wc -l)" = 0 ]; then
    hd workspace create --cwd "$HERMES_WORKSPACE_DIR" --label workspace --no-focus >/dev/null 2>&1 || true
  fi
  do_status
  cat <<MSG

  herdr is ready for $OP_USER:
    ssh $OP_USER@<tailscale-ip>      then: herdr          (detach: ctrl+b q — panes keep running)
    herdr --remote $OP_USER@<tailscale-ip>                  (from a laptop with herdr installed)
  VS Code in a pane: \`tode\` in any folder, or the "Open terminal-code (right split)" action
  (terminal must support the kitty graphics protocol: Ghostty, kitty, WezTerm; run \`tode --shortcut-setup\` once).
  Coding CLIs on the host use $OP_HOME logins: sudo $0 creds (copy the agent's) or sudo $0 login claude|codex|grok|gh.
MSG
}

do_update() {
  installed || die "herdr is not installed: sudo $0 install"
  local before after
  before="$(hd --version | awk '{print $2}')"
  cp -p "$HERDR_BIN" "$HERDR_BIN.previous"
  hd update >/dev/null 2>&1 || warn "herdr update failed"
  if ! hd --version >/dev/null 2>&1; then
    mv -f "$HERDR_BIN.previous" "$HERDR_BIN"
    warn "the new herdr binary does not start → herdr $before restored"
    notify "herdr.sh: the herdr update produced a binary that does not start — herdr $before restored"
  fi
  after="$(hd --version | awk '{print $2}')"
  info "herdr $before → $after"
  as_op sh -c 'command -v tode >/dev/null && tode --upgrade' >/dev/null 2>&1 || warn "tode --upgrade failed (plugin: herdr plugin install $TODE_PLUGIN --yes)"
  # The running server keeps its version (herdr's own policy); restart only on request — it ends every pane.
  if [ "$before" != "$after" ] && [ "${1:-}" = --restart ]; then systemctl restart herdr; info "herdr.service restarted"
  elif [ "$before" != "$after" ]; then info "server still on $before until: sudo $0 restart (ends running panes)"; fi
}

# Back to the binary that ran before the last update (kept by do_update); the server switches at its next restart.
do_rollback() {
  [ -x "$HERDR_BIN.previous" ] || die "no previous herdr binary kept ($HERDR_BIN.previous)"
  local cur; cur="$(hd --version 2>/dev/null | awk '{print $2}')"
  cp -p "$HERDR_BIN" "$HERDR_BIN.rollback" 2>/dev/null || true
  mv -f "$HERDR_BIN.previous" "$HERDR_BIN"
  mv -f "$HERDR_BIN.rollback" "$HERDR_BIN.previous" 2>/dev/null || true
  info "herdr ${cur:-?} → $(hd --version | awk '{print $2}') (running server: sudo $0 restart, ends running panes)"
}

# herdr-config (HERDR_CONFIG_DIR) is cloned as the operator; it lives in the workspace, so it is
# only ever run as the operator (herdr-apply applies its committed files), never as root.
clone_config() {
  [ -d "$HERDR_CONFIG_DIR/.git" ] && return 0
  info "Cloning $HERDR_CONFIG_REPO → $HERDR_CONFIG_DIR (as $OP_USER)…"
  as_op git clone -q "$HERDR_CONFIG_REPO" "$HERDR_CONFIG_DIR" && return 0
  warn "clone failed — log in as $OP_USER first: sudo $0 login gh"
  return 1
}

do_apply() {
  installed || die "herdr is not installed: sudo $0 install"
  clone_config || exit 1
  as_op "$HERDR_CONFIG_DIR/bin/herdr-apply" "${@:-all}"
}

do_login() {
  [ -t 0 ] || die "login needs a terminal"
  case "${1:-}" in
    claude) as_op claude auth login ;;
    codex)  as_op codex login --device-auth ;;
    grok)   as_op grok login --device-auth ;;
    gh)     as_op gh auth login --web --git-protocol https && as_op gh auth setup-git ;;
    *) die "usage: $0 login claude|codex|grok|gh" ;;
  esac
}

do_status() {
  if ! installed; then echo "herdr: not installed (sudo $0 install)"; return 0; fi
  echo "herdr $(hd --version | awk '{print $2}') · $HERDR_BIN · herdr.service: $(systemctl is-active herdr 2>/dev/null || echo n/a) · server: $(server_up && echo running || echo down)"
  echo "user $OP_USER · HOME=$OP_HOME · new_cwd $(sed -n 's/^new_cwd *= *"\(.*\)"/\1/p' "$HERDR_CFG_DIR/config.toml" 2>/dev/null | head -n1) · config $([ -d "$HERDR_CONFIG_DIR/.git" ] && echo "$HERDR_CONFIG_DIR" || echo "herdr-config not cloned")"
  echo "plugins: $(hd plugin list 2>/dev/null | sed -n 's/^- \([^ ]*\) .* \(enabled\|disabled\).*/\1 (\2)/p' | tr '\n' ' ')"
  echo "tode: $(as_op sh -c 'tode --version 2>/dev/null | head -n1' || echo missing)"
  hd integration status 2>/dev/null | sed 's/^/  /' | head -n 25 || true
  local f; for f in "${CRED_FILES[@]}"; do [ -f "$OP_HOME/$f" ] && echo "  login: $f" || echo "  no login: $f"; done
}

do_remove() {
  systemctl disable --now herdr 2>/dev/null || true
  rm -f "$HERDR_UNIT"; systemctl daemon-reload
  if installed; then hd plugin uninstall "$TODE_PLUGIN_ID" >/dev/null 2>&1 || true; fi
  as_op sh -c 'command -v tode >/dev/null && tode --uninstall --yes' >/dev/null 2>&1 || true
  rm -f "$HERDR_BIN"
  info "herdr removed (binary, plugin, tode, herdr.service). Kept: $HERDR_CFG_DIR, logins, ~/.bashrc block."
}

case "${1:-}" in
  install) do_install ;;
  update)  do_update "${2:-}" ;;
  rollback) do_rollback ;;
  creds)   sync_creds --force ;;
  login)   do_login "${2:-}" ;;
  apply)   shift; do_apply "$@" ;;
  status)  do_status ;;
  logs)    journalctl -u herdr -f -o cat ;;
  restart) systemctl restart herdr; info "herdr.service restarted (panes restored from the saved layout)" ;;
  remove)  do_remove ;;
  *) die "usage: $0 install | update [--restart] | rollback | creds | login <claude|codex|grok|gh> | apply [all|config|workspaces|plugins|diff] | status | logs | restart | remove" ;;
esac
