import capstone,struct,sqlite3,json
import os,sys
R=os.environ.get('IW7_REFERENCE_ROOT','C:/Users/ezvalo/Documents/IW7-Paris-Server/tools/references/')
t=open(R+'unpacked-text.bin','rb').read(); TV=0x140001000
rd=open(R+'unpacked-rdata.bin','rb').read()
con=sqlite3.connect(os.environ.get('IW7_ENGINE_MAP_DB','C:/Users/ezvalo/Documents/IW7-Runtime/enginelab/engine-map/iw7-engine-map.sqlite'))
md=capstone.Cs(capstone.CS_ARCH_X86,capstone.CS_MODE_64)
def fn(a):
    r=con.execute('select func from fragments where begin<=? and end>? order by begin desc limit 1',(a,a)).fetchone()
    return r[0] if r else None
def decode_at(s):
    for off in range(24,0,-1):
        ins=list(md.disasm(t[s-off-TV:s-off-TV+40],s-off))
        for i in ins:
            if i.address<=s<i.address+i.size and i.address+i.size-4>=s-3:
                # need the imm/disp bytes inside the instruction
                return i
    return None
out={}
for name,pat in (('0xB5580',struct.pack('<I',0xB5580)),('0xF5580',struct.pack('<I',0xF5580)),('0x18A0',struct.pack('<I',0x18A0)),('0x18A4',struct.pack('<I',0x18A4)),('0x40000',struct.pack('<I',0x40000)),('0x10000',struct.pack('<I',0x10000))):
    i=0; rows=[]
    while True:
        i=t.find(pat,i)
        if i<0: break
        a=TV+i
        ins=None
        for st in (a-3,a-2,a-4,a-1,a-5,a-6,a-7):
            xs=list(md.disasm(t[st-TV:st-TV+16],st))
            if xs and xs[0].address<=a and xs[0].address+xs[0].size>=a+4:
                ins=xs[0];break
        rows.append((hex(a),hex(fn(a) or 0),(ins.mnemonic+' '+ins.op_str) if ins else '?'))
        i+=1
    out[name]=rows
json.dump(out,open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'surf-sites.json'),'w'),indent=0)
for k,v in out.items(): print(k,len(v))
for r in out['0xF5580']: print('F5580',r)
for r in out['0x40000']:
    if r[2]!='?' and ('cmp' in r[2]): print('40000',r)
