#!/usr/bin/env python3
"""Offline MSL syntax check with a tiny stdlib stub. Not a replacement for
Xcode's Metal compiler; catches type/swizzle errors that plain grep misses."""
from pathlib import Path
import json,re,subprocess,tempfile,sys
R=Path(__file__).resolve().parents[1]
s=(R/'Sources/PXCDustShader.h').read_text()
embedded=(R/'Sources/PXCDustMotionSource.h').read_text().split('#define PXC_DUST_MOTION_METAL_SOURCE',1)[1]
s=s.replace('     PXC_DUST_MOTION_METAL_SOURCE',embedded)
start=s.index('    @"')
literals=re.findall(r'@?("(?:\\.|[^"\\])*")',s[start:])
metal=''.join(json.loads(x) for x in literals)
assert 'vertex PXVertexOut px_dust_vertex' in metal
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'shader.metal';p.write_text(metal)
 cmd=['clang++','-x','c++','-std=c++17','-D__METAL_VERSION__','-fsyntax-only',
      '-Wno-unknown-attributes','-I'+str(R/'tests'),str(p)]
 subprocess.run(cmd,check=True)
print('PASS MSL syntax stub:',len(metal),'bytes')
