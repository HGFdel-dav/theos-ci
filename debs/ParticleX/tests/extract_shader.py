#!/usr/bin/env python3
from pathlib import Path
import re,json,sys
r=Path(__file__).resolve().parents[1]
s=(r/'Sources/PXCDustShader.h').read_text()
embedded=(r/'Sources/PXCDustMotionSource.h').read_text().split('#define PXC_DUST_MOTION_METAL_SOURCE',1)[1]
# Expand only this known local macro before decoding the adjacent literals.
s=s.replace('     PXC_DUST_MOTION_METAL_SOURCE',embedded)
start=s.index('    @"')
literals=re.findall(r'@?("(?:\\.|[^"\\])*")',s[start:])
metal=''.join(json.loads(x) for x in literals)
assert 'vertex PXVertexOut px_dust_vertex' in metal and 'fragment float4 px_dust_fragment' in metal
p=Path(sys.argv[1]);p.write_text(metal)
print('Extracted Metal shader:',len(metal),'bytes')
