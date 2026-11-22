import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('read_launch_diagnostics', ROOT/'tools/read_launch_diagnostics.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class SavedFailureReaderTests(unittest.TestCase):
    def failure(self, time=100.0):
        return {'stage': 'failed', 'time': time, 'code': 19, 'build': 'clone0.100',
                'bundle': 'com.tencent.xin', 'token': 1,
                'failureID': '00000000-0000-0000-0000-000000000001',
                'summary': {'lastOpen': {'poll': 100, 'completionReceived': True,
                            'candidates': [{'firstFailedGateName': 'surface_missing',
                                            'failedMask': 8, 'unknownMask': 0}]}},
                'events': [{'stage': 'open_before_cleanup', 'time': time-0.1}]}

    def test_failure_is_read_from_archive_after_success_overwrites_rolling_trace(self):
        failed = self.failure()
        successes = [{'stage': 'done', 'time': 110.0+i, 'code': 0} for i in range(32)]
        # Actual plist encoding/readback, including an empty-of-failures rolling log.
        doc = plistlib.loads(plistlib.dumps({'CXLaunchTrace': successes, 'CXLaunchFailures': [failed]}))
        result = reader.summarize(doc)
        self.assertEqual(result['timeline_count'], 32)
        self.assertEqual(len(result['failures']), 1)
        row = result['failures'][0]
        self.assertEqual(row['source'], 'archive')
        self.assertTrue(row['has_detailed_observation'])
        self.assertEqual(row['summary']['lastOpen']['candidates'][0]['firstFailedGateName'], 'surface_missing')
        self.assertEqual(row['events'], failed['events'])

    def test_same_failure_in_two_sections_is_only_reported_once(self):
        failed = self.failure()
        result = reader.summarize({'CXLaunchTrace': [failed], 'CXLaunchFailures': [failed]})
        self.assertEqual(len(result['failures']), 1)
        self.assertEqual(result['failures'][0]['source'], 'archive')

    def test_older_build_missing_scene_observations_remains_explicitly_unknown(self):
        old = {'stage': 'failed', 'time': 100.0, 'code': 19, 'token': 1, 'build': 'clone0.95'}
        result = reader.summarize({'CXLaunchTrace': [old]})['failures'][0]
        self.assertFalse(result['has_detailed_observation'])
        self.assertEqual(result['summary'], {})
        self.assertIsNotNone(result['missing_observation_reason'])

    def test_device_pull_uses_current_root_and_only_read_tools(self):
        failed = self.failure()
        data = plistlib.dumps({'CXLaunchTrace': [], 'CXLaunchFailures': [failed]})
        replies = [
            {'result': {'structuredContent': {'jailbreak': {'type': 'roothide',
                'rootPath': '/var/containers/Bundle/Application/.jbroot-CURRENT/'}}}},
            {'result': {'structuredContent': {'encoding': 'base64', 'size': len(data),
                'truncated': False, 'content': base64.b64encode(data).decode()}}},
        ]
        with tempfile.TemporaryDirectory() as temp, patch.object(reader.subprocess, 'check_output',
                side_effect=[json.dumps(x) for x in replies]) as call:
            result = reader.pull_trace('fixture', Path(temp))
            self.assertEqual([item.args[0][3] for item in call.call_args_list], ['get_device_info', 'read_file'])
            requested = json.loads(call.call_args_list[1].args[0][-1])['path']
            self.assertEqual(requested, '/var/mobile/Containers/Shared/AppGroup/.jbroot-CURRENT/'
                                       'var/mobile/Library/Preferences/'+reader.TRACE_NAME)
            self.assertEqual((Path(temp)/reader.TRACE_NAME).read_bytes(), data)
            saved = json.loads((Path(temp)/'launch-diagnostics.json').read_text())
            self.assertEqual(saved['failures'], result['failures'])

    def test_incomplete_file_never_creates_an_evidence_report(self):
        replies = [
            {'jailbreak': {'type': 'roothide', 'rootPath': '/var/containers/Bundle/Application/.jbroot-NEXT/'}},
            {'encoding': 'base64', 'size': 200, 'truncated': True, 'content': ''},
        ]
        with tempfile.TemporaryDirectory() as temp, patch.object(reader, 'mcp_call', side_effect=replies):
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                reader.pull_trace('fixture', Path(temp))
            self.assertEqual(list(Path(temp).iterdir()), [])

    def test_invalid_document_cannot_be_misreported_as_no_failures(self):
        for doc in ([], {}, {'CXLaunchTrace': [], 'CXLaunchFailures': 'broken'},
                    {'CXLaunchTrace': [], 'CXLaunchFailures': ['broken row']},
                    {'CXLaunchTrace': [], 'CXLaunchFailures': [{'stage': 'done'}]}):
            with self.subTest(doc=doc), self.assertRaises(ValueError):
                reader.summarize(doc)


if __name__ == '__main__':
    unittest.main()
