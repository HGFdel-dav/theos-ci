#!/usr/bin/env python3
"""Synthetic temporary fixtures only; never read a device or real log."""
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("read_events", ROOT / "tools/diagnostics/read_events.py")
reader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reader)
RUN = "11111111-1111-4111-8111-111111111111"
REQUEST = "22222222-2222-4222-8222-222222222222"
NOW = dt.datetime(2026, 11, 5, 18, tzinfo=dt.timezone.utc)


def line(seq, stage="send", result="ok", feature="chat", fields=None, time=None, pid=100, run=RUN):
    event = {"v": 1, "feature": feature, "stage": stage, "result": result, "fields": fields or {"request": REQUEST}}
    return f"{time or f'2026-11-05T10:00:{seq:02d}.000Z'} pid={pid} process=Minis runId={run} seq={seq} event={json.dumps(event, ensure_ascii=False)}\n"


class ReadEventsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)

    def write(self, name, data):
        path = self.directory / name
        path.write_text(data, encoding="utf-8")
        return path

    def test_merge_explicit_rotation_deduplicate_and_tail(self):
        old = self.write("diagnostic-app.log.1", line(1) + line(2, "reply"))
        current = self.write("diagnostic-app.log", line(3, "display"))
        plugin = self.write("diagnostic-plugin.log", line(4, "apply", feature="settings", fields={"setting": "minisight.style", "revision": 1}, pid=200))
        events, errors = reader.load_events([current, plugin, old, old], tail=3)
        self.assertEqual(errors, 0)
        self.assertEqual([e["seq"] for e in events], [2, 3, 4])
        self.assertEqual(events[0]["fields"]["request"], REQUEST)

    def test_settings_save_receive_failed_apply_correlate_revision(self):
        fields = {"setting": "minisight.style", "revision": 7, "saved": True, "readback": True}
        app = self.write("app.log", line(1, "save", feature="settings", fields=fields))
        plugin = self.write("plugin.log", line(2, "receive", feature="settings", fields=fields, pid=200) + line(3, "apply", "failed", "settings", {**fields, "reason": "readback_mismatch"}, pid=200))
        events, _ = reader.load_events([plugin, app])
        report = reader.build_report(events)
        self.assertEqual(len(report["chains"]), 1)
        self.assertEqual(report["chains"][0]["checkpoints"], {"save": "ok", "readback": "unobserved", "publish": "unobserved", "receive": "ok", "configure": "unobserved", "apply": "failed"})
        self.assertIn("apply=failed", reader.render_text(report))

    def test_missing_display_never_implies_send_did_not_happen(self):
        report = reader.build_report([reader.parse_line(line(1))])
        self.assertEqual(report["chains"][0]["checkpoints"]["send"], "ok")
        self.assertEqual(report["chains"][0]["checkpoints"]["display"], "unobserved")
        self.assertIn("不能据此判定未发送", reader.render_text(report))

    def test_display_only_preserves_observed_display(self):
        report = reader.build_report([reader.parse_line(line(2, "display"))])
        self.assertEqual(report["chains"][0]["checkpoints"]["send"], "unobserved")
        self.assertEqual(report["chains"][0]["checkpoints"]["display"], "ok")

    def test_feature_since_and_tail_apply_after_merge(self):
        path = self.write("mixed.log", line(1) + line(2, "show", feature="voice") + line(3, "reply") + line(4, "close", feature="voice"))
        events, _ = reader.load_events([path], feature="voice", since=reader.parse_time("2026-11-05T10:00:03Z"), tail=1)
        self.assertEqual([(e["feature"], e["seq"]) for e in events], [("voice", 4)])

    def test_old_records_and_request_generation_normalize(self):
        path = self.write("diagnostic.log", f"11-05 10:00:00.000 pid=200 chat send-entry visible=1 sending=0\n11-05 10:00:01.000 pid=200 chat handle request={REQUEST}/7 success=0 issue=4\n11-05 10:00:02.000 pid=200 chat display request={REQUEST}/7 kind=answer chars=8 rows=1\n")
        events, errors = reader.load_events([path], now=NOW)
        self.assertEqual(errors, 0)
        self.assertEqual([e["stage"] for e in events], ["send", "reply", "display"])
        self.assertEqual([e["result"] for e in events], ["pending", "failed", "ok"])
        self.assertEqual(events[1]["fields"]["request"], REQUEST + ".7")
        self.assertEqual(events[2]["fields"]["count"], 1)

    def test_new_and_legacy_sensitive_values_are_not_echoed(self):
        fields = {"value": "SECRET_VALUE", "body": "SECRET_BODY", "endpoint": "https://SECRET_HOST.example", "persona": "SECRET_PERSONA", "audio": "SECRET_AUDIO", "setting": "minisight.style", "source": "sk-SECRET_KEY", "reason": "Bearer SECRET_AUTH", "request": "SECRET_NAME", "chars": 11, "enabled": True, "readback": "SECRET_READBACK", "domain": "https://SECRET_DOMAIN.example", "mode": ["SECRET_NESTED"], "count": 10**50, "x": float("nan")}
        old = "11-05 10:00:02.000 pid=200 chat display kind=answer chars=4 value=SECRET_VALUE endpoint=https://SECRET_HOST.example body=SECRET_BODY persona=SECRET_PERSONA audio=SECRET_AUDIO source=sk-SECRET_KEY request=SECRET_NAME reason=你好\n"
        path = self.write("fake.log", line(1, fields=fields) + old)
        events, _ = reader.load_events([path], now=NOW)
        self.assertEqual(events[0]["fields"], {"setting": "minisight.style", "chars": 11, "enabled": True})
        report = reader.build_report(events)
        self.assertNotIn("SECRET", json.dumps(report))
        self.assertNotIn("SECRET", reader.render_text(report))
        self.assertEqual(events[1]["result"], "ok")

    def test_bounded_tail_excludes_old_prefix_and_partial_line(self):
        path = self.write("huge.log", line(1) + "X" * (reader.MAX_BYTES + 100) + "\n" + line(2, "reply"))
        events, _ = reader.load_events([path])
        self.assertEqual([e["seq"] for e in events], [2])
        self.assertLessEqual(sum(len(s) for s in reader.bounded_lines(path)), reader.MAX_BYTES)

    def test_malformed_unknown_and_truncated_records_ignored(self):
        path = self.write("bad.log", "not a log\n" + line(1, feature="SECRET_FEATURE") + line(2)[:-8] + "\n" + line(3, fields={"chars": 10**1000}))
        events, _ = reader.load_events([path])
        self.assertEqual([e["seq"] for e in events], [3])
        self.assertEqual(events[0]["fields"], {})

    def test_cli_json_and_unreadable_path_never_echo_path(self):
        path = self.write("input.log", line(1, "show", feature="voice"))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = reader.main([str(path), "--feature", "voice", "--json", "--tail", "1"])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["events"][0]["feature"], "voice")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = reader.main([str(self.directory / "SECRET_MISSING"), "--json"])
        self.assertEqual(status, 2)
        self.assertNotIn("SECRET", output.getvalue())

    def test_legacy_year_rollover_and_relative_since(self):
        now = dt.datetime(2026, 1, 1, 1, tzinfo=dt.timezone.utc)
        self.assertEqual(reader.parse_time("12-31 23:59:00.000", now).year, 2025)
        self.assertLess(abs((dt.datetime.now(reader.UTC) - reader.parse_since("30m")).total_seconds() - 1800), 2)


if __name__ == "__main__":
    unittest.main()
