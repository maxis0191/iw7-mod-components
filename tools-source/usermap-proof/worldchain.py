import json, subprocess, sys, struct
cell=sys.argv[1]
def pk(at,typ,count=1):
    r=subprocess.run([sys.executable,'-B',r'C:\forge\forge.py','peek',at,'--type',typ,'--count',str(count),'--cell',cell],capture_output=True,text=True)
    try: return json.loads(r.stdout)['value']
    except Exception: return None
BASE=0x1453E7370; NB=0x19c00
raw=pk(hex(BASE),'bytes',NB*20)
raw=bytes.fromhex(raw.replace(' ','')) if isinstance(raw,str) else bytes(raw)
for i in range(NB):
    e=raw[i*20:(i+1)*20]; typ=e[0x11]
    if typ not in (22,29,27): continue
    hdr=struct.unpack_from('<Q',e,0)[0]
    if not hdr: continue
    nxt=struct.unpack_from('<I',e,0xC)[0]; slot=struct.unpack_from('<H',e,0x12)[0]; fl=e[0x10]
    nm=pk(hex(hdr),'ptr'); nm=int(nm,16) if isinstance(nm,str) else nm
    s=pk(hex(nm),'str',48) if nm else None
    z=pk(hex(0x143A124F8+slot*0x478),'str',24) if slot else None
    print(f'idx={i} type={typ} next={nxt} slot={slot}({z}) flags={fl:#x} hdr={hdr:#x} name={s}')
