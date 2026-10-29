"""Check exact build provenance + local source hash identity before delivery."""
from pathlib import Path
import hashlib,json,sys
import publish
r=Path(__file__).resolve().parent
s=json.loads((r/'ci-state.json').read_text())
run_id=int(sys.argv[1])
p='/repos/'+s['repo']
run=publish.api(p+'/actions/runs/'+str(run_id))
assert run['head_sha']==s['commit'], 'CI was not built from the source commit'
assert run['head_branch']==s['branch']
assert run['status']=='completed' and run['conclusion']=='success', 'CI not successful'
jobs=publish.api(p+'/actions/runs/'+str(run_id)+'/jobs')['jobs']
assert len(jobs)==2 and {j['name'] for j in jobs}=={'build (roothide)','build (rootless)'}
assert all(j['conclusion']=='success' for j in jobs)
commit=publish.api(p+'/git/commits/'+s['commit'])
tree=publish.api(p+'/git/trees/'+commit['tree']['sha']+'?recursive=1')
assert not tree.get('truncated'), 'source tree query truncated'
files={f['path']:f['sha'] for f in tree['tree'] if f['type']=='blob'}
checked=[]
for directory in ('Sources','Prefs','layout','tests'):
 for path in sorted((r/directory).rglob('*')):
  if not path.is_file() or '__pycache__' in path.parts:continue
  data=path.read_bytes();blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
  rel='debs/ParticleX/'+path.relative_to(r).as_posix()
  assert files.get(rel)==blob, 'source differs from build: '+rel
  checked.append(path.relative_to(r).as_posix())
for name in ('Makefile','control','ParticleX.plist','check.py','README.md','create_metadata.py'):
 data=(r/name).read_bytes();blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
 assert files.get('debs/ParticleX/'+name)==blob,'source differs from build: '+name
 checked.append(name)
s.update(run_id=run_id,html_url=run['html_url'],conclusion=run['conclusion'])
(r/'ci-state.json').write_text(json.dumps(s,indent=2))
proof={'repo':s['repo'],'branch':s['branch'],'commit':s['commit'],'run_id':run_id,
 'html_url':run['html_url'],'jobs':[{k:j[k] for k in ('name','conclusion')} for j in jobs],
 'verified_local_files':checked,'main_ref':publish.api(p+'/git/ref/heads/main')['object']['sha']}
(r/'ci-downloads'/'build-provenance.json').write_text(json.dumps(proof,indent=2))
print('PASS build provenance: commit and',len(checked),'local source/metadata files match')
print('Build',proof['html_url'])
print('main ref:',proof['main_ref'])
