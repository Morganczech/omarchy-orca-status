#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("orca-status.py")
SPEC = importlib.util.spec_from_file_location("orca_status", MODULE_PATH)
orca_status = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(orca_status)

aggregate_agent_state = orca_status.aggregate_agent_state
build_terminal_groups = orca_status.build_terminal_groups
headline = orca_status.headline
normalize_agent = orca_status.normalize_agent
normalize_worktree = orca_status.normalize_worktree
parse_usage = orca_status.parse_usage
resolve_agent_label = orca_status.resolve_agent_label
summarize = orca_status.summarize


class OrcaStatusTests(unittest.TestCase):
    def test_aggregate_blocked_wins(self):
        self.assertEqual(aggregate_agent_state(["working", "blocked", "waiting"]), "blocked")
        self.assertEqual(aggregate_agent_state(["working", "waiting"]), "waiting")
        self.assertEqual(aggregate_agent_state(["done", "inactive"]), "done")

    def test_summarize_counts_agents(self):
        worktrees = [
            {
                "state": "working",
                "agents": [
                    {"state": "working"},
                    {"state": "blocked"},
                ],
            },
            {
                "state": "inactive",
                "agents": [],
            },
        ]
        summary = summarize(worktrees)
        self.assertEqual(summary["blocked"], 1)
        self.assertEqual(summary["working"], 1)
        self.assertEqual(summary["semaphore"], "red")

    def test_normalize_worktree_uses_terminal_handle(self):
        worktree = {
            "worktreeId": "repo::/tmp/project",
            "repo": "project",
            "status": "working",
            "agents": [{"state": "working", "agentType": "cursor", "prompt": "hello"}],
        }
        terminals = [{
            "handle": "term_123",
            "agentIdentity": "cursor",
            "title": "⠋ Cursor Agent",
            "lastOutputAt": 20,
        }]
        normalized = normalize_worktree(worktree, terminals)
        self.assertEqual(normalized["terminalHandle"], "term_123")
        self.assertEqual(normalized["state"], "working")
        self.assertEqual(normalized["agents"][0]["displayLabel"], "cursor-agent")

    def test_working_status_beats_done_agents(self):
        worktree = {
            "worktreeId": "repo::/tmp/project",
            "repo": "project",
            "status": "working",
            "liveTerminalCount": 1,
            "agents": [{"state": "done", "agentType": "cursor", "prompt": "still going"}],
        }
        terminals = [{
            "handle": "term_live",
            "agentIdentity": "cursor",
            "title": "Cursor Agent",
            "lastOutputAt": 50,
        }]
        normalized = normalize_worktree(worktree, terminals)
        self.assertEqual(normalized["state"], "working")
        self.assertEqual(normalized["agents"][0]["state"], "working")
        self.assertEqual(normalized["agents"][0]["terminalHandle"], "term_live")
        summary = summarize([normalized])
        self.assertGreater(summary["working"], 0)
        self.assertEqual(summary["semaphore"], "green")

    def test_build_terminal_groups_prefers_latest_output(self):
        terminals = build_terminal_groups([
            {"worktreeId": "a", "handle": "term_old", "lastOutputAt": 10},
            {"worktreeId": "a", "handle": "term_new", "lastOutputAt": 20},
        ])
        self.assertEqual(terminals["a"][0]["handle"], "term_new")

    def test_resolve_agent_label_cursor_agent(self):
        self.assertEqual(
            resolve_agent_label("cursor", "⠋ Cursor Agent", "cursor"),
            "cursor-agent",
        )
        self.assertEqual(resolve_agent_label("codex", "Codex", "codex"), "codex")

    def test_parse_usage_from_status_line(self):
        preview = "Plan · 1 task\nGrok 4.7 256K Low · 46.7% · 4 files edited\n~/Projects/oapp"
        usage = parse_usage(preview)
        self.assertEqual(usage["model"], "Grok 4.7")
        self.assertEqual(usage["percent"], 46.7)
        self.assertEqual(usage["files"], 4)
        self.assertEqual(usage["label"], "Grok 4.7 · 47%")
        self.assertIsNone(parse_usage("no meter here"))

    def test_worktree_usage_picks_fullest_terminal(self):
        worktree = {
            "worktreeId": "repo::/tmp/project",
            "repo": "project",
            "status": "working",
            "agents": [
                {"state": "working", "agentType": "cursor", "prompt": "one"},
                {"state": "working", "agentType": "cursor", "prompt": "two"},
            ],
        }
        terminals = [
            {"handle": "term_low", "title": "Cursor Agent", "preview": "Grok 4.7 256K Low · 12% · 1 file edited", "lastOutputAt": 2},
            {"handle": "term_high", "title": "Cursor", "preview": "Grok 4.7 256K Low · 91.2% · 3 files edited", "lastOutputAt": 1},
        ]
        normalized = normalize_worktree(worktree, terminals)
        self.assertEqual(normalized["summary"], "")
        self.assertEqual(normalized["usage"]["percent"], 91.2)
        percents = sorted(agent["usage"]["percent"] for agent in normalized["agents"])
        self.assertEqual(percents, [12.0, 91.2])

    def test_headline_priority(self):
        self.assertEqual(headline({"blocked": 2, "waiting": 1, "working": 3}), "2 blocked")
        self.assertEqual(headline({"blocked": 0, "waiting": 1, "working": 3}), "1 waiting")
        self.assertEqual(headline({"blocked": 0, "waiting": 0, "working": 3}), "3 working")

    def test_normalize_agent_truncates_prompt(self):
        agent = normalize_agent({"state": "blocked", "prompt": "x" * 200})
        self.assertTrue(agent["prompt"].endswith("…"))
        self.assertEqual(agent["state"], "blocked")


if __name__ == "__main__":
    unittest.main()
