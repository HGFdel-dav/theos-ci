#!/usr/bin/env python3
"""Local-only plugin diff against the delivered 0.3.5 commit."""
import pathlib, subprocess
ROOT = pathlib.Path('/var/minis/workspace/MiniSight-repair')
BASE = '861868d5e76f9e8dc9a6a6be7dbe38a6fdfd0a1e'
OUT = ROOT / 'patches'
OUT.mkdir(exist_ok=True)
# Intent-to-add so brand-new files appear in `git diff` without committing.
subprocess.run(['git', '-C', str(ROOT), 'add', '-N', 'debs/MiniSight'], check=True)
changed = subprocess.check_output(
    ['git', '-C', str(ROOT), 'diff', '--name-only', BASE, '--', 'debs/MiniSight', '.github/workflows/build-minisight.yml'],
    text=True).splitlines()
assert changed, 'no plugin changes'
for rel in changed:
    patch = subprocess.check_output(['git', '-C', str(ROOT), 'diff', BASE, '--', rel], text=True)
    name = 'plugin-' + rel.replace('/', '__') + '.patch'
    (OUT / name).write_text(patch)
    print(name, len(patch), 'bytes')
print('changed files:', len(changed))
