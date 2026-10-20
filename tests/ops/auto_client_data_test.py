"""Closed download contract for the existing publisher's community data, no I/O/network."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

root=Path(__file__).resolve().parents[2]
raw=(root/'config/auto-client-data.json').read_bytes()
m=json.loads(raw)
assert m['Schema']=='iw7.auto-client-data/1'
assert m['CBRevision']=='0a8903a70adbd30824a1d7b3dbaccd72f1bcff51'
assert m['OfficialDeltaRevision']=='37abcb260408ce7cdef0dde831bbfcad594510e3'
assert m['UpstreamManifestSHA256']=='9052C66218E09B73BF0E636BFC1050DFAA8C99F81C51E947CE0ACD9CB64044D2'
assert len(m['Files'])==47
assert sum(f['Bytes'] for f in m['Files'])==371063469
seen=set()
for f in m['Files']:
    p=PurePosixPath(f['Path'])
    assert not p.is_absolute() and p.parts[0]=='cdata'
    assert all(re.fullmatch(r'[A-Za-z0-9_.-]+',part) and part not in ('.','..') for part in p.parts)
    assert p.suffix in {'.arena','.ff','.gsc','.lua','.pak','.sabl','.sabs'}
    assert str(p).casefold() not in seen
    seen.add(str(p).casefold())
    assert type(f['Bytes']) is int and 0<=f['Bytes']<=256*1024*1024
    assert re.fullmatch('[A-F0-9]{40}',f['SHA1'])
    cb=f"https://github.com/CBServers/updater/raw/{m['CBRevision']}/updater/iw7-mod/data/{p}"
    aurora=f"https://github.com/auroramod/iw7-mod/raw/{m['OfficialDeltaRevision']}/data/{p}"
    assert f['Url'] in (cb,aurora)
assert 'cdata/custom_scripts/frontend/usermaps.gsc' in seen
assert 'cdata/ui_scripts/usermaps/__init__.lua' in seen
assert 'cdata/zone/iw7mod_ui_mp.ff' in seen
assert not any('sounddata/' in p for p in seen), 'These publisher records are dedicated-only inputs'
print(json.dumps({'ok':True,'files':len(seen),'bytes':371063469,'manifest_sha256':hashlib.sha256(raw).hexdigest(),'network':False,'assets_downloaded':False}))
