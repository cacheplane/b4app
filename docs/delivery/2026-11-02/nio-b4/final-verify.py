import json,hashlib,subprocess,plistlib,datetime
from pathlib import Path
base=Path('/tmp/b4-nio-b4-evidence');out=Path('docs/delivery/2026-11-02/nio-b4')
records=[json.loads(l) for l in (out/'observations.jsonl').read_text().splitlines()]
byid={r['case_id']:r for r in records};proof=[]
for name in ['strict-final-full-warm-2','strict-final-cold','final-swift-build']:
 r=byid[name];assert r['exit_code']==0
 for p,h in r['input_hashes'].items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,(name,p)
 raw=Path(r['log']).read_bytes();assert hashlib.sha256(raw).hexdigest()==r['log_sha256']
 if name!='final-swift-build':
  s=raw.decode(errors='replace');assert 'Test run with 1164 tests in 146 suites passed' in s
  assert 'already shut down' not in s and 'Fatal error' not in s
 proof.append(name)
for line in (out/'candidate-files.sha256').read_text().splitlines():
 h,p=line.split('  ',1);assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
checks=json.loads((out/'final-checks.json').read_text());assert all(r['exit_code']==0 for r in checks['results'])
native=json.loads((out/'native-products.json').read_text());assert len(native['products'])==6 and len(native['builds'])==6 and all(r['exit_code']==0 for r in native['builds'])
for b in native['builds']:
 r=byid[b['case_id']];assert r['exit_code']==0
 for p,h in r['input_hashes'].items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,(b,p)
assert hashlib.sha256(Path('Package.resolved').read_bytes()).hexdigest()==native['root_package_lock_sha256']
locations=[]
root=Path('/tmp/b4-ci-swift-evidence/native/DerivedData/Build/Products')
for app in sorted(root.glob('*/*.app')):
 plist=app/'Contents/Info.plist' if (app/'Contents/Info.plist').exists() else app/'Info.plist'
 if not plist.exists():continue
 info=plistlib.loads(plist.read_bytes());exe=app/('Contents/MacOS' if (app/'Contents').exists() else '')/info['CFBundleExecutable']
 p=next(p for p in native['products'] if p['configuration']==app.parent.name and p['bundle_id']==info['CFBundleIdentifier'])
 assert hashlib.sha256(exe.read_bytes()).hexdigest()==p['binary_sha256']
 assert hashlib.sha256(plist.read_bytes()).hexdigest()==p['info_plist_sha256']
 locations.append(dict(product_path=str(app),executable_path=str(exe),bundle_id=p['bundle_id'],configuration=p['configuration'],binary_sha256=p['binary_sha256'],info_plist_sha256=p['info_plist_sha256'],artifact_kind='Unsigned local native build; no install or distribution acceptance'))
assert len(locations)==6
(out/'artifact-locations.json').write_text(json.dumps(locations,indent=2)+'\n')
subprocess.run(['git','diff','--check'],check=True)
summary={'collected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'final_source_hashes_match':True,'final_warm_cold_build':proof,'full_tests_each':1164,'suites_each':146,'nio_shutdown_diagnostics_each':0,'native_builds':6,'native_products_digest_verified':6,'static_commands':len(checks['results']),'static_exit_codes':[r['exit_code'] for r in checks['results']],'hosted_candidate':'Untested','published_or_deployed':False,'verdict':'Incomplete for hosted CI delivery improvement; final local correctness/native/cold checks pass'}
(out/'final-verification.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
