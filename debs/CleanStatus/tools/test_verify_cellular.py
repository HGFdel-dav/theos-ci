#!/usr/bin/env python3
"""Synthetic signing fixtures only: not a compiled or device-loadable iOS product."""
from pathlib import Path
import hashlib,plistlib,struct,tempfile
from verify_deb import macho,HELPER_ENTITLEMENTS
checks=0
def fixture(ent):
    xml=plistlib.dumps(ent,fmt=plistlib.FMT_XML)
    eb=struct.pack('>II',0xfade7171,8+len(xml))+xml
    cd_size=52+5*32+32;size=28+cd_size+len(eb)
    header=struct.pack('<8I',0xfeedfacf,0x100000c,0x80000002,2,2,40,0,0)
    build=struct.pack('<6I',0x32,24,2,0x0f0500,0x0f0500,0)
    sig=struct.pack('<4I',0x1d,16,256,size);code=(header+build+sig).ljust(256,b'\0')
    cd=struct.pack('>9I4BI',0xfade0c02,cd_size,0x20100,2,212,44,5,1,256,32,2,0,12,0)+b'fixture\0'
    cd+=hashlib.sha256(eb).digest()+bytes(4*32)+hashlib.sha256(code).digest()
    return code+struct.pack('>7I',0xfade0cc0,size,2,0,28,5,28+cd_size)+cd+eb

def case(ent,expected,good):
    global checks
    with tempfile.TemporaryDirectory() as tmp:
        p=Path(tmp)/'helper';p.write_bytes(fixture(ent))
        try:macho(p,expected)
        except (ValueError,struct.error):assert not good,'valid narrowly entitled fixture refused'
        else:assert good,'unapproved helper permission accepted'
        checks+=1
case(HELPER_ENTITLEMENTS,HELPER_ENTITLEMENTS,True)
case(HELPER_ENTITLEMENTS,None,False)
case({},HELPER_ENTITLEMENTS,False)
case({},None,True)
for key in HELPER_ENTITLEMENTS:
    bad=dict(HELPER_ENTITLEMENTS);bad.pop(key);case(bad,HELPER_ENTITLEMENTS,False)
for key,value in [('get-task-allow',True),('com.apple.private.security.no-sandbox',True),('application-identifier','com.apple.Preferences')]:
    bad=dict(HELPER_ENTITLEMENTS);bad[key]=value;case(bad,HELPER_ENTITLEMENTS,False)
bad=dict(HELPER_ENTITLEMENTS);bad['com.apple.CommCenter.fine-grained']=['*'];case(bad,HELPER_ENTITLEMENTS,False)
print(f'PASS cellular verifier: {checks} synthetic precise-entitlement accept/reject fixtures; no artifact supplied.')
