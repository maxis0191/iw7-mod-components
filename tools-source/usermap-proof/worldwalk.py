import json, subprocess, sys, struct
cell=sys.argv[1]
def pk(at,typ,count=1):
    r=subprocess.run([sys.executable,'-B',r'C:\forge\forge.py','peek',at,'--type',typ,'--count',str(count),'--cell',cell],capture_output=True,text=True)
    try: return json.loads(r.stdout)['value']
    except Exception: return None
BASE=0x1453E7370; NB=0x19c00
raw=pk(hex(BASE),'bytes',NB*20)
if isinstance(raw,str): raw=bytes.fromhex(raw.replace(' ',''))
else: raw=bytes(raw)
want={22:'clipmap',23:'comworld',24:'glassworld',25:'pathdata',26:'navmesh',27:'map_ents',28:'fxworld',29:'gfxworld',30:'gfxworld_tr',3:'physicsasset',64:'streaming',32:'lightdef'}
out=[]
for i in range(NB):
    e=raw[i*20:(i+1)*20]
    hdr=struct.unpack_from('<Q',e,0)[0]; typ=e[0x11]; slot=struct.unpack_from('<H',e,0x12)[0]
    if typ in want and hdr:
        nm=pk(hex(hdr),'ptr')
        nm=int(nm,16) if isinstance(nm,str) else nm
        s=pk(hex(nm),'str',64) if nm else None
        z=pk(hex(0x143A124F8+slot*0x478),'str',32) if slot else None
        out.append((want[typ],s,z))
for o in sorted(out): print(o)
