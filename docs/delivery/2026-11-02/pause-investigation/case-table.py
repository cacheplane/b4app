from pathlib import Path
import json,csv
out=Path('docs/delivery/2026-11-02/pause-investigation');base=Path('/tmp/b4-pause-evidence')
def ok(n):
 p=base/(n+'.json');return p.exists() and json.loads(p.read_text()).get('exit_code')==0
warm=ok('final-full-warm');cold=ok('final-cold');native=(base/'native-products.json').exists() and all(b['exit_code']==0 for b in json.loads((base/'native-products.json').read_text())['builds']);reuse=(out/'ios-reuse.json').exists();checks=(base/'final-checks.json').exists() and all(r['exit_code']==0 for r in json.loads((base/'final-checks.json').read_text())['results'])
rows=[]
def add(c,n,s,r,g='required'):rows.append(dict(criterion=c,case='pause/'+n,authority='User local CI optimization contract and repository obligations; manifest-v1/v2',gate=g,status=s,reason=r))
add('C01.2','coverage','Pass','All1164 previous tests retained; two cleanup cases added; temporary benchmark archived and removed before final discovery.')
add('C01.3','scope','Pass','One local helper change; no CI worker/timeout/cache/signing/release policy change. No performance assertion added as gate.')
add('C02.1','clocks','Pass','Stage samples separate from command/build/library spans; sampled full run not a speed comparison.')
add('C02.2','attempts','Pass','Mutable-input oracle failure, invalid fixture failure and bad naming expectation failure retained separately from greens.')
add('C02.3','frozen-inputs','Pass','Actual helper with same owned5000entry recipe; inventory and per-case roots recorded retrospectively with limitation; interleaved prototype exact-name controls allpass.')
add('C03.2','historical60s-attribution','Untested','First sample directly identifies one main-thread scan blocker; no proof that every historical pause shared its cause.','advisory')
add('C03.3','focused-stage','Pass','Actual helper frozen median.012842084→.005671750s,55.83% versus10% provisional objective; smallsamples, baselinegroupfirst; no wholeCI claim.')
add('C05.1','identity','Pass','Source/test/harness hashes, root mapping, namespace recipe/digest, toolchain and raw log hashes retained; live names not published.')
add('C05.2','locked-cold','Pass' if cold else 'Untested','Fresh specified cache/config/security/build roots with resolved versions enforced; pinnedPG and system caches disclosed.')
add('C06.2','cold-correctness','Pass' if cold else 'Untested','Final1166 population on isolated cold roots; no shared purge or cold-speed claim.')
add('C08.1','full-reference','Pass' if warm and checks else 'Untested','Final full strict suite plus20Python/48Bats/lints pass; cleanup regressions protect Unicode/types/longnames/missing directories.')
add('C08.3','failure-accounting','Pass','New test fixture errors diagnosed and corrected without changing original assertions/parser; no CI retry installed.')
add('C09.2','cleanup-safety','Pass' if warm else 'Untested','Owned Swift string before next Ccall, errno checked before action; same owner/age/liveness/identity/removal rules. Original orphan/scratch tests retained.')
add('C13.2','recovery','Pass' if warm and cold else 'Untested','Crash scratch recovery remains enabled; no cleanup skipped as optimization; postmaster PID reuse checks preserved.')
add('C14.1','observability','Pass','Only owned test helper sampled; raw stacks/logs local with hashes; sanitized summaries and all failed controls retained.')
add('C14.3','rollback','Pass','Original helper exercised in controlled baseline and candidate restored in finally; file-local reversal, no production recovery claim.')
add('C15.1','resources','Pass','Known command wall/childCPU and static wall separate; prototype/audit/Xcode service CPU gaps explicit, no hosted cost inference.')
add('C15.2','maintainability','Pass','One small macOS-only enumeration helper, no added dependencies or build system; three independent read-only reviews, shared naming-test finding corrected.')
add('C15.3','native','Pass' if native and reuse else 'Untested','Three affected macOS configurations rebuilt; three prior iOS results reused only with unchanged relevant input/digest proof and excluded storage dependency.')
add('C15.3','final-holdout','Pass' if warm and cold and native and checks and reuse else 'Untested','Final source full/cold/macOS/static holdout; IOS reuse separately justified.')
add('C15.3','hosted','Untested','No remote write or candidate CI trigger under nonpublishing scope; no hosted gain/accepted availability claim.')
add('C09.3','invalid-UTF8-branch','Untested','APFS rejects invalid UTF8 fixture at creation (errno92); branch statically reviewed only. No fault-injection branch coverage claimed.','advisory')
with (out/'cases.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=['criterion','case','authority','gate','status','reason']);w.writeheader();w.writerows(rows)
required={s:sum(r['gate']=='required' and r['status']==s for r in rows) for s in ['Pass','Fail','Untested']};g=sum(required.values())
(out/'coverage.json').write_text(json.dumps({'scope':'Only new criterion-case pairs; all preceding atomic assessments remain. Not a quality score.','required':required,'G':g,'assessed_coverage':(required['Pass']+required['Fail'])/g,'verified_pass_coverage':required['Pass']/g,'advisory':{s:sum(r['gate']=='advisory' and r['status']==s for r in rows) for s in ['Pass','Fail','Untested','Not applicable']}},indent=2)+'\n')
