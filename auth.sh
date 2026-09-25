#!/usr/bin/env bash
# Interactive OAuth logins for the Hermes stack. Commands run on the host as the Hermes runtime
# user with its environment (/etc/hermes/agent.env) and HOME=/opt/data/home, so tokens land under
# $HERMES_DATA_DIR/home — the agent's own logins, separate from the operator's /home/hermes.
# GitHub is shared through GH_CONFIG_DIR and GIT_CONFIG_GLOBAL (agent.env).
#
#   sudo ./auth.sh                 # menu
#   sudo ./auth.sh <target>        # hermes | claude | claude-token | codex | grok | gh | messaging | obsidian | status | shell | chat
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

# Everything but obsidian/status runs as the agent: needs an installed release and its env.
case "${1:-}" in 8|obsidian|9|status) ;; *)
  [ -e "$HERMES_CURRENT/.release" ] && [ -r "$AGENT_ENV" ] \
    || die "Hermes is not installed on the host (sudo command-center hermes status)" ;;
esac

do_hermes() {
  info "Hermes model provider — pick 'Anthropic' (Claude Max OAuth), 'ChatGPT or Codex Subscription', or 'xAI Grok OAuth (SuperGrok / Premium+)'."
  info "Device-code / paste-code flows: open the printed URL on your laptop, paste the code back here."
  agent_exec hermes model
}

do_claude() {
  local envf
  info "Claude Code login with your Claude subscription. Open the printed URL on your laptop, paste the code back."
  info "Credentials land in /opt/data/home/.claude/.credentials.json. Its refresh token rotates: never copy that"
  info "file to another HOME (Orca / herdr log in on their own). Sturdier for Hermes: $0 claude-token."
  agent_exec env CLAUDE_CONFIG_DIR=/opt/data/home/.claude claude auth login
  envf="$HERMES_DATA_DIR/.env"
  no_symlink "$envf"
  touch "$envf"; chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
  # The two Claude auth paths are alternatives. A setup-token takes precedence over the
  # credential file, so leaving an old one here makes a successful browser login still fail.
  sed -i '/^CLAUDE_CODE_OAUTH_TOKEN=/d' "$envf"
  set_env CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR /opt/data/home/.claude "$envf"
  chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
  info "Claude subscription login selected for Hermes. Apply it: sudo command-center hermes restart"
}

do_claude_token() {
  local envf tok
  info "Recommended for Hermes: long-lived token (1 year) via 'claude setup-token' — nothing to refresh, so no"
  info "rotation to lose. Open the URL on your laptop, approve, paste the code back."
  agent_exec claude setup-token
  echo
  read -r -s -p "Paste the token here to store it as CLAUDE_CODE_OAUTH_TOKEN for Hermes (Enter to skip): " tok; echo
  if [ -n "$tok" ]; then
    envf="$HERMES_DATA_DIR/.env"
    no_symlink "$envf"
    touch "$envf"; chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
    # setup-token is an alternative to the CLI credential directory, not an overlay on it.
    sed -i '/^CLAUDE_SUBSCRIPTION_DIRECTSDK_CONFIG_DIR=/d' "$envf"
    set_env CLAUDE_CODE_OAUTH_TOKEN "$tok" "$envf"
    chown "$HERMES_UID:$HERMES_GID" "$envf"; chmod 600 "$envf"
    info "Stored in $envf. Apply it: sudo command-center hermes restart"
  fi
}

do_codex() {
  info "Codex CLI device-code login (ChatGPT Plus/Pro/Team)."
  agent_exec codex login --device-auth
}

do_grok() {
  info "Grok CLI device-code login (SuperGrok / X Premium+). Open the printed URL on your laptop."
  agent_exec grok login --device-auth
}

do_gh() {
  info "GitHub CLI login (device flow; the agent's gh — Orca has its own: sudo $STACK_DIR/orca.sh login gh)."
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
    *) info "Later: sudo command-center hermes restart" ;;
  esac
}

do_status() {
  if ! agent_running; then
    echo "── Hermes is NOT running (logins not shown): sudo command-center hermes status ──"
  else agent_run sh -c '
    echo "── hermes providers ──"; hermes auth list 2>&1 || true; hermes config get model 2>&1 || true
    echo; echo "── claude ──"
    # What the DirectSDK provider uses: a setup-token in /opt/data/.env wins over the credential file.
    if grep -q "^CLAUDE_CODE_OAUTH_TOKEN=." /opt/data/.env 2>/dev/null; then echo "Hermes uses: CLAUDE_CODE_OAUTH_TOKEN (setup-token, no refresh)"
    else echo "Hermes uses: $HOME/.claude/.credentials.json (rotating refresh token — auth.sh claude-token is sturdier)"; fi
    CLAUDE_CONFIG_DIR="$HOME/.claude" claude auth status --text 2>&1 || echo "not logged in"
    echo; echo "── codex ──"; codex login status 2>&1 || echo "not logged in"
    echo; echo "── grok ──"; [ -f "$HOME/.grok/auth.json" ] && echo "auth.json present" || echo "not logged in"
    echo; echo "── gh ──"; gh auth status 2>&1 || true
    echo "git identity: $(git config --global user.name 2>/dev/null || echo unset) <$(git config --global user.email 2>/dev/null || echo unset)>"
    echo; echo "── messaging ──"; hermes gateway status 2>&1 | head -n 20 || true
'
  fi
  echo; echo "── updates ──"
  if [ -e "$UPDATE_HOLD" ]; then echo "ON HOLD since $(cat "$UPDATE_HOLD") (after a rollback) — sudo $STACK_DIR/update.sh resume"
  elif systemctl is-enabled -q hermes-update.timer 2>/dev/null; then echo "automatic (every night, 04:00)$([ -s "$STACK_DIR/state/last-update" ] && echo " — last: $(cat "$STACK_DIR/state/last-update")")"
  else echo "timer disabled (sudo systemctl enable --now hermes-update.timer)"; fi
  [ -e "$MAINTENANCE_FLAG" ] && echo "heal.sh PAUSED ($MAINTENANCE_FLAG exists)"
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
  echo; echo "── dashboard ──"
  # Gate + gateway state as the dashboard reports them on the raw port (same service Traefik serves).
  _st="$(curl -fsS --max-time 5 "http://${DESKTOP_BIND:-127.0.0.1}:${DESKTOP_PORT:-9120}/api/status" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("auth", "on" if d.get("auth_required") else "OFF", d.get("auth_providers"), " gateway", d.get("gateway_state"), " profile", d.get("active_profile") or "default")' 2>/dev/null \
    || echo "not answering")"
  echo "https://${HERMES_HOST:-?}  (raw: http://${DESKTOP_BIND:-?}:${DESKTOP_PORT:-9120})  $_st"
  echo "login: DESKTOP_USERNAME=${DESKTOP_USERNAME:-admin} from .env — unless a secret source in Hermes' config.yaml sets HERMES_DASHBOARD_BASIC_AUTH_*, which wins (README: Dashboard login)"
  echo; echo "── postgres ──"
  echo "hermes-postgres: $(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' hermes-postgres 2>/dev/null || echo 'not created')  db ${POSTGRES_DB} user ${POSTGRES_USER} → ${DESKTOP_BIND:-?}:${POSTGRES_PORT:-5432} (tailnet), 127.0.0.1:${POSTGRES_PORT:-5432} (agent)  last dump: $(ls -1t "$POSTGRES_DIR"/dumps/pg_dumpall-*.sql.gz 2>/dev/null | head -n1 | xargs -r basename)"
  echo; echo "── dns ──"
  echo "hermes-dns: $(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' hermes-dns 2>/dev/null || echo 'not created')  ${DNS_ZONE:-$HERMES_HOST} + *.${DNS_ZONE:-$HERMES_HOST} → ${DESKTOP_BIND:-?}:53  (Tailscale split DNS → this IP, restricted to that domain)"
  echo; echo "── orca (host) ──"
  if [ -e /opt/orca/current ]; then
    _orca_user="$(systemctl show orca -p User --value 2>/dev/null || true)"
    echo "orca.service: $(systemctl is-active orca 2>/dev/null)  version $(cat /opt/orca/current/VERSION 2>/dev/null || echo ?)  → ${DESKTOP_BIND:-?}:${ORCA_PORT:-6768}  ${_orca_user:+user $_orca_user, }HOME $ORCA_HOME  (details: $STACK_DIR/orca.sh status)"
  else
    echo "not installed (run: sudo $STACK_DIR/orca.sh install)"
  fi
  echo "Orca coding CLI logins (separate HOME): sudo $STACK_DIR/orca.sh login claude|codex|grok"
  local f
  for f in .claude/.credentials.json .codex/auth.json .grok/auth.json; do
    if [ -f "$ORCA_HOME/$f" ]; then echo "  $f: present"
    else echo "  $f: missing"; fi
  done
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
  info "Vault: $HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR (host and agent)  = sync client /vault"
  mkdir -p "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$OBSIDIAN_DIR"
  no_symlink "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR"
  chown "$HERMES_UID:$HERMES_GID" "$HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR" "$OBSIDIAN_DIR"
  # Pull (node:22-bookworm-slim after the image cut-over). Today's obsidian-sync:latest is
  # local-only, so a failed pull is OK when the image is already on the host.
  compose --profile obsidian pull obsidian-sync || warn "pull failed; continuing with the local obsidian-sync image"
  # First compose-run before `up -d`: today's ENTRYPOINT is `ob` (extra args = `ob <args>`);
  # after the cut-over the bind-mounted entrypoint installs `ob` into the volume, then execs it.
  obsidian_exec login
  echo
  info "Remote vaults:"; obsidian_exec sync-list-remote || true
  echo
  # `ob sync-setup` needs the vault on the command line (--vault, ID or name from the list above);
  # only the E2E password is prompted. An empty answer creates a new remote vault first.
  local vault
  read -r -e -p "Remote vault to link (ID or name; empty = create a new one): " vault
  if [ -z "$vault" ]; then
    read -r -e -p "New vault name: " vault
    [ -n "$vault" ] || die "vault name is required."
    obsidian_exec sync-create-remote --name "$vault" --encryption end-to-end
  fi
  info "Linking /vault to \"$vault\" (prompts for the E2E password)."
  obsidian_exec sync-setup --vault "$vault" --path /vault --device-name "hermes-vps"
  # Enable the sidecar profile persistently and start it.
  enable_profile obsidian
  compose up -d obsidian-sync
  info "obsidian-sync started. Status: docker compose logs -f obsidian-sync  |  ./auth.sh status"
}

do_shell() { agent_exec bash; }
# Interactive Hermes CLI as the agent: same config, sessions and workspace as the gateway. Extra args go to `hermes chat` (e.g. --tui, --resume <session>, -m <model>).
do_chat() { shift; agent_exec hermes chat "$@"; }

# Validate first, then run the target plainly: `run_target … || …` would switch `set -e` off
# inside every do_* (a failed login would fall through to the next step).
is_target() {
  case "$1" in
    1|hermes|2|claude|3|claude-token|4|codex|5|grok|6|gh|7|messaging|8|obsidian|9|status|10|shell|11|chat|q|Q|quit) ;;
    *) return 1 ;;
  esac
}
run_target() {
  case "$1" in
    1|hermes) do_hermes ;;
    2|claude) do_claude ;;
    3|claude-token) do_claude_token ;;
    4|codex) do_codex ;;
    5|grok) do_grok ;;
    6|gh) do_gh ;;
    7|messaging) do_messaging ;;
    8|obsidian) do_obsidian ;;
    9|status) do_status ;;
    10|shell) do_shell ;;
    11|chat) do_chat "$@" ;;
    q|Q|quit) exit 0 ;;
  esac
}

menu() {
  cat <<MENU
Hermes stack — auth

  1) hermes        Hermes model provider (Claude Max / ChatGPT-Codex / SuperGrok OAuth)
  2) claude        Claude Code CLI   (claude auth login — subscription, rotating refresh token)
  3) claude-token  Claude Code CLI   (claude setup-token → CLAUDE_CODE_OAUTH_TOKEN, 1 year — recommended)
  4) codex         Codex CLI         (codex login --device-auth)
  5) grok          Grok CLI          (grok login --device-auth)
  6) gh            GitHub CLI        (gh auth login --web + git identity)
  7) messaging     Telegram / Discord / Slack / WhatsApp… (hermes gateway setup)
  8) obsidian      Obsidian Sync     (ob login + ob sync-setup, starts the obsidian-sync sidecar)
  9) status        Show login state
 10) shell         Shell as the agent (its env, HOME=/opt/data/home)
 11) chat          Hermes CLI chat (hermes chat)
  q) quit
MENU
  read -r -p "> " choice
  is_target "$choice" || die "unknown choice: $choice"
  run_target "$choice"
}

if [ -n "${1:-}" ]; then
  is_target "$1" || die "usage: $0 [hermes|claude|claude-token|codex|grok|gh|messaging|obsidian|status|shell|chat [hermes chat args]]"
  run_target "$@"
else
  while true; do menu; echo; done
fi
