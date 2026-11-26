import json, subprocess, sys, struct, time, hashlib
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
    e=raw[i*20:(i+1)*20]
    if e[0x11]!=27: continue
    hdr=struct.unpack_from('<Q',e,0)[0]
    if not hdr: continue
    slot=struct.unpack_from('<H',e,0x12)[0]
    z=pk(0x143A124F8+slot*0x478,'str',24) if slot else None
    h=rb(hdr,0x340)
    size=struct.unpack_from('<I',h,0x150)[0]; ptr=struct.unpack_from('<Q',h,0x158)[0]
    data=rb(ptr,size)
    open(f'ab/pf_{sys.argv[2]}_{z}.hkx','wb').write(data)
    print(f'map_ents zone={z} ptr={ptr:#x} hdr={hdr:#x} packfile size={size} md5={hashlib.md5(data).hexdigest()}')
