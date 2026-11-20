import capstone,collections,re
from capstone import x86_const as X
import os
R=os.environ.get('IW7_REFERENCE_ROOT','C:/Users/ezvalo/Documents/IW7-Paris-Server/tools/references/')
t=open(R+'unpacked-text.bin','rb').read(); TV=0x140001000
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64); md.detail=True
lo,hi=0x140DC0000,0x140E80000
hist=collections.Counter(); ex={}
import sqlite3
# decode per function fragments to stay aligned
con=sqlite3.connect(os.environ.get('IW7_ENGINE_MAP_DB','C:/Users/ezvalo/Documents/IW7-Runtime/enginelab/engine-map/iw7-engine-map.sqlite'))
frs=con.execute('select begin,end from fragments where begin>=? and end<=? order by begin',(lo,hi)).fetchall()
n=0
for b,e in frs:
    for i in md.disasm(t[b-TV:e-TV],b):
        n+=1
        for op in i.operands:
            if op.type==X.X86_OP_MEM:
                d=op.mem.disp
                if 0xB5580<=d<0xB5A00 or 0x2D560<=d<0x2D700:
                    key=('mem',i.mnemonic,'idx*%d'%op.mem.scale if op.mem.index else 'noidx','base' if op.mem.base else 'nobase','D' if d>=0xB5580 else 'D/4')
                    hist[key]+=1; ex.setdefault(key,[]).append(hex(i.address))
            elif op.type==X.X86_OP_IMM:
                v=op.imm
                if 0xB5580<=v<0xB5A00 or 0x2D560<=v<0x2D700:
                    key=('imm',i.mnemonic,'D' if v>=0xB5580 else 'D/4')
                    hist[key]+=1; ex.setdefault(key,[]).append(hex(i.address))
print(n,'instructions')
for k,v in sorted(hist.items(),key=lambda x:-x[1]): print(v,k,ex[k][:3])
print(sum(hist.values()))
