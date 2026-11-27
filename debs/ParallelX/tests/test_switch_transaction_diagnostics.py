import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / 'tests/fixtures'


def _fixture_root(temp):
    # Match the existing writer tests: macOS /var may alias /private/var.
    # Normalize only the synthetic fixture root; keep production checks strict.
    return Path(temp).resolve() / 'Containers/Shared/AppGroup/.jbroot-switch-fixture'


def _fixture_output(value):
    if isinstance(value, bytes):
        return value.decode('utf-8', errors='replace')
    return value or ''


def _run_native(command, label, *, env=None, timeout=15):
    try:
        result = subprocess.run(command, env=env, check=False,
                                capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f'SWITCH_NATIVE {label}: timeout after {timeout}s\n'
            f'stdout:\n{_fixture_output(error.stdout)}\n'
            f'stderr:\n{_fixture_output(error.stderr)}') from None
    if result.returncode != 0:
        raise AssertionError(
            f'SWITCH_NATIVE {label}: returncode={result.returncode}\n'
            f'stdout:\n{_fixture_output(result.stdout)}\n'
            f'stderr:\n{_fixture_output(result.stderr)}')
    print(f'SWITCH_NATIVE {label}: returncode=0', flush=True)
    if result.stdout:
        print(result.stdout, end='', flush=True)
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr, flush=True)
    return result


class SwitchTransactionDiagnosticsTests(unittest.TestCase):
    def test_fixture_root_resolves_temporary_directory_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            actual = Path(temp) / 'actual'
            actual.mkdir()
            alias = Path(temp) / 'alias'
            alias.symlink_to(actual, target_is_directory=True)
            root = _fixture_root(alias)
            root.mkdir(parents=True)
            unresolved = alias / 'Containers/Shared/AppGroup/.jbroot-switch-fixture'
            self.assertEqual(root, root.resolve())
            self.assertEqual(root, _fixture_root(actual))
            self.assertNotEqual(root, unresolved)
            self.assertTrue(root.samefile(unresolved))

    def test_native_runner_rejects_exit_and_signal_with_full_diagnostics(self):
        from unittest import mock
        for code in (23, -6):
            with self.subTest(returncode=code):
                result = subprocess.CompletedProcess(['fixture'], code,
                                                     'stdout-marker\n', 'assertion-marker\n')
                with mock.patch.object(subprocess, 'run', return_value=result) as run:
                    with self.assertRaises(AssertionError) as failure:
                        _run_native(['fixture'], 'full')
                message = str(failure.exception)
                self.assertIn(f'returncode={code}', message)
                self.assertIn('stdout-marker', message)
                self.assertIn('assertion-marker', message)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.kwargs['timeout'], 15)
                self.assertTrue(run.call_args.kwargs['capture_output'])
                self.assertTrue(run.call_args.kwargs['text'])

    def test_native_runner_timeout_preserves_partial_output(self):
        from unittest import mock
        error = subprocess.TimeoutExpired(['fixture'], 15,
                                          output=b'partial-output\n', stderr=b'partial-error\n')
        with mock.patch.object(subprocess, 'run', side_effect=error) as run:
            with self.assertRaises(AssertionError) as failure:
                _run_native(['fixture'], 'restart')
        message = str(failure.exception)
        self.assertIn('timeout after 15s', message)
        self.assertIn('partial-output', message)
        self.assertIn('partial-error', message)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs['timeout'], 15)

    def test_production_portable_policy(self):
        cc = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as temp:
            exe = Path(temp) / 'policy'
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(FIX/'switch_transaction_policy.c'), '-o', str(exe)], check=True, capture_output=True, text=True)
            output = subprocess.check_output([str(exe)], text=True)
            self.assertIn('production_policy_checks=5021', output)

    def test_ios_syntax_production_writer_and_real_host_fixture(self):
        clang = shutil.which('clang')
        sdk = Path('/opt/theos/sdks/iPhoneOS15.5.sdk')
        if not clang or not sdk.exists():
            self.skipTest('iOS SDK syntax-only unavailable; no native execution claimed')
        result = subprocess.run([clang, '-fsyntax-only', '-target', 'arm64e-apple-ios15.0',
            '-isysroot', str(sdk), '-fobjc-arc', '-fblocks', '-Werror',
            str(FIX/'switch_transaction_host.m'), str(ROOT/'Common/PXCloneTrace.m')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_added_process_queries_or_changed_business_waits(self):
        source = (ROOT/'Common/PXCloneLaunch.m').read_text()
        self.assertEqual(source.count('PXProcessPID('), 3)
        self.assertEqual(source.count('PXRunningProcesses('), 6)
        self.assertEqual(source.count('PXRequestTermination(_bundle)'), 3)
        for text in ('_attempt >= 150', '_attempt >= 100', '_attempt >= 30', '_attempt >= 12',
                     '900 * NSEC_PER_MSEC', '45 * NSEC_PER_SEC', '_splitRetries < 2',
                     'PXCloneFlowMaySucceed(&_flow, token, verified, visible)'):
            self.assertIn(text, source)
        self.assertIn('entry[@"monotonic"] = @(CACurrentMediaTime())', source)
        self.assertIn('transactions:_transactions', source)
        helper = (ROOT/'Common/PXCloneTransactionDiagnostics.h').read_text()
        self.assertNotIn('CFAbsoluteTimeGetCurrent', helper)
        self.assertNotIn('NSDate', helper)
        self.assertNotIn('activeContainerForBundle', helper)

    def test_foundation_production_builder_and_persisted_sessions(self):
        xcrun = shutil.which('xcrun')
        if sys.platform != 'darwin' or not xcrun:
            if os.environ.get('PXSWITCH_REQUIRE_NATIVE') == '1' or sys.platform == 'darwin':
                self.fail('native switch transaction fixture REQUIRED: missing macOS/xcrun')
            self.skipTest('macOS Foundation runtime unavailable; set PXSWITCH_REQUIRE_NATIVE=1 to fail closed')
        with tempfile.TemporaryDirectory() as temp:
            root = _fixture_root(temp)
            root.mkdir(parents=True)
            exe = Path(temp)/'switch-host'
            _run_native([xcrun,'clang','-fobjc-arc','-fblocks','-Werror',
                str(FIX/'switch_transaction_host.m'),str(ROOT/'Common/PXCloneTrace.m'),
                '-framework','Foundation','-o',str(exe)], 'compile', timeout=90)
            env = dict(os.environ, PXTRACE_TEST_ROOT=str(root))
            def run(action):
                return _run_native([str(exe),action], action, env=env, timeout=15)
            run('full')
            path=root/'var/mobile/Library/Preferences/fixture.launch-trace.plist'
            doc=plistlib.loads(path.read_bytes())
            self.assertEqual(len(doc['CXLaunchTransactions']),2)
            self.assertEqual(doc['CXLaunchTransactions'][0]['status'],'success')
            self.assertEqual(doc['CXLaunchTransactions'][1]['status'],'in_progress')
            before=doc['CXLaunchTransactions']
            run('legacy')
            self.assertEqual(plistlib.loads(path.read_bytes())['CXLaunchTransactions'],before)
            run('restart')
            doc=plistlib.loads(path.read_bytes())
            self.assertEqual(len(doc['CXLaunchTransactions']),3)
            self.assertNotEqual(doc['CXLaunchTransactions'][0]['session'],doc['CXLaunchTransactions'][2]['session'])
            doc['CXLaunchTransactions']='corrupt'
            path.write_bytes(plistlib.dumps(doc))
            before=path.read_bytes()
            run('corrupt')
            self.assertEqual(path.read_bytes(),before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
