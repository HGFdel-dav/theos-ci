#!/usr/bin/env python3
"""Offline evidence extraction only; never loads or executes Mach-O/iOS code."""
import hashlib, json, pathlib, re, struct, sys
base = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                    '/var/minis/workspace/MiniSight-local-review/evidence')
b = (base / 'recorder-ReplayKit-ios15.0').read_bytes()
assert hashlib.sha256(b).hexdigest() == '76d3930b593449c37cd403d07f68c6d392d7a0beb17f7e6b6c1a327cfe660bd4'
u32 = lambda p: struct.unpack_from('<I', b, p)[0]
u64 = lambda p: struct.unpack_from('<Q', b, p)[0]
assert u32(0) == 0xfeedfacf
segments, p = [], 32
for _ in range(u32(16)):
    cmd, size = struct.unpack_from('<II', b, p)
    if cmd == 0x19:
        vm, vs, fo, fs = struct.unpack_from('<QQQQ', b, p + 24)
        segments.append((vm, fs, fo))
    p += size

def off(a):
    for vm, size, fo in segments:
        if vm <= a < vm + size:
            return fo + a - vm
    raise ValueError(hex(a))

def text(a):
    p = off(a)
    return b[p:b.index(b'\0', p)].decode('utf8')

s = (base / 'ReplayKit-ios15.0.objc.txt').read_text()
methods = {}
for typ, imp, name in re.findall(r'types [^\n]*\((0x[0-9a-f]+)\)\s+imp [^\n]*\((0x[0-9a-f]+)\) ([^\n]+)', s):
    if 'RPScreenRecorder' in name:
        methods[name] = {'encoding': text(int(typ, 16) | 0x100000000),
                         'imp': hex(int(imp, 16) | 0x100000000)}
expected = {'+[RPScreenRecorder sharedRecorder]': '@16@0:8',
 '-[RPScreenRecorder isRecording]': 'B16@0:8',
 '-[RPScreenRecorder isAvailable]': 'B16@0:8',
 '-[RPScreenRecorder screenRecordingAllowed]': 'B16@0:8',
 '-[RPScreenRecorder screenRecordingSupportedOnDevice]': 'B16@0:8',
 '-[RPScreenRecorder isMicrophoneEnabled]': 'B16@0:8',
 '-[RPScreenRecorder setMicrophoneEnabled:]': 'v20@0:8B16',
 '-[RPScreenRecorder setRecording:]': 'v20@0:8B16',
 '-[RPScreenRecorder systemRecording]': 'B16@0:8',
 '-[RPScreenRecorder startSystemRecordingWithMicrophoneEnabled:handler:]': 'v28@0:8B16@?20',
 '-[RPScreenRecorder stopSystemRecordingWithURLHandler:]': 'v24@0:8@?16'}
for name, enc in expected.items():
    assert methods[name]['encoding'] == enc, (name, methods.get(name))
# Descriptors have copy/dispose entries; signature pointer follows them at +32.
descriptors = {}
for a in (0x1ebe0e140, 0x1ebe0e200, 0x1ebe0e320):
    p = off(a)
    descriptors[hex(a)] = {'size': u64(p + 8), 'signature': text(u64(p + 32))}
assert descriptors['0x1ebe0e320']['signature'] == 'v16@?0@"NSError"8'
assert descriptors['0x1ebe0e200']['signature'] == 'v24@?0@"NSURL"8@"NSError"16'
selectors = {}
for a in (0x1f2bea4b8, 0x1f2bea528, 0x1f2bea688, 0x1f2bea6a0, 0x1f2bea6b8):
    selectors[hex(a)] = text(u64(off(a)))
assert selectors['0x1f2bea528'] == 'stopSystemRecordingWithURLHandler:'
assert selectors['0x1f2bea6b8'].startswith('startSystemRecordingWithContextID:')
assert selectors['0x1f2bea6a0'] == 'setWindowToRecord:'
print(json.dumps({'binary_sha256': hashlib.sha256(b).hexdigest(),
 'methods': {n: methods[n] for n in expected}, 'block_descriptors': descriptors,
 'selectors': selectors, 'note': '15.0 static evidence, not a 15.5 device test'},
 ensure_ascii=False, indent=2))
