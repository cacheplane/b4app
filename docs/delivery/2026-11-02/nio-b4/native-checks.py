import subprocess,os,json,shutil,hashlib,plistlib
from pathlib import Path
base=Path('/tmp/b4-nio-b4-evidence'); native=Path('/tmp/b4-ci-swift-evidence/native');native.mkdir(exist_ok=True)
env=os.environ.copy();env.pop('SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH',None)
original=hashlib.sha256(Path('Package.resolved').read_bytes()).hexdigest()
def run(case,command):
 return subprocess.run(['python3','/tmp/b4-nio-measure.py',case,*command],env=env).returncode
if run('native-project-generation',['./Scripts/generate-project.sh']):raise SystemExit(1)
resolved=Path('B4App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');resolved.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile('Package.resolved',resolved)
matrix=[('native-macos-local','B4App-macOS','platform=macOS',None),('native-ios-local','B4App-iOS','generic/platform=iOS Simulator',None),('native-macos-beta','B4App-macOS-Beta','platform=macOS',None),('native-ios-beta','B4App-iOS-Beta','generic/platform=iOS Simulator',None),('native-macos-prod-release','B4App-macOS','platform=macOS','Release'),('native-ios-prod-release','B4App-iOS','generic/platform=iOS Simulator','Release')]
results=[]
for case,scheme,destination,configuration in matrix:
 command=['xcodebuild','build','-project','B4App.xcodeproj','-scheme',scheme,'-destination',destination,'-clonedSourcePackagesDirPath',str(native/'SourcePackages'),'-derivedDataPath',str(native/'DerivedData'),'-onlyUsePackageVersionsFromResolvedFile','-disablePackageRepositoryCache','CODE_SIGNING_ALLOWED=NO']
 if configuration:command.extend(['-configuration',configuration])
 results.append({'case_id':case,'exit_code':run(case,command)})
assert hashlib.sha256(Path('Package.resolved').read_bytes()).hexdigest()==original,'root dependency lock changed'
products=[]
for app in sorted((native/'DerivedData/Build/Products').glob('*/*.app')):
 plist=app/'Contents/Info.plist' if (app/'Contents/Info.plist').exists() else app/'Info.plist'
 if not plist.exists():continue
 info=plistlib.loads(plist.read_bytes());executable=app/('Contents/MacOS' if (app/'Contents').exists() else '')/info['CFBundleExecutable']
 products.append({'configuration':app.parent.name,'platforms':info.get('CFBundleSupportedPlatforms'),'bundle_id':info.get('CFBundleIdentifier'),'flavor':info.get('B4AppFlavor'),'version':info.get('CFBundleShortVersionString'),'binary_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),'info_plist_sha256':hashlib.sha256(plist.read_bytes()).hexdigest(),'file':subprocess.check_output(['file','-b',str(executable)],text=True).strip(),'artifact_kind':'Unsigned local build product, not distributable package','signing_allowed':False})
expected={('local','MacOSX'):'com.cacheplane.b4app.local',('local','iPhoneSimulator'):'com.cacheplane.b4app.ios.local',('beta','MacOSX'):'com.cacheplane.b4app.beta',('beta','iPhoneSimulator'):'com.cacheplane.b4app.ios',('prod','MacOSX'):'com.cacheplane.b4app',('prod','iPhoneSimulator'):'com.cacheplane.b4app.ios'}
for product in products:
 key=(product['flavor'],product['platforms'][0])
 assert product['bundle_id']==expected[key],('wrong bundle',product)
 assert product['version']=='0.1.0',('wrong version',product)
if not any(r['exit_code'] for r in results):
 assert len(products)==6,('missing build products',products)
(base/'native-products.json').write_text(json.dumps({'root_package_lock_sha256':original,'builds':results,'products':products},indent=2)+'\n')
raise SystemExit(1 if any(r['exit_code'] for r in results) else 0)
