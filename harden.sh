#!/usr/bin/env bash
# Prepare and isolate a fresh Ubuntu VPS before running install.sh:
#   - operator user `hermes` (sudo NOPASSWD, docker group) with a generated ed25519 key,
#     owner of /srv/hermes (stack in /srv/hermes/stack, data next to it)
#   - Tailscale; SSH + Traefik reachable ONLY through the tailnet
#   - ufw with a DOCKER-USER block so Docker-published ports don't bypass the firewall
#   - unattended-upgrades (security + updates + Docker/Tailscale repos), auto-reboot
#   - sshd hardening, fail2ban, sysctl, journald, Docker daemon defaults
#
#   sudo ./harden.sh [--keep-public-ssh] [--rotate-key] [--keep-key]
#
# Env: TS_AUTHKEY (optional, non-interactive Tailscale login),
#      HARDEN_ASSUME_YES=1 (skip the interactive lockout check — only if you already
#      verified Tailscale access yourself).
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

OP_USER=hermes
KEY_DIR=/root/hermes-ssh
KEY_FILE="$KEY_DIR/${OP_USER}_ed25519"
KEEP_PUBLIC_SSH=0; ROTATE_KEY=0; KEEP_KEY=0
for arg in "$@"; do
  case "$arg" in
    --keep-public-ssh) KEEP_PUBLIC_SSH=1 ;;
    --rotate-key) ROTATE_KEY=1 ;;
    --keep-key) KEEP_KEY=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done

# ── 0. Pre-flight ────────────────────────────────────────────────────────
grep -qi '^ID=ubuntu' /etc/os-release || die "Ubuntu only (found: $(. /etc/os-release; echo "$ID $VERSION_ID"))."
CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$WAN_IF" ] || die "Cannot detect the default (WAN) network interface."
info "Ubuntu $CODENAME — WAN interface: $WAN_IF"

# ── 1. Base packages + full upgrade ──────────────────────────────────────
# needrestart: never prompt, restart services automatically (also used by apt hooks below)
install -d /etc/needrestart/conf.d
printf '$nrconf{restart} = '"'"'a'"'"';\n$nrconf{kernelhints} = -1;\n' > /etc/needrestart/conf.d/90-auto.conf
info "Updating packages…"
apt-get update -q
apt-get -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade
apt-get install -y -q --no-install-recommends \
  ca-certificates curl gnupg lsb-release ufw unattended-upgrades apt-listchanges \
  fail2ban python3-systemd needrestart openssh-server openssl rsync jq sudo git

# ── 2. Operator user + SSH key ───────────────────────────────────────────
if ! id "$OP_USER" >/dev/null 2>&1; then
  info "Creating user $OP_USER"
  # -p '*' = no password, NOT locked (a '!' would make sshd refuse key logins).
  useradd -m -s /bin/bash -p '*' "$OP_USER"
fi
groupadd -f docker
usermod -aG sudo,docker "$OP_USER"
# Validate before installing: a bad fragment in sudoers.d breaks sudo for everyone.
_sudoers="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$OP_USER" > "$_sudoers"
visudo -cf "$_sudoers" >/dev/null || { rm -f "$_sudoers"; die "sudoers fragment for $OP_USER did not validate"; }
install -m 440 -o root -g root "$_sudoers" /etc/sudoers.d/90-"$OP_USER"; rm -f "$_sudoers"

OP_HOME="$(getent passwd "$OP_USER" | cut -d: -f6)"
install -d -m 700 -o "$OP_USER" -g "$OP_USER" "$OP_HOME/.ssh"
touch "$OP_HOME/.ssh/authorized_keys"
chmod 600 "$OP_HOME/.ssh/authorized_keys"; chown "$OP_USER:$OP_USER" "$OP_HOME/.ssh/authorized_keys"

NEW_KEY=0
if [ "$ROTATE_KEY" = 1 ] || [ ! -s "$OP_HOME/.ssh/authorized_keys" ]; then
  info "Generating ed25519 key pair for $OP_USER"
  install -d -m 700 "$KEY_DIR"
  rm -f "$KEY_FILE" "$KEY_FILE.pub"
  ssh-keygen -q -t ed25519 -N '' -C "$OP_USER@$(hostname)-$(date +%Y%m%d)" -f "$KEY_FILE"
  if [ "$ROTATE_KEY" = 1 ]; then : > "$OP_HOME/.ssh/authorized_keys"; fi
  cat "$KEY_FILE.pub" >> "$OP_HOME/.ssh/authorized_keys"
  NEW_KEY=1
else
  info "authorized_keys for $OP_USER already populated — keeping (use --rotate-key to replace)."
fi

# Everything lives under /srv/hermes, owned by the operator: the stack (this repo) in
# /srv/hermes/stack, data dirs next to it (created by install.sh).
HERMES_ROOT=/srv/hermes
install -d -m 755 -o "$OP_USER" -g "$OP_USER" "$HERMES_ROOT"
if [ "$STACK_DIR" != "$HERMES_ROOT/stack" ]; then
  if [ -e "$HERMES_ROOT/stack/.git" ]; then
    warn "$HERMES_ROOT/stack already exists — not overwritten. Update it with 'git pull' there, and re-run harden.sh from there next time."
  else
    info "Copying stack to $HERMES_ROOT/stack"
    rsync -a --delete --exclude .env "$STACK_DIR/" "$HERMES_ROOT/stack/"
    [ -f "$STACK_DIR/.env" ] && [ ! -f "$HERMES_ROOT/stack/.env" ] && cp "$STACK_DIR/.env" "$HERMES_ROOT/stack/.env"
  fi
fi
# Only the stack checkout: data dirs are chowned by install.sh (HERMES_UID) and orca.sh owns
# $HERMES_ROOT/orca — a blanket chown -R here would hand them to the operator on every re-run.
chown "$OP_USER:$OP_USER" "$HERMES_ROOT"
chown -R "$OP_USER:$OP_USER" "$HERMES_ROOT/stack"

# ── 3. Kernel / journald / time ──────────────────────────────────────────
cat > /etc/sysctl.d/90-hardening.conf <<'SYSCTL'
# Hermes VPS hardening
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTL
sysctl -q --system >/dev/null

install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\nMaxRetentionSec=1month\n' > /etc/systemd/journald.conf.d/90-limits.conf
systemctl restart systemd-journald
systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true

# ── 4. Automatic updates ─────────────────────────────────────────────────
info "Configuring unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
cat > /etc/apt/apt.conf.d/52-hermes-unattended <<'APT'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Origins-Pattern {
    "site=download.docker.com";
    "site=pkgs.tailscale.com";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::SyslogEnable "true";
APT
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
unattended-upgrades --dry-run >/dev/null 2>&1 || warn "unattended-upgrades dry-run reported an issue (check: unattended-upgrades --dry-run --debug)"

# ── 5. fail2ban ──────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/sshd.local <<'F2B'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd

[sshd]
enabled = true
F2B
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban
sleep 2; fail2ban-client status sshd >/dev/null 2>&1 || die "fail2ban: the sshd jail is not running (fail2ban-client status; journalctl -u fail2ban)"

# ── 6. Docker daemon defaults (read when install.sh installs Docker) ─────
if [ ! -f /etc/docker/daemon.json ]; then
  install -d /etc/docker
  cat > /etc/docker/daemon.json <<'DOCKER'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
DOCKER
fi

# Published ports bind the Tailscale IP: make dockerd wait (up to 60 s) for tailscaled to have
# it at boot, or the containers fail to start until heal.sh runs.
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/10-tailscale.conf <<'UNIT'
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do tailscale ip -4 >/dev/null 2>&1 && exit 0; sleep 2; done; echo "docker: no Tailscale IP after 60 s, starting anyway" >&2'
UNIT
systemctl daemon-reload

# ── 7. Tailscale ─────────────────────────────────────────────────────────
if ! command -v tailscale >/dev/null 2>&1; then
  info "Installing Tailscale"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -q && apt-get install -y -q tailscale
fi
systemctl enable --now tailscaled >/dev/null
if ! tailscale status >/dev/null 2>&1; then
  if [ -n "${TS_AUTHKEY:-}" ]; then
    info "Joining tailnet with TS_AUTHKEY"
    # file: keeps the key off the process list; the file is removed right after.
    _tsk="$(mktemp)"; printf '%s' "$TS_AUTHKEY" > "$_tsk"
    tailscale up --auth-key="file:$_tsk" --hostname="$(hostname)"; rm -f "$_tsk"
  else
    [ -t 0 ] || die "no terminal and no TS_AUTHKEY: cannot join the tailnet interactively (sudo TS_AUTHKEY=tskey-… ./harden.sh)"
    info "Joining tailnet — open the URL below in your browser and approve this machine."
    tailscale up --hostname="$(hostname)"
  fi
fi
TS_IP=""
for _ in $(seq 1 30); do TS_IP="$(tailscale ip -4 2>/dev/null || true)"; [ -n "$TS_IP" ] && break; sleep 2; done
[ -n "$TS_IP" ] || die "Tailscale is up but has no IPv4 yet — check 'tailscale status' and re-run."
tailscale set --auto-update >/dev/null 2>&1 || true
info "Tailscale IP: $TS_IP"

# ── 8. Firewall ──────────────────────────────────────────────────────────
info "Configuring ufw"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null
ufw allow in on tailscale0 comment 'tailnet: ssh, traefik, everything' >/dev/null
ufw allow in on "$WAN_IF" to any port 41641 proto udp comment 'tailscale direct' >/dev/null
if [ "$KEEP_PUBLIC_SSH" = 1 ]; then
  ufw limit in on "$WAN_IF" to any port 22 proto tcp comment 'public ssh (--keep-public-ssh)' >/dev/null
fi
ufw logging low >/dev/null

# Docker publishes ports through its own iptables chains, bypassing ufw's INPUT rules.
# Docker consults the DOCKER-USER chain first, so we pre-create it via ufw's after.rules:
# accept from the tailnet, from the containers' own bridges and established flows, drop every
# other NEW connection — whatever NIC it comes in on (WAN, a provider's private network, …).
add_docker_user_block() {
  local file="$1"
  sed -i '/^# BEGIN HERMES DOCKER-USER/,/^# END HERMES DOCKER-USER/d' "$file"
  cat >> "$file" <<RULES
# BEGIN HERMES DOCKER-USER
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i tailscale0 -j RETURN
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate NEW -j DROP
-A DOCKER-USER -j RETURN
COMMIT
# END HERMES DOCKER-USER
RULES
}
add_docker_user_block /etc/ufw/after.rules
add_docker_user_block /etc/ufw/after6.rules

# Anti-lockout guard: if you don't confirm below within 10 minutes, ufw turns itself off.
systemctl stop ufw-lockout-guard.timer ufw-lockout-guard.service >/dev/null 2>&1 || true
systemctl reset-failed ufw-lockout-guard.timer ufw-lockout-guard.service >/dev/null 2>&1 || true
systemd-run --quiet --unit=ufw-lockout-guard --on-active=10min /usr/sbin/ufw disable
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true
# ufw enable re-applies its rule files with iptables-restore, which flushes Docker's chains.
if systemctl is-active --quiet docker 2>/dev/null; then
  info "Docker is running — restarting it so its iptables chains are rebuilt"
  systemctl restart docker
fi
ufw status verbose | sed 's/^/    /'

# ── 9. Show the key, verify tailnet access, then lock SSH down ──────────
cat <<MSG

┌──────────────────────────────────────────────────────────────────────────┐
│  Operator user : $OP_USER   (sudo without password, docker group)
│  Tailscale IP  : $TS_IP
│  SSH           : ssh -i <private-key> $OP_USER@$TS_IP
└──────────────────────────────────────────────────────────────────────────┘
MSG
if [ "$NEW_KEY" = 1 ]; then
  cat <<MSG
==================== SSH KEY PAIR FOR $OP_USER — SAVE IT NOW ====================

--- PUBLIC KEY (already in $OP_HOME/.ssh/authorized_keys) ---
$(cat "$KEY_FILE.pub")

--- PRIVATE KEY (save as ~/.ssh/hermes_vps on your laptop, chmod 600) ---
$(cat "$KEY_FILE")

=================================================================================
MSG
fi

if [ "${HARDEN_ASSUME_YES:-0}" != 1 ]; then
  [ -t 0 ] || die "No TTY for the lockout check. Re-run interactively, or set HARDEN_ASSUME_YES=1 after verifying Tailscale SSH yourself. (ufw will auto-disable in 10 min.)"
  echo "The firewall is ON. It will switch itself OFF in 10 minutes unless you confirm."
  echo "From your laptop (on the tailnet), in ANOTHER terminal, verify:"
  echo "    ssh -i ~/.ssh/hermes_vps $OP_USER@$TS_IP 'sudo -n true && echo OK'"
  read -r -p "Did the Tailscale SSH login work and did you save the key? [y/N] " ok
  if [ "${ok,,}" != y ]; then
    systemctl stop ufw-lockout-guard.timer >/dev/null 2>&1 || true
    ufw --force disable >/dev/null
    warn "Firewall disabled again; nothing else was locked. Fix access (tailscale status, key) and re-run."
    exit 1
  fi
fi
systemctl stop ufw-lockout-guard.timer ufw-lockout-guard.service >/dev/null 2>&1 || true
info "Access confirmed — firewall stays on."

info "Hardening sshd"
cat > /etc/ssh/sshd_config.d/00-hermes-hardening.conf <<SSHD
# Managed by harden.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
PubkeyAuthentication yes
AllowUsers $OP_USER
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD
sshd -t || die "sshd config test failed — drop-in left at /etc/ssh/sshd_config.d/00-hermes-hardening.conf, sshd NOT reloaded."
# 24.04 socket-activates ssh.service: it may be inactive (nothing to reload) when run from a console.
systemctl try-reload-or-restart ssh.service 2>/dev/null || systemctl try-reload-or-restart sshd.service

if [ "$NEW_KEY" = 1 ] && [ "$KEEP_KEY" != 1 ]; then
  shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
  info "Private key removed from the server (kept: $KEY_FILE.pub). Use --keep-key to retain it."
fi

cat <<MSG

Done. Next steps:
  1. Log in as the operator and start the stack:
       ssh -i ~/.ssh/hermes_vps $OP_USER@$TS_IP
       cd /srv/hermes/stack && sudo ./install.sh && sudo ./auth.sh
     No public DNS record needed: the stack's own DNS answers <HERMES_HOST> for the tailnet.
  2. Tailscale admin console → DNS → Nameservers → Add → Custom → $TS_IP, "Restrict to domain" →
     your DNS_ZONE (install.sh prints it). TLS still works via the Cloudflare DNS-01 challenge.
  3. If you run 'ufw reload' later, also run 'systemctl restart docker' (ufw flushes Docker's chains).
  4. Tailscale admin console → this machine → "Disable key expiry". Otherwise the node key
     expires after 180 days and, with SSH closed on the WAN, you are locked out.
MSG
