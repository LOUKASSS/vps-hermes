#!/usr/bin/env bash
# Interactive OAuth logins for the Hermes stack. Runs commands inside the running
# hermes-agent container as the runtime user with HOME=/opt/data/home, so tokens
# persist on the host under $HERMES_DATA_DIR/home and are visible to agent tool calls.
#
#   sudo ./auth.sh                 # menu
#   sudo ./auth.sh <target>        # hermes | claude | claude-token | codex | grok | gh | obsidian | status | shell
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
    info "Stored in $envf. Restart the gateway to pick it up: docker compose restart hermes-agent"
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
}

do_status() {
  agent_run sh -c '
    echo "── hermes providers ──"; hermes auth list 2>&1 || true; hermes config get model 2>&1 || true
    echo; echo "── claude ──"; claude auth status --text 2>&1 || echo "not logged in"
    echo; echo "── codex ──"; codex login status 2>&1 || echo "not logged in"
    echo; echo "── grok ──"; [ -f "$HOME/.grok/auth.json" ] && echo "auth.json present" || echo "not logged in"
    echo; echo "── gh ──"; gh auth status 2>&1 || true
'
  echo; echo "── obsidian ──"
  if [ "${COMPOSE_PROFILES:-}" = obsidian ]; then
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
  if grep -q '^COMPOSE_PROFILES=' "$STACK_DIR/.env"; then
    sed -i 's|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=obsidian|' "$STACK_DIR/.env"
  else
    printf 'COMPOSE_PROFILES=obsidian\n' >> "$STACK_DIR/.env"
  fi
  export COMPOSE_PROFILES=obsidian
  compose up -d obsidian-sync
  info "obsidian-sync started. Status: docker compose logs -f obsidian-sync  |  ./auth.sh status"
}

do_shell() { agent_exec bash; }

run_target() {
  case "$1" in
    1|hermes) do_hermes ;; 2|claude) do_claude ;; 3|claude-token) do_claude_token ;;
    4|codex) do_codex ;; 5|grok) do_grok ;; 6|gh) do_gh ;;
    7|obsidian) do_obsidian ;;
    8|status) do_status ;; 9|shell) do_shell ;;
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
  6) gh            GitHub CLI        (gh auth login --web)
  7) obsidian      Obsidian Sync    (ob login + ob sync-setup, starts the obsidian-sync sidecar)
  8) status        Show login state
  9) shell         Shell inside the agent container
  q) quit
MENU
  read -r -p "> " choice
  run_target "$choice" || warn "unknown choice: $choice"
}

if [ -n "${1:-}" ]; then
  run_target "$1" || die "usage: $0 [hermes|claude|claude-token|codex|grok|gh|obsidian|status|shell]"
else
  while true; do menu; echo; done
fi
