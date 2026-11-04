#!/usr/bin/env python3
"""Pure workspace schema/CAS checks. No core, agent, credentials or network."""
from pathlib import Path
import argparse,hashlib,json,os,platform,subprocess,sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),
     'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8',
     'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')}
sources=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift'))
test='Tests/CoreWorkspace/CoreWorkspaceTests.swift'
store_test='Tests/CoreWorkspace/CoreWorkspaceStoreTests.swift'
lifecycle_test='Tests/CoreWorkspace/CoreWorkspaceLifecycleTests.swift'
delivery_test='Tests/HcBackend/HcTerminalDeliveryTests.swift'
gateway_test='Tests/CoreWorkspace/HcGatewaySnapshotTests.swift'
tracked=sources+[test,store_test,lifecycle_test,delivery_test,gateway_test,str(Path(__file__).resolve().relative_to(ROOT))]
def hashes():return {n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
(out/'compiler.txt').write_text(subprocess.check_output(['/usr/bin/xcrun','swiftc','--version'],env=env,text=True,timeout=30))
flags=['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',feature]
profile=out/'no-network.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages=[];counts=[];store_counts=[];lifecycle_counts=[];delivery_counts=[];gateway_counts=[]
def stage(name,cmd):
    log=out/(name+'.log')
    result=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','120','--natural-exit-grace','5','--log',str(log),'--',*map(str,cmd)],cwd=ROOT,env=env,timeout=155)
    record=json.loads(log.with_suffix('.stage.json').read_text())
    if result.returncode or not record['naturalExitConfirmed'] or record['signalsSent'] or not record['cleanupVerified']:raise RuntimeError(str(log))
    stages.append(name)
for mode,extra in [('debug',[]),('optimized',['-O'])]:
    binary=out/('workspace-'+mode);report=out/(mode+'.json')
    stage(mode+'-build',flags+extra+sources+[test,'-o',binary])
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',profile,binary,report])
    result=json.loads(report.read_text())
    if not result['passed'] or result['checks']<1:raise RuntimeError('no passing checks')
    counts.append(result['checks'])
    store_binary=out/('workspace-store-'+mode);store_report=out/(mode+'-store.json')
    stage(mode+'-store-build',flags+extra+sources+[store_test,'-o',store_binary])
    stage(mode+'-store-tests',['/usr/bin/sandbox-exec','-f',profile,store_binary,store_report])
    value=json.loads(store_report.read_text())
    if not value['passed'] or value['checks']<1:raise RuntimeError('no passing store checks')
    store_counts.append(value['checks'])
    lifecycle_binary=out/('workspace-lifecycle-'+mode);lifecycle_report=out/(mode+'-lifecycle.json')
    stage(mode+'-lifecycle-build',flags+extra+sources+[lifecycle_test,'-o',lifecycle_binary])
    stage(mode+'-lifecycle-tests',['/usr/bin/sandbox-exec','-f',profile,lifecycle_binary,lifecycle_report])
    value=json.loads(lifecycle_report.read_text())
    if not value['passed'] or value['checks']<1:raise RuntimeError('no passing lifecycle checks')
    lifecycle_counts.append(value['checks'])
    delivery_binary=out/('delivery-'+mode);delivery_report=out/(mode+'-delivery.json')
    stage(mode+'-delivery-build',flags+extra+sources+[delivery_test,'-o',delivery_binary])
    stage(mode+'-delivery-tests',['/usr/bin/sandbox-exec','-f',profile,delivery_binary,delivery_report])
    value=json.loads(delivery_report.read_text())
    if not value['passed'] or value['checks']<1:raise RuntimeError('no passing delivery checks')
    delivery_counts.append(value['checks'])
    gateway_binary=out/('gateway-'+mode);gateway_report=out/(mode+'-gateway.json')
    stage(mode+'-gateway-build',flags+extra+sources+[gateway_test,'-o',gateway_binary])
    stage(mode+'-gateway-tests',['/usr/bin/sandbox-exec','-f',profile,gateway_binary,gateway_report])
    value=json.loads(gateway_report.read_text())
    if not value['passed'] or value['checks']<1:raise RuntimeError('no passing gateway metadata checks')
    gateway_counts.append(value['checks'])
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'],env=env,text=True,timeout=30).strip()
stage('ios-typecheck',flags+['-typecheck','-sdk',sdk,'-target',platform.machine()+'-apple-ios17.0-simulator']+sources)
if before!=hashes():raise RuntimeError('source changed during validation')
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'checks':counts,'storeChecks':store_counts,'lifecycleChecks':lifecycle_counts,'deliveryChecks':delivery_counts,'gatewayChecks':gateway_counts,'network':False,'userCoreUsed':False,'productIntegrationComplete':False},indent=2))
print('PASS workspace schema/CAS:',out)
