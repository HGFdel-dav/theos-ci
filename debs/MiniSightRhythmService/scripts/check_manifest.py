#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Plugin-only source manifest; never sync/copy capture or App runtime sources.
Default is read-only verification. --refresh changes MANIFEST.json only.
"""
from pathlib import Path
import argparse, hashlib, json

IGNORED = {'__pycache__', '.theos', 'packages', '.git'}
def source_files(root):
    return {str(p.relative_to(root)): p for p in sorted(root.rglob('*'))
            if p.is_file() and p.name != 'MANIFEST.json'
            and not (set(p.relative_to(root).parts) & IGNORED)}
def verify(root):
    root = Path(root)
    m = json.loads((root/'MANIFEST.json').read_text())
    files = source_files(root)
    assert m['format'] == 1 and m['count'] == len(m['files']) == len(files), 'manifest count drift'
    assert set(m['files']) == set(files), 'manifest paths drift'
    for name, p in files.items():
        assert not p.is_symlink(), 'source symlink: '+name
        raw = p.read_bytes()
        assert m['files'][name] == {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}, name
    for name, digest in m['shared_imports'].items():
        assert hashlib.sha256((root/'shared'/name).read_bytes()).hexdigest() == digest, name
    return m

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--service', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--refresh', action='store_true')
    a = p.parse_args(); root = a.service.resolve()
    if a.refresh:
        m = json.loads((root/'MANIFEST.json').read_text())
        files = source_files(root)
        assert all(not x.is_symlink() for x in files.values()), 'source symlink'
        m['files'] = {name: {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                      for name, x in files.items() for raw in [x.read_bytes()]}
        m['count'] = len(files)
        m['scope'] = 'plugin-only unified package build/test adapter; unchanged .57 runtime and shared imports; no artifacts'
        (root/'MANIFEST.json').write_text(json.dumps(m, indent=2, sort_keys=True)+'\n')
    m = verify(root)
    print(json.dumps({'status': 'PASS', 'manifest_files': m['count'], 'manifest_sha256': hashlib.sha256((root/'MANIFEST.json').read_bytes()).hexdigest(), 'refreshed': a.refresh, 'runtime_sync': False}))
if __name__ == '__main__': main()
