#!/usr/bin/env bash
# Interactive OAuth logins for the Hermes stack. Agent-side commands run inside the
# running hermes-agent container as the runtime user with HOME=/opt/data/home, so
# tokens persist on the host under $HERMES_DATA_DIR/home. GitHub is shared through
# the container-wide GH_CONFIG_DIR and GIT_CONFIG_GLOBAL settings.
# Coding CLIs (claude, codex, grok) log in on the host: sudo ./orca.sh login …
#
#   sudo ./auth.sh                 # menu
#   sudo ./auth.sh <target>        # hermes | gh | messaging | obsidian | status | shell | chat
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

# Retired names must not require hermes-agent (they only print the orca.sh pointer).
# Everything but obsidian/status runs inside the agent container.
case "${1:-}" in 4|obsidian|5|status|claude|claude-token|codex|grok) ;; *)
  running="$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null || echo false)"
  [ "$running" = true ] || die "hermes-agent is not running. Run ./install.sh or: docker compose up -d" ;;
esac

do_hermes() {
  info "Hermes model provider — pick 'Anthropic' (Claude Max OAuth), 'ChatGPT or Codex Subscription', or 'xAI Grok OAuth (SuperGrok / Premium+)'."
  info "Device-code / paste-code flows: open the printed URL on your laptop, paste the code back here."
  agent_exec hermes model
}

do_gh() {
  info "GitHub CLI login (device flow; container gh — Orca has its own: sudo $STACK_DIR/orca.sh login gh)."
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
  if [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null)" != true ]; then
    echo "── hermes-agent is NOT running (logins not shown): docker compose ps ──"
  else agent_run sh -c '
    echo "── hermes providers ──"; hermes auth list 2>&1 || true; hermes config get model 2>&1 || true
    echo; echo "── gh ──"; gh auth status 2>&1 || true
    echo "git identity: $(git config --global user.name 2>/dev/null || echo unset) <$(git config --global user.email 2>/dev/null || echo unset)>"
    echo; echo "── messaging ──"; hermes gateway status 2>&1 | head -n 20 || true
'
  fi
  echo; echo "── updates ──"
  if [ -e "$UPDATE_HOLD" ]; then echo "ON HOLD since $(cat "$UPDATE_HOLD") (after a rollback) — sudo $STACK_DIR/update.sh resume"
  elif systemctl is-enabled -q hermes-update.timer 2>/dev/null; then echo "automatic (Sunday 03:30)"
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
  echo "hermes-postgres: $(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' hermes-postgres 2>/dev/null || echo 'not created')  db ${POSTGRES_DB} user ${POSTGRES_USER} → ${DESKTOP_BIND:-?}:${POSTGRES_PORT:-5432} (tailnet), hermes-postgres:5432 (agent)  last dump: $(ls -1t "$POSTGRES_DIR"/dumps/pg_dumpall-*.sql.gz 2>/dev/null | head -n1 | xargs -r basename)"
  echo; echo "── dns ──"
  echo "hermes-dns: $(docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' hermes-dns 2>/dev/null || echo 'not created')  ${DNS_ZONE:-$HERMES_HOST} + *.${DNS_ZONE:-$HERMES_HOST} → ${DESKTOP_BIND:-?}:53  (Tailscale split DNS → this IP, restricted to that domain)"
  echo; echo "── orca (host) ──"
  if [ -e /opt/orca/current ]; then
    _orca_user="$(systemctl show orca -p User --value 2>/dev/null || true)"
    echo "orca.service: $(systemctl is-active orca 2>/dev/null)  version $(cat /opt/orca/current/VERSION 2>/dev/null || echo ?)  → ${DESKTOP_BIND:-?}:${ORCA_PORT:-6768}  ${_orca_user:+user $_orca_user, }HOME $ORCA_HOME  (details: $STACK_DIR/orca.sh status)"
  else
    echo "not installed (run: sudo $STACK_DIR/orca.sh install)"
  fi
  echo "coding CLIs: sudo $STACK_DIR/orca.sh login claude|codex|grok  (not in the agent container)"
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
  info "Vault: host $HERMES_WORKSPACE_DIR/$OBSIDIAN_VAULT_DIR  = agent /workspace/$OBSIDIAN_VAULT_DIR  = sync client /vault"
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
# Interactive Hermes CLI in the agent container: same config, sessions and /workspace as the
# gateway. Extra args go to `hermes chat` (e.g. --tui, --resume <session>, -m <model>).
do_chat() { shift; agent_exec hermes chat "$@"; }

# Validate first, then run the target plainly: `run_target … || …` would switch `set -e` off
# inside every do_* (a failed login would fall through to the next step).
is_target() {
  case "$1" in
    1|hermes|2|gh|3|messaging|4|obsidian|5|status|6|shell|7|chat|q|Q|quit) ;;
    claude|claude-token|codex|grok) ;;
    *) return 1 ;;
  esac
}
run_target() {
  case "$1" in
    1|hermes) do_hermes ;;
    2|gh) do_gh ;;
    3|messaging) do_messaging ;;
    4|obsidian) do_obsidian ;;
    5|status) do_status ;;
    6|shell) do_shell ;;
    7|chat) do_chat "$@" ;;
    claude|claude-token|codex|grok) die "coding CLIs live on the host: sudo $STACK_DIR/orca.sh login claude|codex|grok" ;;
    q|Q|quit) exit 0 ;;
  esac
}

menu() {
  cat <<MENU
Hermes stack — auth

  1) hermes        Hermes model provider (Claude Max / ChatGPT-Codex / SuperGrok OAuth)
  2) gh            GitHub CLI        (gh auth login --web + git identity)
  3) messaging     Telegram / Discord / Slack / WhatsApp… (hermes gateway setup)
  4) obsidian      Obsidian Sync     (ob login + ob sync-setup, starts the obsidian-sync sidecar)
  5) status        Show login state
  6) shell         Shell inside the agent container
  7) chat          Hermes CLI chat inside the agent container (hermes chat)
  q) quit

  Coding CLIs (claude / codex / grok): sudo ./orca.sh login claude|codex|grok
MENU
  read -r -p "> " choice
  is_target "$choice" || die "unknown choice: $choice"
  run_target "$choice"
}

if [ -n "${1:-}" ]; then
  is_target "$1" || die "usage: $0 [hermes|gh|messaging|obsidian|status|shell|chat [hermes chat args]]"
  run_target "$@"
else
  while true; do menu; echo; done
fi
