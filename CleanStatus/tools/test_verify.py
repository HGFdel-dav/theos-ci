#!/usr/bin/env python3
"""Synthetic Mach-O parsing tests only, not a compiled iOS binary."""
from pathlib import Path
import hashlib, struct, tempfile
from verify_deb import macho
checks=0
def fixture():
    header=struct.pack('<8I',0xfeedfacf,0x100000c,0x80000002,6,2,40,0,0)
    build=struct.pack('<6I',0x32,24,2,0x0f0500,0x0f0500,0)
    sig=struct.pack('<4I',0x1d,16,256,104)
    code=(header+build+sig).ljust(256,b'\0')
    cd=struct.pack('>9I4BI',0xfade0c02,84,0x20100,2,52,44,0,1,256,32,2,0,12,0)
    cd+=b'fixture\0'+hashlib.sha256(code).digest()
    superblob=struct.pack('>5I',0xfade0cc0,104,1,0,20)+cd
    return code+superblob
def try_case(b,good,label):
    global checks
    with tempfile.TemporaryDirectory(prefix='lcs-verify-test-') as temp:
        p=Path(temp)/'synthetic.dylib';p.write_bytes(b)
        try: result=macho(p)
        except (ValueError,struct.error,IndexError,UnicodeError):
            assert not good,label+' unexpectedly rejected'
        else:
            assert good,label+' incorrectly accepted'
            assert result['architecture']=='arm64e'
        checks+=1
b=fixture();try_case(b,True,'valid signature')
for offset in (0,4,8,16,20,32,36,40,44,48,56,60,64,68,100,255,256,260,264,268,272,276,280,292,300,304,308,309,311,313,315,359):
    bad=bytearray(b);bad[offset]^=0xff;try_case(bad,False,'corruption at '+str(offset))
for length in (0,4,20,31,32,40,70,255,256,260,275,300,359):
    try_case(b[:length],False,'truncation '+str(length))
print(f'PASS verifier: {checks} synthetic accept/reject tests; no compiled artifact supplied.')
