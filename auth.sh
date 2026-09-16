#!/usr/bin/env bash
# Interactive OAuth logins for the Hermes stack. Runs commands inside the running
# hermes-agent container as the runtime user with HOME=/opt/data/home, so tokens
# persist on the host under $HERMES_DATA_DIR/home and are visible to agent tool calls.
#
#   sudo ./auth.sh                 # menu
#   sudo ./auth.sh <target>        # hermes | claude | claude-token | codex | grok | gh | messaging | obsidian | orca | status | shell
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

running="$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)"
[ "$running" = true ] || die "hermes-agent is not running. Run ./install.sh or: docker compose up -d"

do_hermes() {
  info "Hermes model provider — pick 'Anthropic' (Claude Max OAuth), 'ChatGPT or Codex Subscription', or 'xAI Grok OAuth (SuperGrok / Premium+)'."
  info "Device-code / paste-code flows: open the printed URL on your laptop, paste the code back here."
  agent_exec hermes model
}

do_claude() {
  info "Claude Code login with your Claude subscription. Open the printed URL on your laptop, paste the code back."
  info "Credentials land in /opt/data/home/.claude/.credentials.json — Hermes' anthropic provider reuses them (refreshable)."
  agent_exec claude auth login
}

do_claude_token() {
  info "Alternative: long-lived token via 'claude setup-token' (Claude Max). Open the URL on your laptop, approve, paste the code back."
  agent_exec claude setup-token
  echo
  read -r -p "Paste the token here to store it as CLAUDE_CODE_OAUTH_TOKEN for Hermes (Enter to skip): " tok
  if [ -n "$tok" ]; then
    envf="$HERMES_DATA_DIR/.env"
    touch "$envf"; chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
    if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$envf"; then
      sed -i "s|^CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${tok}|" "$envf"
    else
      printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$tok" >> "$envf"
    fi
    info "Stored in $envf. Apply with: docker compose up -d --force-recreate hermes-agent"
  fi
}

do_codex() {
  info "Codex CLI device-code login (ChatGPT Plus/Pro/Team). Hermes imports ~/.codex/auth.json automatically."
  agent_exec codex login --device-auth
}

do_grok() {
  info "Grok CLI device-code login (SuperGrok / X Premium+). Open the printed URL on your laptop."
  agent_exec grok login --device-auth
}

do_gh() {
  info "GitHub CLI login (device flow)."
  agent_exec gh auth login --web --git-protocol https
  # git pushes over https reuse the gh token; commits need an identity (~/.gitconfig persists under /opt/data/home).
  agent_run gh auth setup-git || warn "gh auth setup-git failed — git push will prompt for credentials"
  local cur_name cur_email name email
  cur_name="$(agent_run git config --global user.name 2>/dev/null || true)"
  cur_email="$(agent_run git config --global user.email 2>/dev/null || true)"
  read -r -p "Git user.name  [${cur_name:-unset}]: " name
  read -r -p "Git user.email [${cur_email:-unset}]: " email
  [ -n "$name" ]  && agent_run git config --global user.name "$name"
  [ -n "$email" ] && agent_run git config --global user.email "$email"
  agent_run git config --global --get-regexp '^user\.' || warn "no git identity set: the agent cannot commit until you set one"
}

do_messaging() {
  info "Messaging platforms (Telegram, Discord, Slack, WhatsApp, …). Interactive wizard; tokens land in /opt/data/.env."
  info "Bots use outbound polling/websockets — nothing to open in the firewall."
  agent_exec hermes gateway setup
  echo
  read -r -p "Recreate the gateway now to apply the new platforms? [Y/n] " a
  case "${a:-y}" in
    [yY]*) restart_agent ;;
    *) info "Later: cd $STACK_DIR && docker compose up -d --force-recreate hermes-agent" ;;
  esac
}

do_status() {
  agent_run sh -c '
    echo "── hermes providers ──"; hermes auth list 2>&1 || true; hermes config get model 2>&1 || true
    echo; echo "── claude ──"; claude auth status --text 2>&1 || echo "not logged in"
    echo; echo "── codex ──"; codex login status 2>&1 || echo "not logged in"
    echo; echo "── grok ──"; [ -f "$HOME/.grok/auth.json" ] && echo "auth.json present" || echo "not logged in"
    echo; echo "── gh ──"; gh auth status 2>&1 || true
    echo "git identity: $(git config --global user.name 2>/dev/null || echo unset) <$(git config --global user.email 2>/dev/null || echo unset)>"
    echo; echo "── messaging ──"; hermes gateway status 2>&1 | head -n 20 || true
'
  echo; echo "── backups ──"
  if [ -n "${RESTIC_PASSWORD:-}" ]; then
    echo "repository: ${RESTIC_REPOSITORY}"
    if systemctl list-timers hermes-backup.timer --no-pager 2>/dev/null | grep -q hermes-backup; then
      systemctl list-timers hermes-backup.timer --no-pager | sed -n 2p
      echo "last run: $(journalctl -u hermes-backup -n 1 --no-pager -o cat 2>/dev/null || echo none)"
    else
      echo "timer not installed (run ./install.sh)"
    fi
  else
    echo "not configured (run: $STACK_DIR/backup.sh setup)"
  fi
  echo; echo "── orca ──"
  if [[ ",${COMPOSE_PROFILES:-}," == *,orca,* ]]; then
    echo "server: $(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' orca 2>/dev/null || echo 'not created')  → ${DESKTOP_BIND:-?}:6768  (pairing link: $0 orca)"
  else
    echo "not enabled (run: $0 orca)"
  fi
  echo; echo "── obsidian ──"
  if [[ ",${COMPOSE_PROFILES:-}," == *,obsidian,* ]]; then
    docker inspect -f 'sidecar: {{.State.Status}}' obsidian-sync 2>/dev/null || echo "sidecar: not created"
    compose --profile obsidian run --rm --no-deps -T obsidian-sync sync-status --path /vault 2>&1 || true
  else
    echo "not configured (run: $0 obsidian)"
  fi
}

do_obsidian() {
  info "Obsidian Sync headless client (requires an Obsidian Sync subscription)."
  info "Vault: host $HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR  = agent /workspace/$OBSIDIAN_VAULT_DIR  = sync client /vault"
  mkdir -p "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$OBSIDIAN_DIR"
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$OBSIDIAN_DIR"
  compose --profile obsidian build --pull obsidian-sync
  obsidian_exec login
  echo
  info "Remote vaults:"; obsidian_exec sync-list-remote || true
  echo
  info "Linking /vault to a remote vault (prompts for vault + E2E password)."
  info "No remote vault yet? Ctrl+C and run: docker compose --profile obsidian run --rm obsidian-sync sync-create-remote"
  obsidian_exec sync-setup --path /vault --device-name "hermes-vps"
  # Enable the sidecar profile persistently and start it.
  enable_profile obsidian
  compose up -d obsidian-sync
  info "obsidian-sync started. Status: docker compose logs -f obsidian-sync  |  ./auth.sh status"
}

# auth.sh orca [desktop|mobile] — enable the Orca remote server, print the pairing link.
# Orca prints ONE pairing link per run: the runtime link (desktop app) by default, or a
# mobile-scoped QR/link with --mobile-pairing. Already-paired devices keep their own tokens, so
# switching modes to pair another device is safe.
do_orca() {
  local mode="${1:-desktop}" pairing=""
  case "$mode" in
    desktop) pairing="" ;;
    mobile)  pairing="--mobile-pairing" ;;
    *) die "usage: $0 orca [desktop|mobile]" ;;
  esac
  info "Orca remote server on the Tailscale IP (${DESKTOP_BIND:-?}:6768), same /workspace + CLI logins as the agent."
  set_env ORCA_PAIRING "$pairing"; export ORCA_PAIRING="$pairing"
  enable_profile orca
  compose build orca
  compose up -d orca
  info "Waiting for Orca (up to 2 min)…"
  wait_healthy orca 120 || { compose logs --tail=30 orca; die "orca not healthy"; }
  local url web
  url="$(compose logs --no-log-prefix orca 2>/dev/null | grep -o 'orca://pair[^ ]*' | tail -n1)"
  web="$(compose logs --no-log-prefix orca 2>/dev/null | grep -o 'http://[^ ]*web-index.html[^ ]*' | tail -n1)"
  # Mobile mode prints a QR (ANSI block art) between "Mobile pairing QR:" and "Pairing URL:".
  compose logs --no-log-prefix orca 2>/dev/null | sed -n '/pairing QR:/I,/^Pairing URL:/{/^Pairing URL:/!p}' | tail -n 60 || true
  cat <<MSG

  Mode          : $mode pairing   (other device type: sudo $0 orca $([ "$mode" = mobile ] && echo desktop || echo mobile))
  Pairing link  : ${url:-<not found — docker compose logs orca>}
  Browser client: ${web:-n/a}
  Desktop app   : Settings → Remote Orca Servers → Add Server → paste the link
  Mobile app    : scan the QR above / open the link on the phone (must be on the tailnet)

Treat the link like a password (revocable under Shared Server Access in the app).
MSG
}

do_shell() { agent_exec bash; }

run_target() {
  case "$1" in
    1|hermes) do_hermes ;; 2|claude) do_claude ;; 3|claude-token) do_claude_token ;;
    4|codex) do_codex ;; 5|grok) do_grok ;; 6|gh) do_gh ;;
    7|messaging) do_messaging ;; 8|obsidian) do_obsidian ;;
    9|orca) do_orca "${2:-desktop}" ;;
    10|status) do_status ;; 11|shell) do_shell ;;
    q|Q|quit) exit 0 ;;
    *) return 1 ;;
  esac
}

menu() {
  cat <<MENU
Hermes stack — auth

  1) hermes        Hermes model provider (Claude Max / ChatGPT-Codex / SuperGrok OAuth)
  2) claude        Claude Code CLI   (claude auth login — subscription)
  3) claude-token  Claude Code CLI   (claude setup-token → CLAUDE_CODE_OAUTH_TOKEN)
  4) codex         Codex CLI         (codex login --device-auth)
  5) grok          Grok CLI          (grok login --device-auth)
  6) gh            GitHub CLI        (gh auth login --web + git identity)
  7) messaging     Telegram / Discord / Slack / WhatsApp… (hermes gateway setup)
  8) obsidian      Obsidian Sync     (ob login + ob sync-setup, starts the obsidian-sync sidecar)
  9) orca          Orca remote server (claude/codex/grok from the Orca desktop/mobile app) — pairing link
 10) status        Show login state
 11) shell         Shell inside the agent container
  q) quit
MENU
  read -r -p "> " choice
  run_target "$choice" || warn "unknown choice: $choice"
}

if [ -n "${1:-}" ]; then
  run_target "$@" || die "usage: $0 [hermes|claude|claude-token|codex|grok|gh|messaging|obsidian|orca [desktop|mobile]|status|shell]"
else
  while true; do menu; echo; done
fi
