"""Compile the CURRENT production module; never emulate its observer logic.
Linux: strict whole-fixture iOS 15.5 syntax only, native behavior SKIP.
Darwin: xcrun + Foundation, six executable cases. No UIKit, CI or device.
PXWM_REQUIRE_NATIVE=1 and Darwin without xcrun fail closed.
"""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/window_input_adapter'
SOURCE = ROOT / 'Common/PXWindowInputDiagnostics.m'
CASES = ('scope', 'forward_exceptions', 'phases_privacy', 'disabled',
         'close_generation', 'rate_unknown_abi')


def generate(destination):
    source = SOURCE.read_bytes()
    # Remove imports only. All production classes/functions, including install,
    # are compiled unmodified in the same translation unit as the assertions.
    body = re.sub(r'^\s*#import[^\n]*', '', source.decode(), flags=re.M)
    text = '#import "fake.h"\n#line 1 "' + str(SOURCE) + '"\n' + body
    text += '\n#line 1 "cases.m"\n' + (FIXTURE / 'cases.m').read_text()
    destination.write_text(text)
    for path in (SOURCE, ROOT / 'Common/PXWindowInputPolicy.h',
                 ROOT / 'Common/PXWindowMemoryPolicy.h', FIXTURE / 'fake.h', FIXTURE / 'cases.m'):
        digest = hashlib.sha256(source if path == SOURCE else path.read_bytes()).hexdigest()
        print(f'INPUT_SOURCE sha256={digest} path={path}', flush=True)


def run(command):
    print('+ ' + shlex.join(map(str, command)), flush=True)
    result = subprocess.run(command, text=True, capture_output=True, timeout=90)
    print(f'RETURNCODE={result.returncode}', flush=True)
    if result.stdout:
        print(result.stdout, end='', flush=True)
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr, flush=True)
    if result.returncode:
        raise AssertionError(f'command exited {result.returncode}')
    return result


@contextmanager
def build_directory():
    directory = Path(tempfile.mkdtemp(prefix='.build-', dir=FIXTURE))
    try:
        yield directory
    finally:
        # Shared iSH mount does not implement fd-safe rmtree inode checks.
        for child in directory.iterdir():
            child.unlink()
        directory.rmdir()


class WindowInputAdapter(unittest.TestCase):
    def test_whole_fixture_ios155_strict_syntax(self):
        if sys.platform == 'darwin':
            self.skipTest('Linux syntax lane; Darwin executes Foundation below')
        clang = shutil.which('clang')
        sdk = Path('/opt/theos/sdks/iPhoneOS15.5.sdk')
        self.assertTrue(clang, 'clang missing; no tools are installed automatically')
        self.assertTrue((sdk / 'SDKSettings.plist').exists(), 'iOS 15.5 SDK missing')
        with build_directory() as directory:
            generated = directory / 'adapter.m'
            generate(generated)
            run([clang, '-target', 'arm64-apple-ios15.5', '-isysroot', str(sdk),
                 '-fobjc-arc', '-fblocks', '-fsyntax-only', '-Wall', '-Wextra', '-Werror',
                 '-I' + str(ROOT / 'Common'), '-I' + str(FIXTURE), str(generated)])

    def test_native_foundation_behavior(self):
        xcrun = shutil.which('xcrun')
        if sys.platform != 'darwin' or not xcrun:
            reason = 'native behavior SKIP: macOS Foundation + xcrun required; syntax is not behavior'
            if sys.platform == 'darwin' or os.environ.get('PXWM_REQUIRE_NATIVE') == '1':
                self.fail(reason)
            self.skipTest(reason)
        with build_directory() as directory:
            generated = directory / 'adapter.m'
            executable = directory / 'adapter'
            generate(generated)
            run([xcrun, '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
                 '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                 '-I' + str(ROOT / 'Common'), '-I' + str(FIXTURE),
                 str(generated), '-o', str(executable)])
            for case in CASES:
                with self.subTest(case=case):
                    result = run([str(executable), case])
                    self.assertRegex(result.stdout, rf'^PASS {case} checks=[1-9][0-9]*\s*$')


if __name__ == '__main__':
    unittest.main(verbosity=2)
