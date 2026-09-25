"""Hermes work probe — runs as the runtime user with Hermes' own python (lib/agent-sessions.sh pipes
it: agent_run python3 - <mode> … < lib/hermes-probe.py; the venv preloads the fixed SQLite).

  busy <recent_s>       one line per piece of work a restart of hermes-gateway / hermes-dashboard
                        would cut: gateway turn (live turn lease), cron job, kanban run, async
                        delegation, or any open non-CLI session that wrote a message in the last
                        <recent_s> seconds (CLI sessions are separate processes a restart leaves alone)
  ended <id> <since>    exit 0 when <id> is a CLI session that ended at/after <since> (epoch s)

Read-only (sqlite mode=ro). PIDs are checked in /proc together with their kernel start time (field
22 of /proc/<pid>/stat, what Hermes itself records), so rows left 'running' by a process that was
killed never count. A missing database is "nothing there"; a database that cannot be read is
reported on stderr and does not block (a schema change must not hold every update).
"""
import os
import sqlite3
import sys
import time

DATA = os.environ.get("HERMES_HOME") or "/opt/data"
HEARTBEAT_FRESH = 600   # a kanban run / delegation without a checkable pid: heartbeat this recent = alive


def query(db, sql, args=()):
    path = os.path.join(DATA, db)
    if not os.path.exists(path):
        return []
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        try:
            return con.execute(sql, args).fetchall()
        finally:
            con.close()
    except sqlite3.Error as exc:
        print(f"hermes-probe: {db}: {exc}", file=sys.stderr)
        return []


def start_ticks(pid):
    try:
        with open(f"/proc/{pid}/stat", "rb") as fh:
            return int(fh.read().rsplit(b")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def alive(pid, started=None):
    """pid runs (and is the same process when its start time was recorded)."""
    if not pid or not os.path.isdir(f"/proc/{int(pid)}"):
        return False
    if started is None:
        return True
    current = start_ticks(int(pid))
    return current is None or current == int(started)   # unreadable: cannot prove it died


def fresh_or_alive(pid, started, heartbeat, now):
    return alive(pid, started) if pid else (heartbeat or 0) > now - HEARTBEAT_FRESH


def busy(recent):
    now = time.time()
    out = []
    for conv, _holder in query("state.db", "SELECT conversation_id, holder FROM session_turn_leases WHERE expires_at > ?", (now,)):
        out.append(f"gateway turn in progress ({conv})")
    for job, pid, started, status in query(
            "cron/executions.db",
            "SELECT job_id, pid, process_started_at, status FROM executions "
            "WHERE status IN ('claimed','running') AND finished_at IS NULL"):
        if alive(pid, started):
            out.append(f"cron job {job} {status}")
    for task, title, pid, started, heartbeat in query(
            "kanban.db",
            "SELECT r.task_id, t.title, r.worker_pid, r.worker_started_at, r.last_heartbeat_at "
            "FROM task_runs r LEFT JOIN tasks t ON t.id = r.task_id "
            "WHERE r.status = 'running' AND r.ended_at IS NULL"):
        if fresh_or_alive(pid, started, heartbeat, now):
            out.append(f"kanban task {task} running ({(title or '')[:60]})")
    for deleg, session, pid, started, updated in query(
            "state.db",
            "SELECT delegation_id, origin_session, owner_pid, owner_started_at, updated_at FROM async_delegations "
            "WHERE state IN ('running','stalling','finalizing')"):
        if fresh_or_alive(pid, started, updated, now):
            out.append(f"async delegation {deleg} running (from {session})")
    for sid, source, last in query(
            "state.db",
            "SELECT s.id, s.source, MAX(m.timestamp) FROM messages m JOIN sessions s ON s.id = m.session_id "
            "WHERE m.timestamp > ? AND s.ended_at IS NULL AND s.source != 'cli' GROUP BY s.id", (now - recent,)):
        out.append(f"{source} session {sid} active {int(now - last)} s ago")
    for line in out:
        print(line.replace("\n", " "))


def ended(sid, since):
    row = query("state.db", "SELECT 1 FROM sessions WHERE id = ? AND source = 'cli' AND ended_at >= ?", (sid, since))
    return 0 if row else 1


def main(argv):
    if len(argv) == 2 and argv[0] == "busy":
        busy(float(argv[1]))
        return 0
    if len(argv) == 3 and argv[0] == "ended":
        return ended(argv[1], float(argv[2]))
    print("usage: hermes-probe.py busy <recent_s> | ended <session_id> <since_epoch>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
