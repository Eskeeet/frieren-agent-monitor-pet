#!/usr/bin/env python3
"""Emit a JSON snapshot of agent sessions on this machine."""

import datetime as dt
import glob
import json
import os
import pathlib
import re
import subprocess
import time

HOME = pathlib.Path.home()
NOW = time.time()
FINISHED_RETENTION = 10 * 60
SCAN_WINDOW = 24 * 60 * 60
TAIL_BYTES = 512 * 1024


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def parse_date(value):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def elapsed_seconds(value):
    match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", value)
    if not match:
        return 0
    days, hours, minutes, seconds = (int(part or 0) for part in match.groups())
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def harness_for(args, executable_path=None):
    tokens = args.strip().split()
    if not tokens:
        return None
    # ps args does not quote executable paths containing spaces (for example
    # Claude Desktop's Application Support install). Use comm when available.
    executable = os.path.basename(executable_path or tokens[0])
    if executable == "claude":
        infrastructure = {"daemon", "bg-pty-host", "bg-spare", "--bg-pty-host", "--bg-spare"}
        return None if any(token in infrastructure for token in tokens[1:]) else "claude"
    if executable == "pi":
        non_interactive = {"install", "remove", "uninstall", "update", "list", "config", "--help", "-h", "--version", "-v"}
        return None if len(tokens) > 1 and tokens[1] in non_interactive else "pi"
    if executable == "codex":
        return "codex"
    if executable == "cursor-agent":
        return "cursor"
    if args.startswith("Cursor Helper (Plugin): extension-host Agents Window"):
        return "cursor"
    if executable in {"node", "deno", "bun"}:
        if re.search(r"\bcodex(?:-cli)?\b", args):
            return "codex"
        if re.search(r"\bcursor-agent\b", args):
            return "cursor"
        if re.search(r"\bpi-coding-agent\b", args):
            return "pi"
    # Linux comm can contain a runtime thread name or a versioned binary name.
    return harness_for(args) if executable_path else None


def cwd_for(pid):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        pass
    try:
        output = subprocess.check_output(
            ["/usr/sbin/lsof", "-a", "-d", "cwd", "-p", str(pid), "-Fn"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=1,
        )
        return next((line[1:] for line in output.splitlines() if line.startswith("n")), None)
    except (OSError, subprocess.SubprocessError):
        return None


def process_sessions():
    try:
        output = subprocess.check_output(
            ["ps", "-axo", "pid=,etime=,args="], text=True, stderr=subprocess.DEVNULL, timeout=2
        )
    except (OSError, subprocess.SubprocessError):
        return []

    executable_paths = {}
    try:
        commands = subprocess.check_output(
            ["ps", "-axo", "pid=,comm="], text=True, stderr=subprocess.DEVNULL, timeout=2
        )
        for line in commands.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                executable_paths[int(parts[0])] = parts[1]
    except (OSError, subprocess.SubprocessError):
        pass

    sessions = []
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        harness = harness_for(parts[2], executable_paths.get(pid))
        if not harness or harness == "codex":
            continue
        sidecar = read_json(HOME / ".claude" / "sessions" / f"{pid}.json") if harness == "claude" else None
        updated = sidecar.get("updatedAt") / 1000 if isinstance(sidecar, dict) and sidecar.get("updatedAt") else NOW
        # Claude can hand control back to an interactive shell without exiting
        # its long-lived process. Both `idle` and `shell` mean that no agent
        # turn is currently running.
        inactive = isinstance(sidecar, dict) and sidecar.get("status") in {"idle", "shell"}
        status_updated = None
        if isinstance(sidecar, dict):
            if inactive:
                status_updated = sidecar.get("statusUpdatedAt") or sidecar.get("updatedAt")
            elif sidecar.get("status") in {"busy", "running"}:
                # updatedAt also changes on rename; it cannot clear a permission.
                status_updated = sidecar.get("statusUpdatedAt")
        status_updated = status_updated / 1000 if status_updated is not None else None
        sessions.append({
            "id": f"{harness}:{pid}",
            "pid": pid,
            "harness": harness,
            "projectPath": cwd_for(pid),
            "title": sidecar.get("name") if isinstance(sidecar, dict) else None,
            "startedAt": NOW - elapsed_seconds(parts[1]),
            "updatedAt": status_updated if status_updated is not None else updated,
            "state": "idle" if inactive else "running",
            "claudeStatusUpdatedAt": status_updated,
        })
    return sessions


def codex_titles():
    result = {}
    path = HOME / ".codex" / "session_index.jsonl"
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                    result[record["id"]] = record["thread_name"]
                except (ValueError, KeyError, TypeError):
                    pass
    except OSError:
        pass
    return result


def tail_text(path):
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            offset = max(0, size - TAIL_BYTES)
            handle.seek(offset)
            data = handle.read().decode("utf-8", errors="ignore")
            if offset and "\n" in data:
                data = data.split("\n", 1)[1]
            return data
    except OSError:
        return ""


def codex_sessions():
    titles = codex_titles()
    pattern = str(HOME / ".codex" / "sessions" / "*" / "*" / "*" / "rollout-*.jsonl")
    sessions = []
    for path in glob.glob(pattern):
        try:
            modified = os.path.getmtime(path)
            if modified < NOW - SCAN_WINDOW:
                continue
            with open(path, encoding="utf-8") as handle:
                metadata = json.loads(handle.readline())
        except (OSError, ValueError):
            continue
        payload = metadata.get("payload", {})
        if metadata.get("type") != "session_meta":
            continue
        source = payload.get("source")
        if isinstance(source, dict) and "subagent" in source:
            continue
        session_id = payload.get("id") or payload.get("session_id")
        started = parse_date(metadata.get("timestamp"))
        if not session_id or started is None:
            continue

        latest = None
        latest_activity = None
        for line in tail_text(path).splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            stamp = parse_date(record.get("timestamp"))
            if stamp is None:
                continue
            if record.get("type") != "session_meta":
                latest_activity = stamp
            event = record.get("payload", {}).get("type")
            if record.get("type") == "event_msg" and event in {"task_started", "task_complete", "turn_aborted"}:
                latest = (event, stamp)
        if latest is None and latest_activity is not None:
            latest = ("task_started", latest_activity)
        if latest is None:
            continue
        state = "running" if latest[0] == "task_started" else "finished"
        if state == "finished" and NOW - latest[1] > FINISHED_RETENTION:
            continue
        sessions.append({
            "id": f"codex:{session_id}",
            "pid": stable_int(session_id),
            "harness": "codex",
            "projectPath": payload.get("cwd"),
            "title": titles.get(session_id),
            "startedAt": started,
            "updatedAt": latest[1] if state == "finished" else modified,
            "state": state,
        })
    return sessions


def stable_int(value):
    result = 14695981039346656037
    for byte in value.encode():
        result ^= byte
        result = (result * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return result if result < 2**63 else result - 2**64


def recent_hooks():
    text = tail_text(HOME / ".frieren-monitor" / "events.jsonl")
    records = []
    for line in text.splitlines()[-100:]:
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    return records


def merge_hooks(sessions):
    # Freeze the status-file timestamps before replaying hooks. Claude's idle
    # or shell status is newer evidence than an old prompt whose Stop hook was
    # never recorded; process-scan timestamps for other agents are not evidence.
    claude_status_at = {
        session["id"]: session.get("claudeStatusUpdatedAt") if session.get("claudeStatusUpdatedAt") is not None
            else session["updatedAt"]
        for session in sessions
        if session["harness"] == "claude"
        and (session.get("claudeStatusUpdatedAt") is not None or session["state"] == "idle")
    }
    pending_permissions = {}
    for hook in recent_hooks():
        agent = hook.get("agent", "")
        if "cursor" in agent:
            harness = "cursor"
        elif "codex" in agent:
            harness = "codex"
        elif agent == "pi" or "pi-coding-agent" in agent:
            harness = "pi"
        else:
            harness = "claude"
        matches = [session for session in sessions if session["harness"] == harness]
        match = next((session for session in matches if session["pid"] == hook.get("pid")), None)
        if match is None and hook.get("projectPath"):
            match = next((session for session in matches if session.get("projectPath") == hook["projectPath"]), None)
        if match is None and harness == "cursor" and len(matches) == 1:
            match = matches[0]
        if match is None:
            continue
        stamp = hook.get("timestamp")
        if not isinstance(stamp, (int, float)):
            continue
        if harness != "cursor" and stamp < match["startedAt"] - 2:
            continue
        event = hook.get("event")
        if event == "start":
            if hook.get("title"):
                match["title"] = hook["title"]
            if hook.get("projectPath") not in {None, "/"}:
                match["projectPath"] = hook["projectPath"]
        if stamp < claude_status_at.get(match["id"], float("-inf")):
            continue
        if event == "start":
            match["state"] = "running"
            match["updatedAt"] = stamp
            pending_permissions.pop(match["id"], None)
        elif event == "permission" and hook.get("requestKey") is not None:
            match["state"] = "waiting"
            pending_permissions.setdefault(match["id"], set()).add(hook["requestKey"])
        elif (
            event == "resume"
            and match["state"] == "waiting"
            and hook.get("requestKey") is not None
            and hook.get("requestKey") in pending_permissions.get(match["id"], set())
        ):
            pending_permissions[match["id"]].remove(hook["requestKey"])
            if not pending_permissions[match["id"]]:
                match["state"] = "running"
                match["updatedAt"] = stamp
                pending_permissions.pop(match["id"], None)
        elif event == "stop":
            match["state"] = "finished"
            match["updatedAt"] = stamp
    return sessions


if __name__ == "__main__":
    print(json.dumps({"version": 1, "generatedAt": NOW, "sessions": merge_hooks(process_sessions() + codex_sessions())}, separators=(",", ":")))
