import subprocess,os,time,json,hashlib,datetime,resource,signal
from pathlib import Path
base=Path('/tmp/b4-pause-evidence');base.mkdir(exist_ok=True)
runtime=base/'runtime';runtime.mkdir(exist_ok=True)
env=dict(os.environ,TMPDIR=str(runtime)+'/',SWIFTNIO_STRICT='1',B4APP_POSTGRES_BIN=str(Path('.build/postgres/bin').resolve()))
for key in list(env):
 if key.startswith('B4APP_LIVE_'):env.pop(key)
identity=Path('docs/delivery/2026-11-02/nio-b4/candidate-files.sha256').read_text()
for row in identity.splitlines():
 digest,path=row.split('  ',1);assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,path
log=base/'diagnostic-full-1.log';samples=[];started=datetime.datetime.now(datetime.timezone.utc).isoformat();start=time.monotonic();before=resource.getrusage(resource.RUSAGE_CHILDREN);test_start=None;targets=iter([2,15,40]);next_sample=next(targets,None)
with log.open('w') as output:
 process=subprocess.Popen(['swift','test','--skip-build'],stdout=output,stderr=subprocess.STDOUT,env=env,start_new_session=True)
 while process.poll() is None:
  if time.monotonic()-start>600:
   os.killpg(process.pid,signal.SIGTERM);process.wait(timeout=15);break
  if test_start is None and 'Test run started' in log.read_text(errors='replace'):test_start=time.monotonic()
  if test_start is not None and next_sample is not None and time.monotonic()-test_start>=next_sample:
   raw=subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True)
   procs={}
   for line in raw.splitlines():
    row=line.strip().split(None,2)
    if len(row)==3:procs[int(row[0])]=(int(row[1]),row[2])
   owned=[]
   for pid,(parent,args) in procs.items():
    if 'swiftpm-testing-helper --test-bundle-path /Users/blove/.codex/worktrees/f4fa/b4app/.build/' not in args:continue
    ancestor=parent
    for _ in range(10):
     if ancestor==process.pid:owned.append(pid);break
     if ancestor not in procs:break
     ancestor=procs[ancestor][0]
   for pid in owned:
    dest=base/f'sample-{next_sample}-{pid}.txt';r=subprocess.run(['sample',str(pid),'3','-file',str(dest)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    samples.append(dict(pid=pid,elapsed_from_test_detection=time.monotonic()-test_start,requested_offset=next_sample,exit_code=r.returncode,path=str(dest),sha256=hashlib.sha256(dest.read_bytes()).hexdigest() if dest.exists() else None))
   next_sample=next(targets,None)
  time.sleep(.25)
after=resource.getrusage(resource.RUSAGE_CHILDREN)
record=dict(case_id='diagnostic-full-1',command=['swift','test','--skip-build'],source_catalog=identity,started_at=started,ended_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),wall_seconds=time.monotonic()-start,exit_code=process.returncode,child_cpu_seconds=after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime,sampling_overhead_included=True,samples=samples,log=str(log),log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),test_start_detected=test_start is not None,environment={'TMPDIR':str(runtime),'SWIFTNIO_STRICT':'1','live_provider_flags':'unset'},limitation='Diagnostic run only; sampling and uncontrollable host activity preclude a fair speed comparison')
(base/'diagnostic-full-1.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2));raise SystemExit(process.returncode)
