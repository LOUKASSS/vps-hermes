#!/usr/bin/python3
"""Hermes pre_tool_call shell hook — the human-approval gate for host actions (option B).

Hermes runs on the host as the operator user: sudo without password, docker group. Its own
approval gate only flags a fixed list of dangerous patterns (a plain `sudo cmd` is not one of
them), so this hook escalates to the SAME human gate (prompt / Telegram: once, session, always,
deny; timeout = denied) every tool call that acts on the server rather than on the workspace:

  terminal / execute_code   sudo, docker (anything but read-only verbs), systemctl/service
                            state changes, package managers, firewall / network / tailscale,
                            users and sudoers, crontab, and any command that touches a
                            protected path (/etc, /opt, /srv/command-center, …) or reads a
                            secret file (.env, credentials, keys) outside the workspace
  write_file / patch        a file under a protected path, or Hermes' own config / env /
                            credentials / hook allowlist in /opt/data

Installed root-owned as /etc/hermes/host-guard.py by hermes-host.sh units (the agent cannot edit
it without sudo — which this hook escalates). Wired in config.yaml `hooks.pre_tool_call` with
fail_closed: a crash or a timeout blocks the call. stdin: the hook payload (JSON); stdout: `{}`
(allow) or `{"action": "approve", "message": …, "rule_key": …}`. rule_key hashes the exact
command, so "always" allows that command only, never "all sudo".

This is a seatbelt against mistakes and prompt injection, not a security boundary: an agent that
means to get around it can (it holds the uid that owns /opt/data).

  host-guard.py --self-test     # run the built-in cases
"""
import hashlib
import json
import re
import sys

WORKSPACE = "/srv/workspace"
# Mutations anywhere under these need a human.
PROTECTED = (
    "/etc/", "/usr/", "/opt/hermes", "/opt/orca", "/boot/", "/root", "/var/lib/docker",
    "/srv/command-center", "/srv/hermes", "/srv/orca", "/srv/helios", "/srv/discord-backup",
    "/home/hermes/.ssh", "/lib/systemd", "/run/systemd",
)
# Hermes' own control files in its data dir (config, env, logins, hook consent).
AGENT_CONTROL = (
    "/opt/data/config.yaml", "/opt/data/.env", "/opt/data/auth.json", "/opt/data/SOUL.md",
    "/opt/data/shell-hooks-allowlist.json", "/opt/data/home/.ssh",
    "/srv/hermes/data/config.yaml", "/srv/hermes/data/.env", "/srv/hermes/data/auth.json",
    "/srv/hermes/data/shell-hooks-allowlist.json",
)
CMD = r"(?:^|[;&|`(\n]|\$\(|&&|\|\||['\"])\s*(?:\w+=\S*\s+)*"          # command position
RULES = [
    ("sudo", CMD + r"sudo\b"),
    ("su", CMD + r"su(?:\s|$)"),
    ("docker", CMD + r"(?:docker(?:-compose)?|podman)\s+(?:-{1,2}\S+(?:[=\s]\S+)?\s+)*"
               r"(?!(?:ps|images|inspect|logs|version|info|stats|top|events|port|diff|history|search|"
               r"compose\s+(?:ps|logs|config|images|ls|top|version))\b)\S"),
    ("systemd", CMD + r"(?:systemctl|service)\s+(?:--\S+\s+)*(?:start|stop|restart|reload|try-restart|"
                r"reload-or-restart|enable|disable|mask|unmask|edit|daemon-reload|daemon-reexec|kill|"
                r"set-property|isolate|revert|link|preset)\b"),
    ("packages", CMD + r"(?:apt|apt-get|aptitude|dpkg|snap|add-apt-repository)\b"),
    ("firewall/network", CMD + r"(?:ufw|iptables|ip6tables|nft|iptables-restore|tailscale\s+(?:up|down|set|logout|serve|funnel)|"
                         r"ip\s+(?:link|route|addr|address)\s+(?:add|del|delete|set|flush|change|replace))\b"),
    ("users", CMD + r"(?:useradd|usermod|userdel|groupadd|groupmod|groupdel|gpasswd|passwd|chpasswd|visudo|"
              r"chsh|loginctl\s+(?:enable|disable)-linger)\b"),
    ("crontab", CMD + r"crontab\s+(?!-l\b)"),
    ("power", CMD + r"(?:reboot|shutdown|poweroff|halt)\b"),
    ("mount", CMD + r"(?:mount|umount|swapoff|swapon|mkfs(?:\.\w+)?|fdisk|parted|losetup)\b"),
]
RULES = [(name, re.compile(rx, re.IGNORECASE)) for name, rx in RULES]
MUTATE = re.compile(r"(?:\brm\b|\brmdir\b|\bmv\b|\bcp\b|\btee\b|\bsed\s+(?:-\S*\s+)*-i|\bchmod\b|\bchown\b|\bchgrp\b|"
                    r"\bln\b|\binstall\b|\btruncate\b|\bdd\b|\bshred\b|\btouch\b|\bmkdir\b|\bunlink\b|\brsync\b|"
                    r"\bgit\s+(?:clean|reset|checkout|restore)\b|[^<>&0-9]>{1,2}\s*\S|\bopen\([^)]*['\"][wa])")
# Reading one of these outside the workspace = handling a secret.
SECRET_READ = re.compile(r"(?:^|[\s'\"=])(?!" + re.escape(WORKSPACE) + r")(?:/\S*)?"
                         r"(?:/\.env\b|/agent\.env\b|\.credentials\.json\b|/auth\.json\b|/id_(?:rsa|ed25519|ecdsa)\b|"
                         r"/\.ssh/|/acme\.json\b|/shadow\b|/sudoers\b|/bws\.env\b)")
PATCH_FILES = re.compile(r"^\*\*\*\s+(?:Add|Update|Delete|Move)\s+File:\s*(\S+)", re.MULTILINE)


def _protected(path):
    p = path.strip().strip("'\"")
    if p.startswith("~/"):
        p = "/opt/data/home/" + p[2:]
    if p.startswith(WORKSPACE + "/") or p == WORKSPACE:
        return False
    return p.startswith(PROTECTED) or p.startswith(AGENT_CONTROL)


def check_command(cmd):
    """Why this shell command / code needs a human, or None."""
    hits = [name for name, rx in RULES if rx.search(cmd)]
    if MUTATE.search(cmd):
        for token in re.findall(r"(?:~|/)[^\s'\";|&<>)]*", cmd):
            if _protected(token):
                hits.append("writes " + token)
                break
    if SECRET_READ.search(cmd):
        hits.append("reads a secret file")
    return ", ".join(dict.fromkeys(hits)) or None


def decide(payload):
    tool = payload.get("tool_name") or ""
    args = payload.get("tool_input") or {}
    if not isinstance(args, dict):
        return {}
    if tool in ("terminal", "execute_code"):
        subject = args.get("command") if tool == "terminal" else args.get("code")
        if not isinstance(subject, str) or not subject.strip():
            return {}
        why = check_command(subject)
    elif tool in ("write_file", "patch"):
        paths = [args.get("path")] if isinstance(args.get("path"), str) else []
        if isinstance(args.get("patch"), str):
            paths += PATCH_FILES.findall(args["patch"])
        bad = [p for p in paths if p and _protected(p)]
        if not bad:
            return {}
        subject, why = " ".join(bad), "writes " + ", ".join(bad)
    else:
        return {}
    if not why:
        return {}
    shown = subject if len(subject) <= 400 else subject[:400] + "…"
    digest = hashlib.sha256(subject.encode("utf-8", "replace")).hexdigest()[:16]
    return {"action": "approve",
            "message": f"host action ({why}): {shown}",
            "rule_key": f"host-guard:{tool}:{digest}"}


SELF_TEST = [
    ("terminal", {"command": "ls -la /srv/workspace/projects"}, False),
    ("terminal", {"command": "git -C /srv/workspace/projects/helios status"}, False),
    ("terminal", {"command": "sudo apt install jq"}, True),
    ("terminal", {"command": "cd /tmp && sudo -n true"}, True),
    ("terminal", {"command": "docker ps --format '{{.Names}}'"}, False),
    ("terminal", {"command": "docker compose logs -f traefik"}, False),
    ("terminal", {"command": "docker compose up -d"}, True),
    ("terminal", {"command": "docker run --rm -v /:/host alpine sh"}, True),
    ("terminal", {"command": "systemctl status hermes-gateway"}, False),
    ("terminal", {"command": "systemctl --user restart foo"}, True),
    ("terminal", {"command": "journalctl -u hermes-gateway -n 50"}, False),
    ("terminal", {"command": "cat /srv/command-center/.env"}, True),
    ("terminal", {"command": "cat /srv/workspace/projects/helios/.env.example"}, False),
    ("terminal", {"command": "echo x > /etc/hosts"}, True),
    ("terminal", {"command": "cat /etc/os-release"}, False),
    ("terminal", {"command": "rm -rf /srv/workspace/scratch/tmp1"}, False),
    ("terminal", {"command": "rm -rf /srv/hermes/postgres"}, True),
    ("terminal", {"command": "sed -i s/a/b/ /opt/data/config.yaml"}, True),
    ("terminal", {"command": "crontab -l"}, False),
    ("terminal", {"command": "psql -c 'select 1'"}, False),
    ("terminal", {"command": "ufw status"}, True),
    ("terminal", {"command": "bash -c 'sudo reboot'"}, True),
    ("execute_code", {"code": "import os; os.system('sudo reboot')"}, True),
    ("execute_code", {"code": "print(open('/srv/workspace/scratch/a').read())"}, False),
    ("write_file", {"path": "/srv/workspace/scratch/a.md", "content": "x"}, False),
    ("write_file", {"path": "/etc/cron.d/x", "content": "x"}, True),
    ("write_file", {"path": "/opt/data/config.yaml", "content": "x"}, True),
    ("patch", {"patch": "*** Begin Patch\n*** Update File: /srv/command-center/update.sh\n@@\n-a\n+b\n*** End Patch"}, True),
    ("read_file", {"path": "/etc/shadow"}, False),
]


def self_test():
    bad = 0
    for tool, args, want in SELF_TEST:
        got = bool(decide({"tool_name": tool, "tool_input": args}))
        if got != want:
            bad += 1
            print(f"FAIL {tool} {args} → {'approve' if got else 'allow'} (want {'approve' if want else 'allow'})")
    print(f"{len(SELF_TEST) - bad}/{len(SELF_TEST)} ok")
    return 1 if bad else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        payload = {}
    print(json.dumps(decide(payload) if isinstance(payload, dict) else {}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
