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
sources=['ShepherdKit/Sources/ShepherdKit/CoreKit/CoreWorkspaceDocument.swift','ShepherdKit/Sources/ShepherdKit/CoreKit/CoreWorkspaceCAS.swift']
test='Tests/CoreWorkspace/CoreWorkspaceTests.swift'
tracked=sources+[test,str(Path(__file__).resolve().relative_to(ROOT))]
def hashes():return {n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
(out/'compiler.txt').write_text(subprocess.check_output(['/usr/bin/xcrun','swiftc','--version'],env=env,text=True,timeout=30))
flags=['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',feature]
profile=out/'no-network.sb';profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages=[];counts=[]
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
sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','iphonesimulator','--show-sdk-path'],env=env,text=True,timeout=30).strip()
stage('ios-typecheck',flags+['-typecheck','-sdk',sdk,'-target',platform.machine()+'-apple-ios17.0-simulator']+sources)
if before!=hashes():raise RuntimeError('source changed during validation')
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':stages,'checks':counts,'network':False,'userCoreUsed':False,'productIntegrationComplete':False},indent=2))
print('PASS workspace schema/CAS:',out)
