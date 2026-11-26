import json, subprocess, sys
cell, arr, out = sys.argv[1], int(sys.argv[2], 16), sys.argv[3]
def peek(at, typ, count=1):
    r = subprocess.run([sys.executable, '-B', r'C:\forge\forge.py', 'peek', at, '--type', typ, '--count', str(count), '--cell', cell], capture_output=True, text=True)
    try: return json.loads(r.stdout)['value']
    except Exception: return ('ERR', r.stdout[:200], r.stderr[:200])
ids = peek(hex(arr), 'u32', 256)
if not isinstance(ids, list): print(ids); sys.exit(1)
empty = peek('0x145d5af00', 'u32')
rows = []
for i, sid in enumerate(ids):
    s = None
    if sid and sid != empty:
        s = peek(hex(0x1460B9600 + 8 + sid * 0x14), 'str', 96)
    rows.append([i, sid, s])
json.dump({'empty_id': empty, 'rows': rows}, open(out, 'w'), indent=0)
used = [r for r in rows[2:256] if r[2]]
print('empty id', empty, 'used slots 2..255:', len(used))
for r in rows[:256]:
    if r[2]: print(r[0], r[2])
