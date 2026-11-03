from pathlib import Path
import subprocess,os,hashlib,json
p=Path('Sources/WorkspaceStorage/EphemeralPostgres.swift');candidate=p.read_bytes();baseline=subprocess.check_output(['git','show','HEAD:Sources/WorkspaceStorage/EphemeralPostgres.swift'])
assert hashlib.sha256(baseline).hexdigest()=='f4346ee00fd32112181f9da393b67ab7b133fc47aababf8822c72ffe00d7081a'
env=dict(os.environ,SWIFTNIO_STRICT='1',B4APP_SCAN_ROOT='/tmp/b4-pause-evidence/scan-control')
statuses=[]
try:
 p.write_bytes(baseline)
 statuses.append(subprocess.run(['python3','/tmp/b4-scratch-measure.py','actual-frozen-baseline','swift','test','--jobs','2','--filter','ScratchScanMeasurementTests'],env=env).returncode)
finally:p.write_bytes(candidate)
statuses.append(subprocess.run(['python3','/tmp/b4-scratch-measure.py','actual-frozen-candidate','swift','test','--jobs','2','--filter','ScratchScanMeasurementTests|ScratchSweepTests'],env=env).returncode)
raise SystemExit(any(statuses))
