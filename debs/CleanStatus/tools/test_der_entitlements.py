#!/usr/bin/env python3
"""Synthetic DER and CodeDirectory tests; never AMFI/runtime proof."""
from pathlib import Path
import hashlib,plistlib,struct,tempfile
from der_entitlements import decode_der_entitlements
from verify_deb import macho,HELPER_ENTITLEMENTS
checks=0
def need(value,label):
 global checks
 if not value:raise AssertionError(label)
 checks+=1
def tlv(tag,data):
 n=len(data);length=bytes([n]) if n<128 else bytes([128+(n.bit_length()+7)//8])+n.to_bytes((n.bit_length()+7)//8,'big')
 return bytes([tag])+length+data
def string(value):return tlv(12,value.encode())
def encode(values):
 entries=[]
 for key,v in values.items():
  raw=tlv(1,bytes([1 if v else 0])) if isinstance(v,bool) else tlv(48,b''.join(string(x) for x in v)) if isinstance(v,list) else string(v)
  entries.append(tlv(48,string(key)+raw))
 return tlv(49,b''.join(sorted(entries)))
def reject(raw):
 try:decode_der_entitlements(raw)
 except (ValueError,UnicodeError):need(True,'expected DER refusal')
 else:need(False,'malformed DER accepted')
raw=encode(HELPER_ENTITLEMENTS);need(decode_der_entitlements(raw)==HELPER_ENTITLEMENTS,'expected entitlement map')
for length in range(len(raw)):reject(raw[:length])
for bad in [raw+b'\0',b'\x31\x80\0\0',b'\x31\x81'+raw[1:],b'\x31\x82\0'+raw[1:],b'\x31\x83\0\0'+raw[1:]]:reject(bad)
for tag in [2,3,4,5,6,16,48,127,255]:reject(bytes([tag])+raw[1:])
pair=tlv(48,string('duplicate')+tlv(1,b'\x01'));reject(tlv(49,pair+pair))
for bad in [b'',b'\x02',b'\0\x01',b'\x01\0']:
 reject(tlv(49,tlv(48,string('boolean')+tlv(1,bad))))
reject(tlv(49,tlv(48,string('key')+tlv(48,tlv(1,b'\x01')))))
reject(tlv(49,tlv(48,string('key')+string('a')+string('b'))))
reject(tlv(49,tlv(48,tlv(12,b'\xff')+string('value'))))
reject(tlv(49,tlv(48,string('bad\nkey')+string('value'))))

def fixture(der_values=None,xml_values=None,raw_der=None,nsp=7):
 xml=plistlib.dumps(HELPER_ENTITLEMENTS if xml_values is None else xml_values)
 eb=struct.pack('>II',0xfade7171,8+len(xml))+xml
 der=raw_der if raw_der is not None else encode(HELPER_ENTITLEMENTS if der_values is None else der_values)
 db=struct.pack('>II',0xfade7172,8+len(der))+der
 cd_size=52+nsp*32+32;size=36+cd_size+len(eb)+len(db)
 code=(struct.pack('<8I',0xfeedfacf,0x100000c,0x80000002,2,2,40,0,0)+struct.pack('<6I',0x32,24,2,0x0f0500,0x0f0500,0)+struct.pack('<4I',0x1d,16,256,size)).ljust(256,b'\0')
 cd=struct.pack('>9I4BI',0xfade0c02,cd_size,0x20100,2,52+nsp*32,44,nsp,1,256,32,2,0,12,0)+b'fixture\0'
 cd+=b''.join(hashlib.sha256(db if i==7 else eb).digest() if i in (5,7) else bytes(32) for i in range(nsp,0,-1))+hashlib.sha256(code).digest()
 return code+struct.pack('>9I',0xfade0cc0,size,3,0,36,5,36+cd_size,7,36+cd_size+len(eb))+cd+eb+db

def macho_case(data,expected,good):
 with tempfile.TemporaryDirectory() as tmp:
  f=Path(tmp)/'synthetic';f.write_bytes(data)
  try:r=macho(f,expected)
  except (ValueError,UnicodeError,struct.error,IndexError):need(not good,'expected signed fixture refused')
  else:
   need(good,'bad signed fixture accepted')
   if good:need(r['der_entitlements']==r['entitlements']==[HELPER_ENTITLEMENTS],'both permissions validated')
macho_case(fixture(),HELPER_ENTITLEMENTS,True);macho_case(fixture(),None,False)
bad=dict(HELPER_ENTITLEMENTS);bad['get-task-allow']=True
macho_case(fixture(der_values=bad),HELPER_ENTITLEMENTS,False)
macho_case(fixture(xml_values=bad),HELPER_ENTITLEMENTS,False)
macho_case(fixture(raw_der=raw+b'\0'),HELPER_ENTITLEMENTS,False)
macho_case(fixture(nsp=5),HELPER_ENTITLEMENTS,False)
b=bytearray(fixture());b[-1]^=1;macho_case(bytes(b),HELPER_ENTITLEMENTS,False)
b=bytearray(fixture());b[100]^=1;macho_case(bytes(b),HELPER_ENTITLEMENTS,False)
print(f'PASS DER entitlement verifier: {checks} synthetic checks; no permission expansion and no AMFI/device claim.')
