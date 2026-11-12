#!/usr/bin/env python3
"""Narrow, hash-locked ABI correction for the user's 0.1.38.1 binary.
Not a compiler or installer. Output is UNSIGNED and is never an installable DEB.
The full 0.1.38.1 implementation, including every mode branch, is preserved.
"""
from __future__ import annotations
import argparse,hashlib,json,pathlib,struct,uuid,sys
BASE_SHA256='db3726d94978c35c46b5dfdd1719f6194768dfc282471bfcf24fe422bd7322f6'
REVISION='0.1.38.1-rh5'
NOP=0xd503201f
RET=0xd65f03c0
# VM addresses equal thin-file offsets only for this verified original.
# map_address() below still checks each actual executable __text location.
PATCHES=(
 ('arm64e',0x8d64,0x940006d2,NOP,'scalar argument: remove objc_retain'),
 ('arm64e',0x8d94,0x940006ce,NOP,'scalar result: remove retainAutoreleasedReturnValue'),
 ('arm64e',0x8da8,0x940006bd,NOP,'scalar argument: remove objc_release'),
 ('arm64e',0x8dd4,0x1400068e,RET,'scalar result: RET after existing AUTIBSP; never double-auth RETAB'),
 ('arm64',0xc6c8,0x9400065a,NOP,'scalar argument: remove objc_retain'),
 ('arm64',0xc6f8,0x94000654,NOP,'scalar result: remove retainAutoreleasedReturnValue'),
 ('arm64',0xc70c,0x94000646,NOP,'scalar argument: remove objc_release'),
 ('arm64',0xc728,0x14000624,RET,'scalar result: normal RET, not objc_autoreleaseReturnValue'),
 # The plist power values are milliwatt-scale (this iPhone: backlight 600..3900,
 # maxPower 6131), but the original floor constant is 1_000_000. It is fed into
 # max() against those values and then written to BOTH maxThermalPower and
 # minThermalPower, locking the backlight at the wrong magnitude -> black screen
 # even at maximum brightness. 600 matches the stock backlight minThermalPower.
 ('arm64e',0x4780,0x52884800,0x52804b00,'backlight power floor: 1,000,000 -> 600 (unit match)'),
 ('arm64e',0x4784,0x72a001e0,0xd503201f,'floor constant: second half no longer needed'),
 ('arm64',0x8698,0x52884800,0x52804b00,'backlight power floor: same unit fix'),
 ('arm64',0x869c,0x72a001e0,0xd503201f,'floor constant: second half no longer needed'),
 # Stock plist has generalProductConfig/needsPushingTSFDtoDisplayDriver = true.
 # This branch overwrote it with kCFBooleanFalse; without TSF pushes the display
 # driver never gets the new state -> fully black screen that still accepts touch.
 # Point the same slot at kCFBooleanTrue instead (arm64e GOT 0x101F0, arm64 0x10110).
 # kCFBooleanTrue's GOT slot is an authenticated pointer; a plain ldr leaves it
 # unsigned and objc_msgSend traps (PAC). Skip the three setObject: calls and let
 # the mutable copy keep the stock values (needsPushingTSFDtoDisplayDriver=true).
 ('arm64e',0x8f98,0x940007e1,0xd503201f,'keep stock needsPushingTSFDtoDisplayDriver'),
 ('arm64e',0x8fb0,0x940007db,0xd503201f,'keep stock displayBrightnessMitigation'),
 ('arm64e',0x8fc8,0x940007d5,0xd503201f,'keep stock displayMitigation'),
 ('arm64',0xc8d4,0x9400076a,0xd503201f,'keep stock needsPushingTSFDtoDisplayDriver'),
 ('arm64',0xc8ec,0x94000764,0xd503201f,'keep stock displayBrightnessMitigation'),
 ('arm64',0xc904,0x9400075e,0xd503201f,'keep stock displayMitigation'),
)
EXPECTED_UUIDS={'arm64':'adf544fb-16ad-3574-b6e0-0e6cace94169','arm64e':'e4b12879-1e1e-3156-b516-2059759bbf02'}

def slices(data:bytes):
 if len(data)<48 or data[:4]!=b'\xca\xfe\xba\xbe':raise ValueError('Expected exact FAT32 baseline')
 n=struct.unpack_from('>I',data,4)[0]
 if n!=2:raise ValueError('Expected precisely arm64 and arm64e')
 result={}
 for i in range(n):
  ct,st,off,size,align=struct.unpack_from('>5I',data,8+20*i)
  if ct!=0x100000c or off+size>len(data):raise ValueError('Invalid FAT slice')
  name='arm64e' if (st&0xffffff)==2 else 'arm64'
  if name in result:raise ValueError('Duplicate architecture')
  result[name]={'off':off,'size':size,'raw':data[off:off+size]}
 return result

def metadata(raw:bytes):
 if struct.unpack_from('<I',raw)[0]!=0xfeedfacf:raise ValueError('Not Mach-O64')
 p=32;sections=[];uuid_offset=None
 for _ in range(struct.unpack_from('<I',raw,16)[0]):
  cmd,size=struct.unpack_from('<II',raw,p)
  if size<8 or p+size>len(raw):raise ValueError('Invalid Mach-O command')
  if cmd==0x19:
   ns=struct.unpack_from('<I',raw,p+64)[0]
   for i in range(ns):
    q=p+72+80*i;name=raw[q:q+16].split(b'\0')[0].decode()
    addr,length,fileoff=struct.unpack_from('<QQI',raw,q+32)
    flags=struct.unpack_from('<I',raw,q+64)[0]
    sections.append((name,addr,length,fileoff,flags))
  elif cmd==0x1b:uuid_offset=p+8
  p+=size
 if uuid_offset is None:raise ValueError('Missing LC_UUID')
 return sections,uuid_offset

def map_address(raw:bytes,address:int):
 sections,_=metadata(raw)
 for name,va,size,off,flags in sections:
  if name=='__text' and va<=address<va+size and flags&0x80000000:
   return off+address-va
 raise ValueError(f'Not an executable __text address: {address:#x}')

def patch(data:bytes,*,update_uuid=True):
 actual=hashlib.sha256(data).hexdigest()
 if actual!=BASE_SHA256:raise ValueError('Original SHA256 differs; refuse unreviewed version or old fix2')
 out=bytearray(data);ss=slices(data); changes=[]; uuids={}
 for arch,s in ss.items():
  _,uo=metadata(s['raw']); original=str(uuid.UUID(bytes=s['raw'][uo:uo+16]))
  if original!=EXPECTED_UUIDS[arch]:raise ValueError('Original architecture UUID differs')
 for arch,addr,expected,replacement,reason in PATCHES:
  s=ss[arch];off=map_address(s['raw'],addr)
  if struct.unpack_from('<I',s['raw'],off)[0]!=expected:raise ValueError(f'Instruction differs at {arch}:{addr:#x}')
  struct.pack_into('<I',out,s['off']+off,replacement)
  changes.append({'arch':arch,'address':hex(addr),'original':hex(expected),'replacement':hex(replacement),'reason':reason})
 # New deterministic per-slice UUID prevents confusing later IPS with original/fix2.
 if update_uuid:
  for arch,s in ss.items():
   _,uo=metadata(s['raw']);new=uuid.uuid5(uuid.NAMESPACE_URL,f'insulation|{BASE_SHA256}|{REVISION}|{arch}|scalar-ABI-ret')
   out[s['off']+uo:s['off']+uo+16]=new.bytes;uuids[arch]=str(new)
 manifest={'baseline_sha256':actual,'revision':REVISION,'unsigned_sha256':hashlib.sha256(out).hexdigest(),'instruction_changes':changes,'uuid':uuids,'signed':False,'warning':'UNSIGNED static candidate: must be re-signed and fully verified on authorized CI before packaging/install'}
 return bytes(out),manifest

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('source',type=pathlib.Path);ap.add_argument('destination',type=pathlib.Path);ap.add_argument('--manifest',type=pathlib.Path);args=ap.parse_args()
 if args.destination.exists():ap.error('Destination already exists; refusing overwrite')
 data,m=patch(args.source.read_bytes());args.destination.parent.mkdir(parents=True,exist_ok=True);args.destination.write_bytes(data)
 if args.destination.read_bytes()!=data:raise ValueError('Write-back mismatch')
 if args.manifest:args.manifest.write_text(json.dumps(m,indent=2))
 print(json.dumps(m,indent=2))
if __name__=='__main__':main()
