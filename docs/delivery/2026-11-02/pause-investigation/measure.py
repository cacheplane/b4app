import subprocess,time,json,datetime,os,sys,resource,hashlib
from pathlib import Path
case=sys.argv[1];command=sys.argv[2:];base=Path('/tmp/b4-pause-evidence');base.mkdir(exist_ok=True)
env=os.environ.copy()
for name in ['B4APP_LIVE_CODEX','B4APP_LIVE_CLAUDE','B4APP_LIVE_B4_URL','B4APP_LIVE_B4_ROUTE','B4APP_LIVE_B4_TOKEN']:
 env.pop(name,None)
scratch=base/'runtime';scratch.mkdir(exist_ok=True);env['TMPDIR']=str(scratch)+'/'
input_paths=['Sources/WorkspaceStorage/EphemeralPostgres.swift','Tests/WorkspaceStorageTests/ScratchSweepTests.swift','Tests/WorkspaceStorageTests/ScratchScanMeasurementTests.swift','Sources/NIOTransport/UnixSocketTransport.swift','Sources/Coordinator/SocketServer.swift','Tests/CoordinatorTests/CoordinatorTests.swift','Tests/B4AdapterTests/Fixtures/fake-b4-cli.py','Sources/WorkspaceSync/FakeHubAPI.swift','Tests/WorkspaceSyncTests/FakeHubRevocationTests.swift','Tests/CoordinatorTests/HubSyncTests.swift','Tests/CoordinatorTests/SessionTests.swift','Tests/B4AdapterTests/Fixtures/fake-b4.py','.github/workflows/ci.yml']
input_hashes={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in input_paths if Path(p).exists()}
start=time.monotonic();created=datetime.datetime.now(datetime.timezone.utc).isoformat();before=resource.getrusage(resource.RUSAGE_CHILDREN)
with (base/(case+'.log')).open('w') as log:
 r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,env=env)
after=resource.getrusage(resource.RUSAGE_CHILDREN)
record=dict(input_hashes=input_hashes,nio_strict=env.get('SWIFTNIO_STRICT','unset'),test_width=env.get('SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH','default'),case_id=case,command=command,started_at=created,ended_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),wall_seconds=time.monotonic()-start,child_user_seconds=after.ru_utime-before.ru_utime,child_system_seconds=after.ru_stime-before.ru_stime,exit_code=r.returncode,log=str(base/(case+'.log')),source_revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),environment={'TMPDIR':str(scratch),'live_provider_flags':'unset'},cache_state='case-specific; see manifest')
(base/(case+'.json')).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record));sys.exit(r.returncode)
