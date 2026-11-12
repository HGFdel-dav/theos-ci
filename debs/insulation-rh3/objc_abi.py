#!/usr/bin/env python3
"""Static arm64/arm64e Mach-O Objective-C ABI reader (no target execution)."""
import struct,pathlib,json,uuid,sys
class MachO:
 def __init__(self,path,arch='arm64e'):
  b=pathlib.Path(path).read_bytes()
  if b[:4]==b'\xca\xfe\xba\xbe':
   n=struct.unpack_from('>I',b,4)[0]; es=[struct.unpack_from('>IIIII',b,8+20*i) for i in range(n)]
   e=next(e for e in es if ((e[1]&0xffffff)==2)==(arch=='arm64e')); b=b[e[2]:e[2]+e[3]]
  self.b=b; self.sections=[];self.segments=[];self.chain={};self.uuid=None;fix=None
  assert struct.unpack_from('<I',b)[0]==0xfeedfacf
  p=32
  for _ in range(struct.unpack_from('<I',b,16)[0]):
   c,z=struct.unpack_from('<II',b,p)
   if c==0x19:
    seg=b[p+8:p+24].split(b'\0')[0].decode();va,vs,fo,fs=struct.unpack_from('<4Q',b,p+24)
    self.segments.append((seg,va,vs,fo,fs)); ns=struct.unpack_from('<I',b,p+64)[0]
    for j in range(ns):
     q=p+72+j*80; name=b[q:q+16].split(b'\0')[0].decode();addr,size,off=struct.unpack_from('<QQI',b,q+32)
     self.sections.append(dict(name=name,seg=seg,addr=addr,size=size,off=off))
   elif c==0x1b:self.uuid=str(uuid.UUID(bytes=b[p+8:p+24]))
   elif c==0x80000034:fix=struct.unpack_from('<II',b,p+8)
   p+=z
  self.base=next(v[1] for v in self.segments if v[0]=='__TEXT')
  if fix:self.fixups(*fix)
 def off(self,a):
  for _,va,vs,fo,fs in self.segments:
   if va<=a<va+fs:return fo+a-va
  raise ValueError(f'Unmapped address {a:#x}')
 def raw(self,a,n):return self.b[self.off(a):self.off(a)+n]
 def u32(self,a):return struct.unpack('<I',self.raw(a,4))[0]
 def i32(self,a):return struct.unpack('<i',self.raw(a,4))[0]
 def u64(self,a):return struct.unpack('<Q',self.raw(a,8))[0]
 def ptr(self,a):return self.chain.get(a,self.u64(a))
 def cstr(self,a):
  if not isinstance(a,int) or not a:return a
  off=self.off(a);return self.b[off:self.b.index(b'\0',off)].decode('utf-8',errors='replace')
 def fixups(self,off,size):
  _,starts,imp,sym,count,fmt,_=struct.unpack_from('<7I',self.b,off); imports=[]
  for i in range(count):
   pos=off+imp+i*({1:4,2:8,3:16}[fmt]);v=struct.unpack_from('<I' if fmt!=3 else '<Q',self.b,pos)[0]
   no=v>>9 if fmt!=3 else v>>32; s=off+sym+no
   imports.append(self.b[s:self.b.index(b'\0',s)].decode())
  st=off+starts;nseg=struct.unpack_from('<I',self.b,st)[0]
  for i in range(nseg):
   rel=struct.unpack_from('<I',self.b,st+4+4*i)[0]
   if not rel:continue
   q=st+rel;z,ps,pf,so,mv,pc=struct.unpack_from('<IHHQIH',self.b,q)
   for pi in range(pc):
    po=struct.unpack_from('<H',self.b,q+22+2*pi)[0]
    if po==65535:continue
    assert not po&0x8000,'Multiple chains not yet supported'
    a=self.base+so+pi*ps+po;seen=set()
    while True:
     assert a not in seen;seen.add(a);v=self.u64(a)
     if pf in (1,7,9,10,12):
      auth=v>>63;bind=(v>>62)&1;nextoff=(v>>51)&2047
      if bind:out=imports[v&((1<<24)-1 if pf==12 else 65535)]
      elif auth:out=self.base+(v&0xffffffff)
      else:
       out=(v&((1<<43)-1))|(((v>>43)&255)<<56)
       if pf in (7,9,10,12):out+=self.base
      stride=4 if pf in (7,10) else 8
     elif pf in (2,6):
      bind=v>>63;nextoff=(v>>51)&4095
      if bind:out=imports[v&0xffffff]
      else:
       out=(v&((1<<36)-1))|(((v>>36)&255)<<56)
       if pf==6:out+=self.base
      stride=4
     else:raise ValueError(f'Unsupported chained pointer format {pf}')
     self.chain[a]=out
     if not nextoff:break
     a+=nextoff*stride
 def methods(self,p):
  if not p:return []
  flags,n=struct.unpack('<II',self.raw(p,8));small=bool(flags&0x80000000);direct=bool(flags&0x40000000)
  entsize=flags&0xffff;assert n<20000 and entsize in (12,24)
  out=[]
  for i in range(n):
   a=p+8+i*entsize
   if small:
    sel=a+self.i32(a); sel=sel if direct else self.ptr(sel)
    types=a+4+self.i32(a+4);imp=a+8+self.i32(a+8)
   else:sel=self.ptr(a);types=self.ptr(a+8);imp=self.ptr(a+16)
   out.append(dict(selector=self.cstr(sel),types=self.cstr(types),imp=hex(imp) if isinstance(imp,int) else imp))
  return out
 def class_info(self,p):
  data=self.ptr(p+32)
  if not isinstance(data,int):raise ValueError('Bound class_ro')
  ro=data&~7
  return self.cstr(self.ptr(ro+24)),self.methods(self.ptr(ro+32))
 def classes(self):
  result=[]
  sec=next(s for s in self.sections if s['name']=='__objc_classlist')
  for i in range(sec['size']//8):
   p=self.ptr(sec['addr']+8*i)
   name,inst=self.class_info(p);meta=self.ptr(p);_,classmeth=self.class_info(meta)
   superp=self.ptr(p+8)
   if isinstance(superp,str):sup=superp.removeprefix('_OBJC_CLASS_$_')
   elif superp:sup=self.class_info(superp)[0]
   else:sup=None
   result.append(dict(name=name,superclass=sup,address=hex(p),instance_methods=inst,class_methods=classmeth))
  return result
if __name__=='__main__':
 m=MachO(sys.argv[1],sys.argv[2] if len(sys.argv)>2 else 'arm64e');d=dict(uuid=m.uuid,base=hex(m.base),fixups=len(m.chain),classes=m.classes())
 print(json.dumps(d,ensure_ascii=False,indent=2))
