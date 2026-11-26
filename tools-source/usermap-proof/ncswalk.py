import json, subprocess, sys
cell = sys.argv[1]
def pk(at, typ, count=1):
    r = subprocess.run([sys.executable,'-B',r'C:\forge\forge.py','peek',at,'--type',typ,'--count',str(count),'--cell',cell],capture_output=True,text=True)
    try: return json.loads(r.stdout)['value']
    except Exception: raise SystemExit(('ERR',at,r.stdout[:200],r.stderr[:200]))
def h(x): return int(x,16) if isinstance(x,str) else x
kinds = pk('0x141ba78e8','u64',23*3)
names=[]
for k in range(23):
    p = h(kinds[k*3]); names.append(pk(hex(p),'str',16) if p else None)
print('kinds', names)
nloaded = pk('0x145206470','u32')
print('assets registered (DAT_145206470):', nloaded)
out={}
for k in range(23):
    head = h(pk(hex(0x145205ae0+k*16),'u64'))
    cnt = pk(hex(0x145205ae8+k*16),'u32')
    lst=[]; seen=0
    while head and seen<64:
        a = h(pk(hex(head),'u64')); nxt=h(pk(hex(head+8),'u64'))
        name = h(pk(hex(a),'u64')); nm = pk(hex(name),'str',64) if name else None
        n = pk(hex(a+0x14),'u32'); kd=pk(hex(a+8),'u32')
        lst.append((nm,kd,n)); head=nxt; seen+=1
    out[names[k]]=(cnt,lst)
    if lst: print(names[k],cnt,lst)
json.dump(out,open(sys.argv[2],'w'),indent=0)
