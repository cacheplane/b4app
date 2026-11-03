import contextlib,importlib.util,io,json,socket,sys,time,hashlib,platform
from unittest import mock
from pathlib import Path
phase=sys.argv[1];base=Path('/tmp/b4-nio-b4-evidence');base.mkdir(exist_ok=True)
root=Path('Tests/B4AdapterTests/Fixtures').resolve()
def module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
results=[]
cases=[('standalone',.25,n) for n in range(3)]+[('managed',.25,n) for n in range(3)]+[('standalone',35,0)]
for entry,delay,repetition in cases:
 fixture=module('profile_fixture',root/'fake-b4.py');fixture.STATE_FILE=None
 with mock.patch.object(sys,'path',sys.path.copy()):cli=module('profile_cli',root/'fake-b4-cli.py')
 calls=[]
 def resolver(host):
  calls.append(host);time.sleep(delay);return 'localhost'
 output=io.StringIO()
 with mock.patch('socket.getfqdn',side_effect=resolver),mock.patch('http.server.ThreadingHTTPServer.serve_forever',side_effect=KeyboardInterrupt),mock.patch.dict(sys.modules,{'fake_b4':fixture}),mock.patch.object(sys,'argv',['fake-b4','--port','0']),contextlib.redirect_stdout(output):
  start=time.monotonic()
  if entry=='standalone':fixture.main()
  else:assert cli.serve(0,'ready at %d')==0
  elapsed=time.monotonic()-start
 assert output.getvalue().strip(),'missing readiness output'
 record=dict(phase=phase,entry=entry,injected_resolver_delay_seconds=delay,repetition=repetition,wall_seconds=elapsed,resolver_calls=len(calls),readiness_seen=True,evidence_mode='B+M controlled resolver injection; not actual CI timing')
 results.append(record);print(json.dumps(record),flush=True)
packet=dict(source_hashes={f:hashlib.sha256((root/f).read_bytes()).hexdigest() for f in ['fake-b4.py','fake-b4-cli.py']},python=platform.python_version(),conditions='Real loopback bind; serve_forever interrupted after readiness; only getfqdn delay injected. Module imports excluded consistently.',observations=results)
(base/(phase+'-bind.json')).write_text(json.dumps(packet,indent=2)+'\n')
