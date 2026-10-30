"""Embed the shared C/Metal wind math as an Objective-C string macro."""
from pathlib import Path
import json, sys
ROOT = Path(__file__).resolve().parent

def motion_source_text():
    lines = (ROOT / 'Sources/PXCDustMotion.h').read_text().splitlines(keepends=True)
    body = ['#pragma once', '// Generated: run generate_motion_source.py after changing PXCDustMotion.h.',
            '#define PXC_DUST_MOTION_METAL_SOURCE \\']
    body.extend('    ' + json.dumps(line) + (' \\' if i < len(lines)-1 else '')
                for i, line in enumerate(lines))
    return '\n'.join(body) + '\n'

if __name__ == '__main__':
    target = ROOT / 'Sources/PXCDustMotionSource.h'
    text = motion_source_text()
    if '--check' in sys.argv:
        assert target.read_text() == text, 'Embedded GPU motion math is stale'
        print('PASS shared C/Metal motion source identity')
    else:
        target.write_text(text)
        print('Generated', target.name, len(text), 'bytes; no build or push')
