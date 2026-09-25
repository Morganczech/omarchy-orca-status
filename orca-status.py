#!/usr/bin/env python3
"""Backend for the Orca Status Omarchy plugin.

Produces a single normalized JSON document on stdout. Commands:
    (none)                              fetch projects, worktrees, and agents
    switch --terminal <handle>          focus a terminal tab in Orca
"""
import json
import os
import re
import shutil
import subprocess
import sys

DEFAULT_ORCA = os.path.expanduser("~/.config/orca/linux-orca-cli-shim/orca")

STATE_PRIORITY = {
    "blocked": 4,
    "waiting": 3,
    "working": 2,
    "done": 1,
    "inactive": 0,
}

SEMAPHORE_BY_STATE = {
    "blocked": "red",
    "waiting": "yellow",
    "working": "green",
    "done": "gray",
    "inactive": "gray",
    "offline": "gray",
}


def find_orca(cli_path):
    if cli_path:
        expanded = os.path.expanduser(cli_path)
        if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
            return expanded
        return None
    found = shutil.which("orca")
    if found:
        return found
    if os.path.isfile(DEFAULT_ORCA) and os.access(DEFAULT_ORCA, os.X_OK):
        return DEFAULT_ORCA
    return None


def run_orca(orca_bin, *args, timeout=15):
    try:
        completed = subprocess.run(
            [orca_bin, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as error:
        return {"ok": False, "error": str(error), "stdout": "", "stderr": ""}

    stdout = completed.stdout or ""
    stderr = completed.stderr or ""
    if completed.returncode != 0:
        return {
            "ok": False,
            "error": stderr.strip() or stdout.strip() or f"exit {completed.returncode}",
            "stdout": stdout,
            "stderr": stderr,
        }

    try:
        payload = json.loads(stdout) if stdout.strip() else {}
    except json.JSONDecodeError as error:
        return {
            "ok": False,
            "error": f"Invalid JSON: {error}",
            "stdout": stdout,
            "stderr": stderr,
        }

    if isinstance(payload, dict) and payload.get("ok") is False:
        return {
            "ok": False,
            "error": payload.get("error") or "Orca command failed",
            "stdout": stdout,
            "stderr": stderr,
        }

    return {"ok": True, "payload": payload, "stdout": stdout, "stderr": stderr}


def unwrap_result(payload):
    if not isinstance(payload, dict):
        return payload
    if "result" in payload:
        return payload["result"]
    return payload


USAGE_LINE = re.compile(
    r"(?P<model>.+?)\s+[·•|]\s+(?P<percent>\d+(?:\.\d+)?)%\s+[·•|]\s+(?P<files>\d+)\s+files?\b"
)
MODEL_SUFFIX = re.compile(r"^(?P<name>.*?)(?:\s+\d+(?:\.\d+)?[kKmM])?(?:\s+(?:low|medium|high|xhigh|max))?$", re.IGNORECASE)


def shorten_model(model):
    cleaned = " ".join(str(model or "").split())
    match = MODEL_SUFFIX.match(cleaned)
    name = (match.group("name") if match else cleaned).strip()
    return name or cleaned


def parse_usage(text):
    found = None
    for line in str(text or "").splitlines():
        match = USAGE_LINE.search(" ".join(line.split()))
        if match:
            found = match
    if not found:
        return None
    percent = float(found.group("percent"))
    model = shorten_model(found.group("model"))
    rounded = int(round(percent))
    return {
        "model": model,
        "percent": percent,
        "files": int(found.group("files")),
        "label": f"{model} · {rounded}%",
    }


def pick_usage(usages):
    best = None
    for usage in usages:
        if not usage:
            continue
        if best is None or usage.get("percent", 0) > best.get("percent", 0):
            best = usage
    return best


def truncate(text, limit=140):
    value = str(text or "").replace("\n", " ").strip()
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "…"


def aggregate_agent_state(states):
    best = "inactive"
    best_rank = -1
    for state in states:
        rank = STATE_PRIORITY.get(state, 0)
        if rank > best_rank:
            best = state
            best_rank = rank
    return best


def resolve_agent_label(agent_type="", terminal_title="", agent_identity=""):
    title = str(terminal_title or "").lower()
    identity = str(agent_identity or agent_type or "").lower()
    agent = str(agent_type or "").lower()
    if "cursor" in title or identity == "cursor" or agent == "cursor":
        if "agent" in title or "cursor-agent" in title or "cursor agent" in title:
            return "cursor-agent"
        return "cursor"
    labels = {
        "codex": "codex",
        "claude": "claude-code",
        "omp": "omp",
        "hermes": "hermes",
        "pi": "pi",
        "fireworks": "fireworks",
    }
    if identity in labels:
        return labels[identity]
    if agent in labels:
        return labels[agent]
    cleaned_title = str(terminal_title or "").strip()
    if cleaned_title:
        return truncate(cleaned_title, 40)
    return identity or agent or "agent"


def normalize_agent(agent, terminal=None):
    terminal = terminal or {}
    state = str(agent.get("state") or "done").lower()
    if state not in STATE_PRIORITY:
        state = "done"
    agent_type = agent.get("agentType") or terminal.get("agentIdentity") or "unknown"
    display_label = resolve_agent_label(
        agent_type,
        terminal.get("title") or "",
        terminal.get("agentIdentity") or "",
    )
    return {
        "paneKey": agent.get("paneKey") or "",
        "state": state,
        "agentType": agent_type,
        "displayLabel": display_label,
        "prompt": truncate(agent.get("prompt")),
        "taskTitle": truncate(agent.get("taskTitle")),
        "displayName": truncate(agent.get("displayName")) or display_label,
        "toolName": agent.get("toolName") or "",
        "lastAssistantMessage": truncate(agent.get("lastAssistantMessage"), 200),
        "interrupted": bool(agent.get("interrupted")),
        "terminalHandle": terminal.get("handle") or "",
        "terminalTitle": truncate(terminal.get("title"), 80),
        "usage": None,
    }


def agent_from_terminal(terminal, worktree_status="inactive"):
    state = "working" if str(worktree_status).lower() == "working" else "inactive"
    if state == "inactive":
        state = "done"
    agent_type = terminal.get("agentIdentity") or "unknown"
    display_label = resolve_agent_label(
        agent_type,
        terminal.get("title") or "",
        terminal.get("agentIdentity") or "",
    )
    return {
        "paneKey": "",
        "state": state,
        "agentType": agent_type,
        "displayLabel": display_label,
        "prompt": truncate(terminal.get("preview")),
        "taskTitle": "",
        "displayName": display_label,
        "toolName": "",
        "lastAssistantMessage": "",
        "interrupted": False,
        "terminalHandle": terminal.get("handle") or "",
        "terminalTitle": truncate(terminal.get("title"), 80),
        "usage": parse_usage(terminal.get("preview")),
    }


def assign_terminals(agents, terminals, worktree_status):
    terminals = list(terminals or [])
    status = str(worktree_status or "inactive").lower()
    if not agents and terminals:
        return [agent_from_terminal(terminal, status) for terminal in terminals]
    for index, agent in enumerate(agents):
        terminal = terminals[index] if index < len(terminals) else {}
        if terminal:
            agent["terminalHandle"] = terminal.get("handle") or agent.get("terminalHandle") or ""
            agent["displayLabel"] = resolve_agent_label(
                agent.get("agentType"),
                terminal.get("title") or "",
                terminal.get("agentIdentity") or "",
            )
            agent["terminalTitle"] = truncate(terminal.get("title"), 80)
            agent["usage"] = parse_usage(terminal.get("preview")) or agent.get("usage")
    for terminal in terminals[len(agents):]:
        agents.append(agent_from_terminal(terminal, status))
    if status == "working" and agents and agents[0].get("state") in ("done", "inactive"):
        agents[0]["state"] = "working"
    return agents


def normalize_worktree(worktree, terminals_for_worktree):
    terminals = list(terminals_for_worktree or [])
    primary_terminal = terminals[0] if terminals else {}
    agents = [
        normalize_agent(agent, {})
        for agent in worktree.get("agents") or []
    ]
    agents = assign_terminals(agents, terminals, worktree.get("status"))
    agent_states = [agent["state"] for agent in agents]
    reported = str(worktree.get("status") or "inactive").lower()
    if reported not in STATE_PRIORITY:
        reported = "inactive"
    worktree_state = aggregate_agent_state(agent_states) if agent_states else reported
    if STATE_PRIORITY.get(reported, 0) > STATE_PRIORITY.get(worktree_state, 0):
        worktree_state = reported
    worktree_id = worktree.get("worktreeId") or ""
    preview = truncate(worktree.get("preview"), 180)
    usage = pick_usage([agent.get("usage") for agent in agents]) or parse_usage(worktree.get("preview"))
    if usage and agents and not any(agent.get("usage") for agent in agents):
        agents[0]["usage"] = usage
    return {
        "worktreeId": worktree_id,
        "repoId": worktree.get("repoId") or "",
        "repo": worktree.get("repo") or worktree.get("displayName") or "",
        "displayName": worktree.get("displayName") or worktree.get("repo") or "",
        "path": worktree.get("path") or "",
        "branch": worktree.get("branch") or "",
        "workspaceStatus": worktree.get("workspaceStatus") or "",
        "status": worktree.get("status") or "inactive",
        "state": worktree_state,
        "liveTerminalCount": int(worktree.get("liveTerminalCount") or 0),
        "isActive": bool(worktree.get("isActive")),
        "preview": preview,
        "summary": "",
        "usage": usage,
        "agents": agents,
        "terminalHandle": primary_terminal.get("handle") or "",
        "agentIdentity": primary_terminal.get("agentIdentity") or "",
        "terminalTitle": truncate(primary_terminal.get("title"), 80),
    }


def normalize_project(project, worktrees):
    source_ids = set(project.get("sourceRepoIds") or [])
    matched = []
    for worktree in worktrees:
        repo_id = worktree.get("repoId")
        if repo_id and repo_id in source_ids:
            matched.append(worktree)
        elif project.get("displayName") and project.get("displayName") == worktree.get("repo"):
            matched.append(worktree)
    active = sum(1 for wt in matched if wt.get("state") in ("working", "waiting", "blocked"))
    return {
        "id": project.get("id") or "",
        "displayName": project.get("displayName") or "",
        "badgeColor": project.get("badgeColor") or "#737373",
        "kind": project.get("kind") or "",
        "worktreeCount": len(matched),
        "activeWorktreeCount": active,
        "workspaceStatus": project_workspace_status(matched),
        "worstState": aggregate_agent_state([wt.get("state") for wt in matched]) if matched else "inactive",
    }


def project_workspace_status(worktrees):
    rank = {"in-progress": 4, "in-review": 3, "todo": 2, "completed": 1, "done": 1}
    best = ""
    best_rank = -1
    for worktree in worktrees:
        status = str(worktree.get("workspaceStatus") or "").lower()
        if status == "done":
            status = "completed"
        score = rank.get(status, 0)
        if score > best_rank:
            best = status
            best_rank = score
    return best or "todo"


def normalize_terminal(terminal):
    return {
        "handle": terminal.get("handle") or "",
        "agentIdentity": terminal.get("agentIdentity") or "",
        "title": terminal.get("title") or "",
        "preview": terminal.get("preview") or "",
        "lastOutputAt": int(terminal.get("lastOutputAt") or 0),
        "worktreeId": terminal.get("worktreeId") or "",
    }


def build_terminal_groups(terminals):
    groups = {}
    for terminal in terminals or []:
        normalized = normalize_terminal(terminal)
        worktree_id = normalized["worktreeId"]
        if not worktree_id:
            continue
        groups.setdefault(worktree_id, []).append(normalized)
    for worktree_id in groups:
        groups[worktree_id].sort(key=lambda item: item["lastOutputAt"], reverse=True)
    return groups


def summarize(worktrees):
    worktree_counts = {"blocked": 0, "waiting": 0, "working": 0, "done": 0, "inactive": 0}
    agent_counts = {"blocked": 0, "waiting": 0, "working": 0, "done": 0}
    for worktree in worktrees:
        state = worktree.get("state") or "inactive"
        if state not in worktree_counts:
            worktree_counts["inactive"] += 1
        else:
            worktree_counts[state] += 1
        counted = False
        for agent in worktree.get("agents") or []:
            agent_state = agent.get("state") or "done"
            if agent_state in agent_counts:
                agent_counts[agent_state] += 1
                if agent_state == state and state in ("blocked", "waiting", "working"):
                    counted = True
        if state in ("blocked", "waiting", "working") and not counted:
            agent_counts[state] += 1
    all_states = [wt.get("state") for wt in worktrees]
    for worktree in worktrees:
        for agent in worktree.get("agents") or []:
            all_states.append(agent.get("state"))
    overall = aggregate_agent_state(all_states)
    return {
        "worktrees": worktree_counts,
        "agents": agent_counts,
        "blocked": agent_counts["blocked"],
        "waiting": agent_counts["waiting"],
        "working": agent_counts["working"],
        "inactive": worktree_counts["inactive"],
        "overallState": overall,
        "semaphore": SEMAPHORE_BY_STATE.get(overall, "gray"),
    }


def headline(summary):
    blocked = summary.get("blocked", 0)
    waiting = summary.get("waiting", 0)
    working = summary.get("working", 0)
    if blocked > 0:
        return f"{blocked} blocked"
    if waiting > 0:
        return f"{waiting} waiting"
    if working > 0:
        return f"{working} working"
    return "Idle"


def fetch_status(cli_path=""):
    orca_bin = find_orca(cli_path)
    if not orca_bin:
        return {
            "ok": False,
            "offline": True,
            "error": "Orca CLI not found.",
            "summary": {"blocked": 0, "waiting": 0, "working": 0, "inactive": 0},
            "semaphore": "gray",
            "projects": [],
            "worktrees": [],
        }

    status_result = run_orca(orca_bin, "status", "--json")
    if not status_result.get("ok"):
        return {
            "ok": False,
            "offline": True,
            "error": status_result.get("error") or "Orca is not running.",
            "orcaCli": orca_bin,
            "summary": {"blocked": 0, "waiting": 0, "working": 0, "inactive": 0},
            "semaphore": "gray",
            "projects": [],
            "worktrees": [],
        }

    worktree_result = run_orca(orca_bin, "worktree", "ps", "--json")
    if not worktree_result.get("ok"):
        return {
            "ok": False,
            "offline": False,
            "error": worktree_result.get("error") or "Unable to read worktrees.",
            "orcaCli": orca_bin,
            "summary": {"blocked": 0, "waiting": 0, "working": 0, "inactive": 0},
            "semaphore": "gray",
            "projects": [],
            "worktrees": [],
        }

    project_result = run_orca(orca_bin, "project", "list", "--json")
    terminal_result = run_orca(orca_bin, "terminal", "list", "--json")

    worktree_payload = unwrap_result(worktree_result["payload"])
    project_payload = unwrap_result(project_result["payload"]) if project_result.get("ok") else {}
    terminal_payload = unwrap_result(terminal_result["payload"]) if terminal_result.get("ok") else {}

    terminal_groups = build_terminal_groups(terminal_payload.get("terminals") or [])
    raw_worktrees = worktree_payload.get("worktrees") or []
    worktrees = [
        normalize_worktree(item, terminal_groups.get(item.get("worktreeId") or "", []))
        for item in raw_worktrees
    ]
    projects = [
        normalize_project(project, worktrees)
        for project in (project_payload.get("projects") or [])
    ]

    summary = summarize(worktrees)
    return {
        "ok": True,
        "offline": False,
        "orcaCli": orca_bin,
        "headline": headline(summary),
        "summary": summary,
        "semaphore": summary["semaphore"],
        "projects": projects,
        "worktrees": worktrees,
    }


def switch_terminal(cli_path, handle):
    orca_bin = find_orca(cli_path)
    if not orca_bin:
        return {"ok": False, "error": "Orca CLI not found."}
    if not handle:
        return {"ok": False, "error": "Missing terminal handle."}
    result = run_orca(orca_bin, "terminal", "switch", "--terminal", handle, "--json")
    if not result.get("ok"):
        return {"ok": False, "error": result.get("error") or "Unable to switch terminal."}
    focus_orca_window()
    return {"ok": True}


def open_changed(cli_path, path):
    orca_bin = find_orca(cli_path)
    if not orca_bin:
        return {"ok": False, "error": "Orca CLI not found."}
    if not path:
        return {"ok": False, "error": "Missing worktree path."}
    result = run_orca(orca_bin, "file", "open-changed", "--mode", "diff",
                      "--worktree", f"path:{path}", "--json")
    if not result.get("ok"):
        return {"ok": False, "error": result.get("error") or "Unable to open changed files."}
    focus_orca_window()
    return {"ok": True}


def launch_orca(cli_path):
    orca_bin = find_orca(cli_path)
    if not orca_bin:
        return {"ok": False, "error": "Orca CLI not found."}
    try:
        subprocess.Popen(
            [orca_bin, "open"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as error:
        return {"ok": False, "error": f"Unable to launch Orca: {error}"}
    return {"ok": True}


def focus_orca_window():
    try:
        subprocess.run(
            ["hyprctl", "dispatch", 'hl.dsp.focus({ window = "class:^(orca)$" })'],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return


def flag_value(argv, name):
    if name in argv:
        index = argv.index(name)
        if index + 1 < len(argv):
            return argv[index + 1]
    return ""


def strip_flag(argv, name):
    cleaned = []
    skip = False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg == name:
            skip = True
            continue
        cleaned.append(arg)
    return cleaned


def main(argv):
    cli_path = flag_value(argv, "--cli")
    args = strip_flag(argv[1:], "--cli")
    command = args[0] if args else ""
    if command == "switch":
        return switch_terminal(cli_path, flag_value(argv, "--terminal"))
    if command == "open-changed":
        return open_changed(cli_path, flag_value(argv, "--path"))
    if command == "launch":
        return launch_orca(cli_path)
    if command and command not in ("status", ""):
        return {"ok": False, "error": f"Unknown command: {command}"}
    return fetch_status(cli_path)


if __name__ == "__main__":
    print(json.dumps(main(sys.argv)))
