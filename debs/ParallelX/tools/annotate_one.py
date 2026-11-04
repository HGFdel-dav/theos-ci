#!/usr/bin/env python3
import lief,sys,struct
from capstone import *
from capstone.arm64_const import *
p=sys.argv[1] if len(sys.argv)>1 else sys.exit()
start=int(sys.argv[2],16); stop=int(sys.argv[3],16)
b=lief.parse(p); raw=open(p,'rb').read()
def sec(n):
    for s in b.sections:
        if s.name==n: return s
def u64(o): return struct.unpack_from('<Q',raw,o)[0]
# bindings
got={}
for c in b.commands:
    if c.command==lief.MachO.LoadCommand.TYPE.DYLD_CHAINED_FIXUPS:
        for x in c.bindings:
            if x.has_symbol: got[x.address]=x.symbol.name
# stubs
st=sec('__auth_stubs')
stubmap={}
off=st.offset
for i in range(0,st.size,16):
    tmpd=Cs(CS_ARCH_ARM64, CS_MODE_ARM); tmpd.detail=True; ins=list(tmpd.disasm(raw[off+i:off+i+16], st.virtual_address+i))
    if len(ins)<4: continue
    adrp=ins[0]; add=ins[1]
    if adrp.mnemonic!='adrp': continue
    page=adrp.operands[1].imm
    delta=add.operands[2].imm if add.mnemonic=='add' and len(add.operands)>2 else 0
    tgt=got.get(page+delta)
    if tgt: stubmap[st.virtual_address+i]=tgt
# selrefs
mr=sec('__objc_methname'); sr=sec('__objc_selrefs')
sel={}
for i in range(0,sr.size,8):
    v=u64(sr.offset+i); t=v & ((1<<43)-1)
    if mr.virtual_address <= t < mr.virtual_address+mr.size:
        sel[sr.virtual_address+i]=bytes(mr.content[t-mr.virtual_address:]).split(b'\0')[0].decode('utf-8','replace')
# disasm
md=Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail=True
code=raw[start:stop]
ins=list(md.disasm(code,start))
print('stubs',len(stubmap),'selrefs',len(sel))
for i,x in enumerate(ins):
    note=''
    if x.mnemonic=='bl' and x.operands and x.operands[0].type==CS_OP_IMM:
        t=x.operands[0].imm
        if t in stubmap: note=' ; '+stubmap[t]
    # selref load lookback
    used=[o.reg for o in x.operands if o.type==CS_OP_REG]
    if x.mnemonic=='blraa': used=[ARM64_REG_X0,ARM64_REG_X1,ARM64_REG_X2]
    if x.mnemonic in ('bl','blr','blraa') and used:
        for j in range(i-1,max(-1,i-14),-1):
            y=ins[j]
            if y.mnemonic=='ldr' and len(y.operands)>=2 and y.operands[1].type==CS_OP_MEM and y.operands[0].type==CS_OP_REG and y.operands[0].reg in used:
                mem=y.operands[1].mem
                a=mem.base
                # find adrp for a
                for k in range(j-1,max(-1,j-10),-1):
                    z=ins[k]
                    if z.mnemonic=='adrp' and z.operands[0].reg==a:
                        addr=z.operands[1].imm+mem.disp
                        if addr in sel: note+=' SEL:'+sel[addr]
                        break
                break
    print(f'{x.address:x}: {x.mnemonic}\t{x.op_str}{note}')
