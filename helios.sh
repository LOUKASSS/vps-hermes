#!/usr/bin/env bash
# Helios (dashboard + tinyauth + fitness collector) — its own compose project (`loukass`) behind
# the platform's Traefik (joins the `proxy` network). Code and deployment are split:
#
#   HELIOS_SRC  = $HERMES_WORKSPACE_DIR/projects/helios   git repo: compose.yaml, deploy.sh, sources
#                 (the agent, Orca and herdr all edit it there — same path everywhere)
#   HELIOS_DIR  = /srv/helios                              deployment: .env (secrets), tinyauth/data
#
# The repo's own deploy.sh does the work (bws secrets, fitness profile, watchlist CLI sync); this
# wrapper runs it as the operator with the deployment's .env and state directory.
#
#   sudo ./helios.sh deploy            # build + (re)start (one click)
#   sudo ./helios.sh status | ps | logs [svc] | down | restart | config
#   sudo ./helios.sh compose <args…>   # raw docker compose on the Helios project
#
# HOME for deploy.sh = HELIOS_CLI_HOME (default ORCA_HOME): fitness-sync mounts that HOME's
# .claude / .codex / .grok read-only for its quota panel, and deploy.sh reads the bws binary and
# token from $HOME/.hermes/ (override with BWS / HERMES_ENV in $HELIOS_DIR/.env).
# Treat the workspace as untrusted for this step: compose.yaml there is what gets deployed.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
: "${HELIOS_CLI_HOME:=$ORCA_HOME}"

HELIOS_ENV="$HELIOS_DIR/.env"

check_layout() {
  [ -f "$HELIOS_SRC/compose.yaml" ] || die "Helios code not found at $HELIOS_SRC (git clone https://github.com/LOUKASSS/helios.git $HELIOS_SRC)"
  [ -f "$HELIOS_ENV" ] || die "missing $HELIOS_ENV — cp $HELIOS_SRC/.env.example $HELIOS_ENV and fill it in"
  install -d -m 0755 -o "$HERMES_UID" -g "$HERMES_GID" "$HELIOS_DIR" "$HELIOS_DIR/tinyauth" "$HELIOS_DIR/tinyauth/data"
  chown "$HERMES_UID:$HERMES_GID" "$HELIOS_ENV"; chmod 600 "$HELIOS_ENV"
  docker network inspect proxy >/dev/null 2>&1 || die "docker network 'proxy' missing — deploy the platform first: sudo $STACK_DIR/command-center deploy hermes"
}

# run_deploy [compose args…] — the repo's deploy.sh with the deployment's env and state.
run_deploy() {
  local -a extra=()
  [ -n "${BWS:-}" ] && extra+=(BWS="$BWS")
  [ -n "${HERMES_ENV:-}" ] && extra+=(HERMES_ENV="$HERMES_ENV")
  as_op_home "$HELIOS_CLI_HOME" env HELIOS_ENV_FILE="$HELIOS_ENV" HELIOS_STATE_DIR="$HELIOS_DIR" \
    "${extra[@]}" bash -c 'cd "$1" && shift && exec ./deploy.sh "$@"' _ "$HELIOS_SRC" "$@"
}

do_status() {
  echo "code       : $HELIOS_SRC $( [ -d "$HELIOS_SRC/.git" ] && git -C "$HELIOS_SRC" -c safe.directory='*' log -1 --format='(%h %s)' 2>/dev/null)"
  echo "deployment : $HELIOS_DIR  (.env $( [ -f "$HELIOS_ENV" ] && echo present || echo MISSING), tinyauth/data $( [ -d "$HELIOS_DIR/tinyauth/data" ] && echo present || echo missing))"
  docker ps -a --filter label=com.docker.compose.project=loukass --format '  {{.Names}}\t{{.Status}}' || true
  local d h
  d="$(sed -n 's/^DOMAIN=\([^[:space:]#]*\).*/\1/p' "$HELIOS_ENV" 2>/dev/null | head -n1)"
  h="$(sed -n 's/^DASHBOARD_HOST=\([^[:space:]#]*\).*/\1/p' "$HELIOS_ENV" 2>/dev/null | head -n1)"
  [ -z "$d" ] || echo "urls       : https://${h:-dashboard.$d}  https://auth.$d"
}

case "${1:-}" in
  deploy)  check_layout; shift; run_deploy "$@" ;;
  status)  do_status ;;
  ps)      check_layout; run_deploy ps ;;
  logs)    check_layout; shift; run_deploy logs -f --tail=100 "$@" ;;
  down)    check_layout; run_deploy down ;;
  restart) check_layout; run_deploy restart ;;
  config)  check_layout; run_deploy config ;;
  compose) check_layout; shift; run_deploy "$@" ;;
  *) die "usage: $0 deploy | status | ps | logs [svc] | down | restart | config | compose <args…>" ;;
esac
