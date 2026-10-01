import importlib.util
import pathlib
import unittest
from unittest.mock import patch


COLLECTOR_PATH = pathlib.Path(__file__).resolve().parents[1] / "scripts/remote-collector.py"
spec = importlib.util.spec_from_file_location("remote_collector", COLLECTOR_PATH)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class ClaudeStatusTests(unittest.TestCase):
    def session(self, status="idle", updated=200, status_updated=None):
        sidecar = {"status": status, "updatedAt": updated * 1000} if status else None
        if sidecar is not None and status_updated is not None:
            sidecar["statusUpdatedAt"] = status_updated * 1000
        with patch.object(collector, "NOW", 1000), \
             patch.object(collector.subprocess, "check_output", return_value="42 00:15:00 claude\n"), \
             patch.object(collector, "cwd_for", return_value="/project"), \
             patch.object(collector, "read_json", return_value=sidecar):
            return collector.process_sessions()[0]

    def hook(self, event="start", stamp=150, **fields):
        # Hook shell PIDs differ from Claude's PID in the reported failure.
        return dict(timestamp=stamp, agent="claude-code", event=event,
                    pid=900, projectPath="/project", **fields)

    def merge(self, session, hooks):
        with patch.object(collector, "recent_hooks", return_value=hooks):
            return collector.merge_hooks([session])[0]

    def test_old_prompt_does_not_override_idle_or_shell(self):
        for status in ("idle", "shell"):
            with self.subTest(status=status):
                result = self.merge(self.session(status), [self.hook(title="Previous prompt")])
                self.assertEqual(result["state"], "idle")
                self.assertEqual(result["updatedAt"], 200)
                self.assertEqual(result["title"], "Previous prompt")

    def test_old_permission_resume_and_stop_do_not_override_idle(self):
        hooks = [self.hook(), self.hook("permission", 160, requestKey="tool"),
                 self.hook("resume", 170, requestKey="tool"), self.hook("stop", 180)]
        result = self.merge(self.session(), hooks)
        self.assertEqual((result["state"], result["updatedAt"]), ("idle", 200))

    def test_new_prompt_can_restart_idle_session(self):
        result = self.merge(self.session(), [self.hook(), self.hook(stamp=210)])
        self.assertEqual((result["state"], result["updatedAt"]), ("running", 210))

    def test_new_permission_and_resume_still_work(self):
        hooks = [self.hook("permission", 210, requestKey="tool")]
        result = self.merge(self.session(), hooks)
        self.assertEqual(result["state"], "waiting")
        result = self.merge(self.session(), hooks + [self.hook("resume", 220, requestKey="tool")])
        self.assertEqual((result["state"], result["updatedAt"]), ("running", 220))

    def test_resume_of_obsolete_permission_does_not_restart_session(self):
        result = self.merge(self.session(), [self.hook("permission", 150, requestKey="tool"),
                                             self.hook("resume", 210, requestKey="tool")])
        self.assertEqual(result["state"], "idle")

    def test_new_stop_still_marks_finished(self):
        result = self.merge(self.session(), [self.hook("stop", 210)])
        self.assertEqual((result["state"], result["updatedAt"]), ("finished", 210))

    def test_missing_sidecar_does_not_suppress_hooks(self):
        result = self.merge(self.session(None), [self.hook("stop", 150)])
        self.assertEqual((result["state"], result["updatedAt"]), ("finished", 150))

    def test_active_sidecar_does_not_hide_pending_permission(self):
        result = self.merge(self.session("running"), [self.hook("permission", 150, requestKey="tool")])
        self.assertEqual(result["state"], "waiting")

    def test_busy_transition_clears_permission_with_changed_tool_input(self):
        hooks = [self.hook("permission", 160, requestKey="original-tool"),
                 self.hook("resume", 190, requestKey="edited-tool")]
        result = self.merge(self.session("busy", status_updated=180), hooks)
        self.assertEqual((result["state"], result["updatedAt"]), ("running", 180))

    def test_busy_transition_does_not_hide_newer_permission(self):
        hooks = [self.hook("permission", 160, requestKey="old-tool"),
                 self.hook("permission", 190, requestKey="new-tool"),
                 self.hook("resume", 195, requestKey="unrelated-subagent")]
        result = self.merge(self.session("busy", status_updated=180), hooks)
        self.assertEqual(result["state"], "waiting")

    def test_rename_does_not_clear_permission(self):
        for status_updated in (None, 140):
            with self.subTest(status_updated=status_updated):
                result = self.merge(self.session("busy", updated=200, status_updated=status_updated),
                                    [self.hook("permission", 160, requestKey="tool")])
                self.assertEqual(result["state"], "waiting")

    def test_busy_transition_does_not_hide_newer_stop(self):
        result = self.merge(self.session("busy", status_updated=180), [self.hook("stop", 210)])
        self.assertEqual((result["state"], result["updatedAt"]), ("finished", 210))

    def test_status_transition_time_takes_precedence_over_rename_for_idle(self):
        result = self.merge(self.session("idle", updated=250, status_updated=180),
                            [self.hook("permission", 210, requestKey="tool")])
        self.assertEqual(result["state"], "waiting")

    def test_other_harness_hooks_remain_authoritative(self):
        for harness in ("pi", "cursor"):
            with self.subTest(harness=harness):
                session = self.session(None)
                session.update(harness=harness, id=f"{harness}:42")
                hook = self.hook("stop", 150)
                hook["agent"] = harness
                result = self.merge(session, [hook])
                self.assertEqual(result["state"], "finished")


if __name__ == "__main__":
    unittest.main()
