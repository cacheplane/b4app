from pathlib import Path
import json,hashlib,re,csv,shutil,datetime,statistics,subprocess
base=Path('/tmp/b4-nio-b4-evidence');out=Path('docs/delivery/2026-11-02/nio-b4');records=[];summaries=[]
files=list(base.glob('*.json'))
files += [Path('/tmp/b4-ci-swift-evidence')/(n+'.json') for n in ['nio-strict-baseline','nio-close-regression-red']]
for f in files:
 data=json.loads(f.read_text())
 if 'case_id' not in data:continue
 log=Path(data['log']);raw=log.read_text(errors='replace') if log.exists() else ''
 data['log_sha256']=hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None
 data['evidence_modes']='R+M local execution; B for negative controls'
 data['hosted_run_id']=None;data['release_intent_id']=None;data['accepted_availability_seconds']=None
 records.append(data)
 result=re.findall(r'Test run with (\d+) tests in (\d+) suites (passed|failed) after ([\d.]+) seconds(?: with (\d+) issues)?',raw)
 summaries.append({'case_id':data['case_id'],'test_summary':result[-1] if result else None,'nio_shutdown_diagnostic':('already shut down' in raw),'fatal':('Fatal error' in raw),'build_succeeded':('** BUILD SUCCEEDED **' in raw),'build_span_seconds':re.findall(r'Build complete! \(([\d.]+)s\)',raw),'limitations':'Raw logs retained locally by path/hash; parameterized fixture output omitted here to avoid sharing identifying sample values.'})
records.sort(key=lambda x:x['started_at'])
(out/'observations.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records))
(out/'console-summaries.json').write_text(json.dumps(summaries,indent=2)+'\n')
with (out/'observations.csv').open('w') as f:
 cols=['case_id','started_at','ended_at','wall_seconds','child_user_seconds','child_system_seconds','exit_code','nio_strict','test_width','log','log_sha256'];w=csv.DictWriter(f,fieldnames=cols,extrasaction='ignore');w.writeheader();w.writerows(records)
for name in ['native-products.json','final-checks.json','final-checks.log','fixture-profile-final.json']:
 if (base/name).exists():shutil.copyfile(base/name,out/name)
auxiliary=json.loads((out/'auxiliary-attempts.json').read_text())
known_auxiliary_wall=sum(r['wall_seconds'] for r in auxiliary if r.get('wall_seconds') is not None)
resource={'scope':'This phase only. Main instrumented attempts are in observations.jsonl; separately measured static command wall is in auxiliary-attempts.json. Individual bind samples are narrower clocks, not command-wall measurements. Other auxiliary command clocks/CPU remain unknown. Parent packet totals excluded; no cloud cost inferred.','collected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'main_instrumented_command_attempts':len(records),'main_instrumented_command_wall_seconds':sum(r['wall_seconds'] for r in records),'known_auxiliary_command_wall_seconds':known_auxiliary_wall,'known_command_wall_sum_seconds':sum(r['wall_seconds'] for r in records)+known_auxiliary_wall,'main_instrumented_child_cpu_seconds':sum(r['child_user_seconds']+r['child_system_seconds'] for r in records),'cpu_limitation':'RUSAGE_CHILDREN only; Xcode build-service/other non-child daemon CPU, parent harness CPU and machine-wide contention are not captured. Not total native compute.','hosted_compute_dollars':None,'publication_latency_seconds':None,'accepted_availability_seconds':None,'interpretation':'Sum of attempts includes failures and repeated planning; not elapsed recovery time or comparable performance. Parent budgets/resources are unchanged.'}
(out/'resources.json').write_text(json.dumps(resource,indent=2)+'\n')
paths={'Package.swift','Package.resolved','project.yml'}
changed=subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()+subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True).splitlines()
for p in changed:
 if p.startswith(('Sources/','Tests/','Apps/','.github/','Scripts/','Config/')) and '__pycache__' not in p and Path(p).is_file():paths.add(p)
(out/'candidate-files.sha256').write_text(''.join(hashlib.sha256(Path(p).read_bytes()).hexdigest()+'  '+p+'\n' for p in sorted(paths)))
