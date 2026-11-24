#!/usr/bin/env python3
"""Generate a Foundation-only TU from ACTUAL candidate bodies; stream to clang.
Default/local mode is syntax-only. --native is deliberately macOS-only.
No iOS code generation, hook installation, network, push, CI or device calls.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
DEFAULT_SOURCE = HERE.parent
METHODS = ('unbind', 'bindingFailureForButton', 'logBindingFailure',
           'safeDirectButton', 'entryReady', 'shouldBeginPressedGesture',
           'shouldYieldForGesture', 'ownsPreview', 'scheduleLayoutRebind',
           'syncWindowPress', 'bindAfterLayout', 'bind', 'pressed', 'dealloc')
HELPERS = ('LCSVisible', 'LCSDirectTouch', 'LCSExpansionForState',
           'LCSGestureKind', 'LCSGestureStateSlug', 'LCSTop',
           'LCSFindButton', 'LCSTapContract')
CALLBACKS = ('LCSState', 'LCSLoaded', 'LCSAppeared', 'LCSDisappeared',
             'LCSLayoutSubviews', 'LCSWillExpand', 'LCSRoundDidMoveToWindow',
             'LCSCellularOwnsRoundGesture', 'LCSRoundGestureShouldBegin',
             'LCSPreviewShouldBegin', 'LCSReconcile')
GLOBALS = ('LCSCellularStateKey', 'LCSNativeCellularClass', 'LCSHookMask',
           'LCSRequiredHookMask', 'LCSCellularStates', 'LCSPresentedSIM',
           'LCSPreviewHookReady', 'LCSOriginalPreviewShouldBegin',
           'LCSOriginalExpanded', 'LCSOriginalRoundGestureShouldBegin',
           'LCSOriginalRoundDidMoveToWindow', 'LCSOriginalLoad',
           'LCSOriginalAppear', 'LCSOriginalDisappear', 'LCSOriginalLayout')


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def exactly(pattern, text):
    matches = list(re.finditer(pattern, text, re.M))
    if len(matches) != 1:
        raise ValueError(f'extraction must be unique ({len(matches)}): {pattern}')
    return matches[0]


def block(text, start, opening):
    # Brace matching excludes strings, character literals and both comment kinds.
    depth, i, mode = 0, opening, 'code'
    while i < len(text):
        ch, pair = text[i], text[i:i+2]
        if mode == 'line':
            if ch == '\n': mode = 'code'
        elif mode == 'comment':
            if pair == '*/': mode, i = 'code', i+1
        elif mode in ('"', "'"):
            if ch == '\\': i += 1
            elif ch == mode: mode = 'code'
        elif pair == '//': mode, i = 'line', i+1
        elif pair == '/*': mode, i = 'comment', i+1
        elif ch in ('"', "'"): mode = ch
        elif ch == '{': depth += 1
        elif ch == '}':
            depth -= 1
            if not depth: return text[start:i+1]
        i += 1
    raise ValueError('unterminated Objective-C body')


def generate(source):
    hooks = source / 'Cellular/LCSCellularHooks.m'
    policy = source / 'Cellular/LCSCellularEntryPolicy.h'
    original = hooks.read_text()
    policy_text = policy.read_text()
    manifest = {'source': str(hooks), 'source_sha256': sha(original),
                'policy_sha256': sha(policy_text), 'extracted': {}}
    def copied(label, content):
        manifest['extracted'][label] = sha(content)
        return '\n// EXACT EXTRACT: ' + label + '\n' + content + '\n'
    def section(kind, name):
        m = exactly(r'^@' + kind + r' ' + name + r'\b[^\n]*[\s\S]*?^@end', original)
        return m.group()
    def function(name):
        m = exactly(r'^static [^\n]*?\b' + name + r'\([^;{}]*\)\s*\{', original)
        return copied(name, block(original, m.start(), m.end()-1))
    state = section('implementation', 'LCSCellularButtonState')
    bodies = []
    for name in METHODS:
        m = exactly(r'^- \([^)]*\)' + name + r'(?=[\s:{])[^;{}]*\{', state)
        bodies.append(copied('state.' + name, block(state, m.start(), m.end()-1)))
    globals_text = []
    for name in GLOBALS:
        m = exactly(r'^static [^\n;]*\b' + name + r'\b[^\n]*;', original)
        globals_text.append(copied('global.' + name, m.group()))
    template = (source / 'tests/cellular/binding_fallback_native.m').read_text()
    marker = '// NF_PRODUCTION_METHODS_INSERT_HERE\n'
    if template.count(marker) != 1: raise ValueError('fixture insertion marker must be unique')
    fake, driver = template.split(marker)
    manifest.update(fake_sha256=sha(fake), driver_sha256=sha(driver))
    diagnostics = '''
// Explicit diagnostic-only stubs. No competing binding/route implementation.
- (void)traceGesture:(UIGestureRecognizer *)gesture phase:(NSString *)phase {(void)phase;if(gesture)NFTraces++;}
- (void)logGestureInventory {NFInventories++;}
- (void)receivedTouch:(UIGestureRecognizer *)gesture {if(gesture==self.directPress||gesture==self.windowPress)NFReceived++;}
'''
    tu = (fake + '\n#pragma clang diagnostic push\n'
          '#pragma clang diagnostic ignored "-Wpragma-once-outside-header"\n'
          + copied('entry-policy-header', policy_text)
          + '\n#pragma clang diagnostic pop\n' + ''.join(globals_text)
          + '\n@class LCSCellularButtonState;\n'
          + copied('press-target-interface', section('interface', 'LCSCellularPressTarget'))
          + copied('state-interface', section('interface', 'LCSCellularButtonState'))
          + ''.join(function(name) for name in HELPERS)
          + copied('press-target-implementation', section('implementation', 'LCSCellularPressTarget'))
          + '\n@implementation LCSCellularButtonState\n' + ''.join(bodies)
          + diagnostics + '\n@end\n' + ''.join(function(name) for name in CALLBACKS)
          + '\n' + driver)
    manifest['translation_unit_sha256'] = sha(tu)
    return tu, manifest, hooks, original, policy, policy_text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--syntax-only', action='store_true')
    mode.add_argument('--native', action='store_true')
    mode.add_argument('--emit', action='store_true', help='write generated TU to stdout')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.native and sys.platform != 'darwin':
        print('NOT RUN: native Foundation execution requires macOS; Alpine cannot execute this fixture.', file=sys.stderr)
        return 77
    tu, report, hooks, original, policy, policy_text = generate(args.source.resolve())
    if args.emit:
        sys.stdout.write(tu)
        return 0
    flags = ['-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror', '-x', 'objective-c', '-']
    if args.native:
        build_dir = tempfile.TemporaryDirectory(prefix='lcs315-foundation-')
        binary = Path(build_dir.name) / 'binding_native'
        cmd = ['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', *flags,
               '-framework', 'Foundation', '-o', str(binary)]
        report['mode'] = 'macOS native Foundation fake objects (not UIKit/device)'
    else:
        sdk = Path('/opt/theos/sdks/iPhoneOS15.5.sdk')
        clang = shutil.which('clang')
        if not clang or not sdk.is_dir():
            print('NOT RUN: local clang/iOS15.5 SDK missing.', file=sys.stderr)
            return 77
        cmd = [clang, '-fsyntax-only', '-target', 'arm64e-apple-ios15.5',
               '-isysroot', str(sdk), *flags]
        report['mode'] = 'Alpine syntax-only; no codegen/link/native execution'
    process = subprocess.run(cmd, input=tu, text=True, capture_output=True, timeout=240)
    report.update(command=cmd, compile_exit=process.returncode,
                  diagnostics=process.stdout + process.stderr,
                  native_executed=False, native_exit=None)
    stable = hooks.read_text() == original and policy.read_text() == policy_text
    report['production_inputs_unchanged_during_check'] = stable
    if args.native and process.returncode == 0 and stable:
        execution = subprocess.run([str(binary)], text=True, capture_output=True, timeout=60)
        report.update(native_executed=True, native_exit=execution.returncode,
                      native_stdout=execution.stdout, native_stderr=execution.stderr)
        driver=(args.source/'tests/cellular/binding_fallback_native.m').read_text()
        table=re.search(r'const char \*names\[\]=\{([^}]+)\};',driver)
        expected=re.findall(r'"([^"]+)"',table.group(1)) if table else []
        passed=[line[5:] for line in execution.stdout.splitlines() if line.startswith('PASS ') and line[5:] in expected]
        complete=len(expected)==9 and all(passed.count(name)==1 for name in expected)
        report.update(expected_groups=expected,reported_groups=passed,all_groups_reported_once=complete)
        if execution.returncode==0 and not complete:
            report['native_exit']=3
            print('FAIL: native fixture did not report every declared group exactly once.')
        print(execution.stdout + execution.stderr, end='')
    filename = 'native_result.json' if args.native else 'syntax_result.json'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if process.stdout or process.stderr:
        print(process.stdout + process.stderr, end='')
    if not stable:
        print('INVALIDATED: production input changed during check; rerun against current snapshot.')
        return 3
    if process.returncode: return process.returncode
    if args.native: return report['native_exit']
    print('PASS syntax-only (exit 0); 9 native assertion groups NOT EXECUTED; no iOS machine code generated.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f'FAIL fixture generator: {error}', file=sys.stderr)
        sys.exit(2)
