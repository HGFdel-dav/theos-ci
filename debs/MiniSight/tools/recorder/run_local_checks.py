#!/usr/bin/env python3
"""Local source + Linux C checks ONLY. Never invokes Theos, an iOS compiler or device."""
import hashlib, json, pathlib, re, shutil, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / 'MiniSightRecorder.m').read_text()
header = (root / 'MiniSightRecorder.h').read_text()
core = (root / 'tools/recorder/MiniSightRecorderCore.h').read_text()
files = (root / 'tools/recorder/MiniSightRecorderFile.h').read_text()
results = {}

def check(name, condition):
    if not condition:
        raise AssertionError(name)
    results[name] = 'PASS'

def code_only(text):
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', ' ', text, flags=re.S)

def balanced(text):
    stack, closes = [], {')':'(', ']':'[', '}':'{'}
    for char in code_only(text):
        if char in '([{': stack.append(char)
        elif char in closes:
            if not stack or stack.pop() != closes[char]: return False
    return not stack

check('objc_delimiters', balanced(source) and balanced(header))
for name, text in [('implementation', source), ('header', header)]:
    check('objc_sections_' + name,
          len(re.findall(r'@(interface|implementation|protocol)\b', text)) ==
          len(re.findall(r'@end\b', text)))
check('only_system_backend', all(x not in source for x in (
    'startRecordingWithHandler:', 'stopRecordingWithOutputURL:', 'startCaptureWithHandler:',
    'NSInvocation', 'performSelector', 'method_getImplementation')))
check('no_delegate_or_fake_state_mutation', not re.search(
    r'\[_system\s+(setRecording|setSystemRecording|setWindowToRecord|setDelegate)', source))
check('typed_start_block', 'handler:(void (^)(NSError *error))handler;' in source)
check('typed_url_stop_block',
      'stopSystemRecordingWithURLHandler:(void (^)(NSURL *url, NSError *error))handler;' in source)
check('one_system_start_call', len(re.findall(r'\[_system startSystemRecordingWithMicrophoneEnabled:', source)) == 1)
check('one_system_stop_call', len(re.findall(r'\[_system stopSystemRecordingWithURLHandler:', source)) == 1)
check('runtime_abi_checks', all(x in source for x in (
    'method_getNumberOfArguments', 'method_copyReturnType', 'method_copyArgumentType',
    'MSRBackendABI(object_getClass(_system))', '"B", "@?"', '"v", 4, start', '"v", 3, stop')))
check('springboard_ios15_5_gate', 'os.majorVersion != 15 || os.minorVersion != 5' in source and
      'com.apple.springboard' in source)
check('ownership_continuity', all(x in source for x in (
    'atomic_fetch_add(&_recordingDrops, 1)', '!s.continuous', '!s.recording || !s.system',
    'UIScreenCapturedDidChangeNotification', 'forKeyPath:@"recording"')))
check('main_and_continuous_clock', 'mach_continuous_time()' in source and 'dispatch_sync' not in source and
      source.count('if (![NSThread isMainThread])') >= 7)
check('validated_video_not_stop_equals_saved', all(x in source for x in (
    'loadValuesAsynchronouslyForKeys:', 'AVKeyValueStatusLoaded', 'CMTIME_IS_NUMERIC',
    'asset.playable', 'tracksWithMediaType:AVMediaTypeVideo', 'isfinite(duration)', 'bytes >= 1024')))
check('actual_posix_artifact_checks', all(x in files for x in (
    'O_NOFOLLOW', 'O_EXCL', 'fsync(out)', 'linkat(', 'a.st_ino == b.st_ino', 'atomic_load(cancelled)')))
check('no_recorder_logging_or_credentials', all(x not in source for x in (
    'NSLog', 'os_log', 'getenv', 'system(', 'popen(', 'localizedDescription')))
check('shared_production_reducer', '#include "tools/recorder/MiniSightRecorderCore.h"' in header)
check('timeout_and_ten_minutes', all(x in core for x in ('+ 15.0', '+ 30.0', '+ 60.0', '>= 600.0', '< 0.35')))
check('singleton_only', '- (instancetype)init NS_UNAVAILABLE;' in header and '+ (instancetype)new NS_UNAVAILABLE;' in header)

native = {}
with tempfile.TemporaryDirectory(prefix='minisight-recorder-check-', dir='/tmp') as temporary:
    for name in ('gcc', 'clang'):
        compiler = shutil.which(name)
        if not compiler:
            native[name] = 'UNAVAILABLE'; continue
        binary = pathlib.Path(temporary) / name
        built = subprocess.run([compiler, '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
            str(root / 'tests/recorder/recorder_test.c'), '-o', str(binary)],
            capture_output=True, text=True, timeout=120)
        if built.returncode: raise RuntimeError(built.stderr)
        check('native_linux_elf_' + name, binary.read_bytes()[:4] == b'\x7fELF')
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        if ran.returncode: raise RuntimeError(ran.stderr)
        native[name] = ran.stdout.strip()

output = pathlib.Path(sys.argv[1] if len(sys.argv)>1 else
    '/var/minis/workspace/MiniSight-local-review/recorder-checks/checks.json')
output.parent.mkdir(parents=True, exist_ok=True)
report = {'scope': 'source policies + native Linux C, NOT iOS compilation/device validation',
          'static_checks': results, 'native_c': native,
          'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (root/'MiniSightRecorder.h', root/'MiniSightRecorder.m',
                      root/'tools/recorder/MiniSightRecorderCore.h', root/'tools/recorder/MiniSightRecorderFile.h')}}
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print('PASS:', len(results), 'static/ELF policies')
for name, text in native.items(): print(name + ': ' + text)
