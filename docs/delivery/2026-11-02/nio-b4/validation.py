import os,time,subprocess
from pathlib import Path
base=Path('/tmp/b4-nio-b4-evidence')
while not (base/'strict-final-full-warm-2.json').exists(): time.sleep(5)
env=dict(os.environ,SWIFTNIO_STRICT='1',B4APP_POSTGRES_BIN=str(Path('.build/postgres/bin').resolve()))
cold=base/'cold';cold.mkdir(exist_ok=True)
commands=[['python3','/tmp/b4-nio-measure.py','final-swift-build','swift','build','--jobs','2'],['python3','/tmp/b4-nio-measure.py','strict-final-cold','swift','test','--jobs','2','--scratch-path',str(cold/'build'),'--cache-path',str(cold/'cache'),'--config-path',str(cold/'config'),'--security-path',str(cold/'security'),'--disable-dependency-cache','--manifest-cache','local','--only-use-versions-from-resolved-file'],['python3','/tmp/b4-nio-native-checks.py']]
statuses=[]
for command in commands:
 print('START',command,flush=True)
 r=subprocess.run(command,env=env);statuses.append(r.returncode)
 print('END',r.returncode,flush=True)
raise SystemExit(any(statuses))
