#!/usr/bin/env python3
"""Real source-guard execution, including mutations; no native/UI claim."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
P = Path(__file__).resolve().parents[1]
GUARD = P / 'tests/check_name_wake_remote_20261116.py'

class SourceGuardTests(unittest.TestCase):
    def invoke(self, script, *args):
        return subprocess.run([sys.executable, str(script), *map(str, args)], capture_output=True, text=True, timeout=30)

    def test_plugin_ci_keeps_behavior_guards(self):
        result = self.invoke(GUARD, '--plugin-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('explicitly plugin-only', result.stdout)

    def test_same_tree_is_not_mirror_evidence(self):
        result = self.invoke(GUARD, P)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('distinct tree', result.stderr)
        result = self.invoke(GUARD, '--plugin-only', P)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cannot masquerade', result.stderr)

    def test_behavior_and_whole_file_mirror_mutants_rejected(self):
        with tempfile.TemporaryDirectory(prefix='ms-wake-guards-') as temporary:
            root = Path(temporary) / 'plugin'
            (root / 'tests').mkdir(parents=True)
            shutil.copy2(GUARD, root / 'tests' / GUARD.name)
            for name in ('MiniSightNameWakeHost.h', 'MiniSightNameWakeBridge.m', 'MiniSightNameWakeState.h', 'Tweak.xm',
                         'Makefile', 'MiniSightChatPanel.m', 'MiniSightChatPanel.h', 'MiniSightResources.m'):
                shutil.copy2(P / name, root / name)
            script = root / 'tests' / GUARD.name
            baseline = self.invoke(script, '--plugin-only')
            self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)
            mirror = Path(temporary) / 'app'
            mirror.mkdir()
            for name in ('MiniSightChatPanel.m', 'MiniSightChatPanel.h', 'MiniSightResources.m'):
                shutil.copy2(root / name, mirror / name)
            invalid = self.invoke(script, mirror)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn('independent App panel layout retained', invalid.stderr)
            panel = root / 'MiniSightChatPanel.m'
            source = panel.read_text()
            for old, new in (('self.panelBoost > 1. ? 1. : 1.35', '1.'),
                             ('* self.panelBoost', '* 1.'),
                             ('MIN(self.panelBoost, 1.2)', '1.')):
                self.assertIn(old, source)
                panel.write_text(source.replace(old, new))
                mutant = self.invoke(script, '--plugin-only')
                self.assertNotEqual(mutant.returncode, 0)
                self.assertIn('old plugin panel boost behavior retained', mutant.stderr)
            panel.write_text(source)

if __name__ == '__main__':
    unittest.main(verbosity=2)
