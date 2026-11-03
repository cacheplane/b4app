from pathlib import Path
import json,hashlib,re,shutil,statistics,datetime,csv,subprocess
base=Path('/tmp/b4-pause-evidence');out=Path('docs/delivery/2026-11-02/pause-investigation');records=[];summaries=[]
for p in base.glob('*.json'):
 d=json.loads(p.read_text())
 if 'case_id' not in d:continue
 log=Path(d['log']);raw=log.read_text(errors='replace') if log.exists() else ''
 d['log_sha256']=hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None
 d['hosted_run_id']=None;d['accepted_availability_seconds']=None
 records.append(d)
 summaries.append({'case_id':d['case_id'],'test_summary':re.findall(r'Test run with (\d+) tests in (\d+) suites (passed|failed) after ([\d.]+) seconds(?: with (\d+) issues)?',raw),'shutdown_diagnostic':'already shut down' in raw,'scan_stage_seconds':[float(x) for x in re.findall(r'SCAN_SAMPLE repetition=\d+ seconds=([\d.]+)',raw)],'build_succeeded':'** BUILD SUCCEEDED **' in raw,'issues':[x[:500] for x in raw.splitlines() if 'recorded an issue' in x]})
# Baseline characterization used the preceding phase harness; keep it here without changing its old packet.
p=Path('/tmp/b4-nio-b4-evidence/scratch-characterization-baseline.json')
if p.exists():
 d=json.loads(p.read_text());d['limitation']='Old harness did not include new test/helper hashes; unchanged baseline helper hash is confirmed by actual-sweep-baseline. Characterization is not a speed comparison.';records.append(d)
records.sort(key=lambda r:r['started_at'])
(out/'observations.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records));(out/'console-summaries.json').write_text(json.dumps(summaries,indent=2)+'\n')
with (out/'observations.csv').open('w') as f:
 fields=['case_id','started_at','ended_at','wall_seconds','exit_code','log','log_sha256'];w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(records)
for name in ['scan-inputs-retrospective.json','scan-control-inventory.json','invalid-name-fixture.json','native-products.json','final-checks.json','final-checks.log']:
 if (base/name).exists():shutil.copyfile(base/name,out/name)
for name in ['scan-benchmark-initial.jsonl','scan-benchmark-initial.swift','scan-control.jsonl','scan-live.jsonl']:
 if (base/name).exists():shutil.copyfile(base/name,out/name)
sam=json.loads((base/'diagnostic-full-1.json').read_text())
(out/'sample-summary.json').write_text(json.dumps({'evidence':sam['samples'],'observed_first_sample_main_thread':['ConnectionsModelTests.usageArrivesAfterACheck','ModelHarness.start','EphemeralPostgres.paths','EphemeralPostgres.endpoint','EphemeralPostgres.ensureStarted','EphemeralPostgres.sweepStale','FileManager.contentsOfDirectory','getattrlistbulk'],'observed_other_workers':'Waiting in EphemeralPostgres.ensureStarted→NSLock→__psynch_mutexwait','limits':'First3s sample localizes an actual startup blocker, not proof that every historical60s pause has this cause. Later samples show normal SQL/test work. Sampling overhead excludes full diagnostic run from speed comparisons.'},indent=2)+'\n')
bycase={s['case_id']:s for s in summaries};b=bycase['actual-frozen-baseline']['scan_stage_seconds'];c=bycase.get('actual-frozen-candidate-corrected',{}).get('scan_stage_seconds',[])
if c:
 (out/'comparison.json').write_text(json.dumps({'scope':'Actual sweep helper, frozen5000entry namespace, three repetitions each. Baseline group before candidate; prototype interleaved control also retained. Not whole-test/fullCI latency.','baseline_seconds':b,'candidate_seconds':c,'baseline_median_seconds':statistics.median(b),'candidate_median_seconds':statistics.median(c),'median_reduction_fraction':1-statistics.median(c)/statistics.median(b),'objective_fraction':.10,'inventory_identity':'scan-inputs-retrospective.json (explicitly retrospective)','mutable_live_samples':'Separate actual-sweep logs; non-equivalent changing inputs; no exact ratio claimed.'},indent=2)+'\n')
checks=json.loads((base/'final-checks.json').read_text()) if (base/'final-checks.json').exists() else {'results':[]}
maincpu=sum(r.get('child_cpu_seconds',r.get('child_user_seconds',0)+r.get('child_system_seconds',0)) for r in records)
(out/'resources.json').write_text(json.dumps({'main_command_attempts':len(records),'main_command_wall_sum_seconds':sum(r['wall_seconds'] for r in records),'known_static_command_wall_seconds':sum(r['wall_seconds'] for r in checks['results']),'main_instrumented_child_cpu_seconds':maincpu,'limitations':'Includes failures and sampler children; excludes prototype compilation/scan commands with no complete wrapper clock, audit helper CPU and Xcode non-child build-service CPU. Sums are not elapsed recovery time or total native compute. No hosted cost/accepted availability measured.','hosted_cost':None},indent=2)+'\n')
paths={'Package.swift','Package.resolved','project.yml'}
changed=subprocess.check_output(['git','diff','--name-only'],text=True).splitlines()+subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True).splitlines()
for p in changed:
 if p.startswith(('Sources/','Tests/','Apps/','.github/','Scripts/','Config/')) and '__pycache__' not in p and Path(p).is_file():paths.add(p)
(out/'candidate-files.sha256').write_text(''.join(hashlib.sha256(Path(p).read_bytes()).hexdigest()+'  '+p+'\n' for p in sorted(paths)))
