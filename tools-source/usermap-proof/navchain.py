import json, subprocess, sys, struct, time
cell=sys.argv[1]
def pk(at,typ,count=1):
    r=subprocess.run([sys.executable,'-B',r'C:\forge\forge.py','peek',at if isinstance(at,str) else hex(at),'--type',typ,'--count',str(count),'--cell',cell],capture_output=True,text=True)
    try: return json.loads(r.stdout)['value']
    except Exception: return None
def rb(at,n):
    v=pk(at,'bytes',n)
    if v is None: return None
    return bytes.fromhex(v.replace(' ','')) if isinstance(v,str) else bytes(v)
BASE=0x1453E7370; NB=0x19c00
raw=None
for _ in range(60):
    raw=rb(BASE,NB*20)
    if raw: break
    time.sleep(5)
print('cell',cell)
for i in range(NB):
    e=raw[i*20:(i+1)*20]; typ=e[0x11]
    if typ not in (25,26): continue
    hdr=struct.unpack_from('<Q',e,0)[0]
    if not hdr: continue
    slot=struct.unpack_from('<H',e,0x12)[0]; nxt=struct.unpack_from('<I',e,0xC)[0]
    z=pk(0x143A124F8+slot*0x478,'str',24) if slot else None
    h=rb(hdr,0x80)
    nm=struct.unpack_from('<Q',h,0)[0]; name=pk(nm,'str',40)
    words=struct.unpack_from('<16I',h,8)
    small=[w for w in words if w<100000000]
    print(f'type={typ} zone={z} idx={i} next={nxt} hdr={hdr:#x} name={name} u32s={list(words)}')
