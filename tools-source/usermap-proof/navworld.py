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
idx=None
for _ in range(60):
    idx=pk(0x144e4f4b4,'u32')
    if idx is not None: break
    time.sleep(5)
print('cell',cell,'active nav world index',idx)
# the navmesh assets: pool of 0x90 headers starting 0x1438682a8? read three
hdrs={}
for a in (0x143868218,0x1438682a8,0x143868338,0x1438683c8):
    h=rb(a,0x90)
    if h: hdrs[a]=h
ptrs={}
for a,h in hdrs.items():
    nm=struct.unpack_from('<Q',h,0)[0]; name=pk(nm,'str',40)
    f=[struct.unpack_from('<Q',h,o)[0] for o in (0x18,0x28,0x40,0x48,0x50,0x58)]
    print(f'navmesh header {a:#x} name={name} ptrs={[hex(x) for x in f]}')
    ptrs[a]=set(x for x in f if x>0x10000)|{a,nm}
for w in range(4):
    base=0x144e3c0a8+w*0x268
    s=rb(base,0x268)
    if s is None: continue
    q=struct.unpack_from('<%dQ'%(0x268//8),s,0)
    nz=[(i*8,v) for i,v in enumerate(q) if v]
    print(f'world {w} at {base:#x}: {len(nz)} nonzero qwords')
    for off,v in nz:
        tag=[hex(a) for a,ps in ptrs.items() if v in ps]
        if tag or v>0x10000:
            print(f'   +{off:#x} = {v:#x} {"== navmesh hdr/ptr of "+",".join(tag) if tag else ""}')
