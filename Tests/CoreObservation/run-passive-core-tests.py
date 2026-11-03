#!/usr/bin/env python3
"""Opt-in passive attributed-screen gate. Uses only an owned private core.
The #14711-only baseline is a negative control and must exit nonzero.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess, sys, time
import candidate_artifact as candidate
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as baseline
p=argparse.ArgumentParser()
g=p.add_mutually_exclusive_group(required=True)
g.add_argument('--candidate-receipt',type=Path)
g.add_argument('--baseline-receipt',type=Path)
p.add_argument('--products',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args(); out=a.output.resolve(); products=a.products.resolve()
out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','core','bin']:(out/name).mkdir(mode=0o700)
binary=out/'bin/herdr-core'
if a.candidate_receipt:
    original, provenance = candidate.select(a.candidate_receipt)
    with original.open('rb') as source,binary.open('xb') as destination: shutil.copyfileobj(source,destination)
    candidate.require(candidate.digest(binary)==provenance['binarySHA256'],'copied binary changed')
    binary.chmod(0o700)
else:
    selected=baseline.select(build_receipt=a.baseline_receipt)
    provenance=baseline.extract(selected,binary)
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
core=out/'core'; sock=core/'c.sock'
candidate.require(len(str(sock).encode())<104,'use a shorter output path')
core_env={'PATH':'/usr/bin:/bin','HOME':str(core),'XDG_STATE_HOME':str(core/'state'),'XDG_CONFIG_HOME':str(core/'config'),
          'XDG_RUNTIME_DIR':str(core/'runtime'),'HC_SOCKET':str(sock),'HC_SESSION':'owned','DO_NOT_TRACK':'1','LANG':'en_US.UTF-8'}
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),
     'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8',
     'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')}
profile=out/'private-network.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(core))+'))\n')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
test='Tests/CoreObservation/PassiveCoreIntegrationTests.swift'; peer='Tests/CoreObservation/passive-peer.py'
tracked=[test,peer,'Tests/CoreObservation/candidate_artifact.py','Tests/CoreObservation/run-passive-core-tests.py',
         'Tests/CoreProtocol/core_test_artifact.py']+[str(f.relative_to(ROOT)) for f in (ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift')]
hashes={n:candidate.digest(ROOT/n) for n in tracked}; (out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
candidate.require(all((ROOT/n).stat().st_mtime<=(products/'ShepherdKit.o').stat().st_mtime for n in tracked if n.startswith('ShepherdKit/')),'build current macOS products first')
(out/'product-hashes.json').write_text(json.dumps({f.name:candidate.digest(f) for f in products.glob('*.o')},indent=2))
for bundle in ['SwiftTerm_SwiftTerm.bundle','ShepherdKit_ShepherdKit.bundle']: shutil.copytree(products/bundle,out/bundle)
maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
    maps+=sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
objects=sorted(str(f) for f in products.glob('*.o'))
flags=['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-target','arm64-apple-macos26.6.2','-I',str(products)]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',feature]
for m in maps:flags+=['-Xcc','-fmodule-map-file='+str(m)]
exe=out/'passive-tests'; report=out/'report.json'
def stage(name,seconds,args):
    log=out/(name+'.log')
    code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
        '--natural-exit-grace','10','--log',str(log),'--',*map(str,args)],cwd=ROOT,env=env,timeout=seconds+40).returncode
    result=json.loads(log.with_suffix('.stage.json').read_text())
    candidate.require(code==0 and result['naturalExitConfirmed'] and not result['signalsSent'] and result['cleanupVerified'],str(log))
stage('build',180,flags+[test,*objects,'-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',exe])
failure=None
try:
    stage('passive',90,sandbox+[exe,binary,core,ROOT/peer,report])
except Exception as error:
    failure=error
finally:
    if sock.exists():
        stopped=subprocess.run(sandbox+[str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
        (out/'cleanup.json').write_text(json.dumps({'exitCode':stopped.returncode}))
    result=json.loads(report.read_text()) if report.exists() else {}
    end=time.monotonic()+5
    while True:
        alive=[]
        for pid in result.get('ownedPIDs',[]):
            try:os.kill(pid,0);alive.append(pid)
            except ProcessLookupError:pass
        if not alive and not sock.exists():break
        if time.monotonic()>end:raise RuntimeError('owned cleanup unconfirmed')
        time.sleep(.025)
candidate.require(hashes=={n:candidate.digest(ROOT/n) for n in tracked},'source changed during test')
passed=failure is None and result.get('passed') is True and bool(result.get('ownedPIDs'))
(out/'validation.json').write_text(json.dumps({'passed':passed,'variant':provenance['variant'],'resizeNegotiated':result.get('resizeNegotiated'),
    'checks':result.get('checks'),'failure':result.get('failure'),'ownedProcessesExited':bool(result.get('ownedPIDs')),
    'socketRemoved':True,'userCoreOrCredentialsUsed':False,'fullAgentParityQualified':False},indent=2))
if failure:raise failure
candidate.require(passed,'passive test did not pass')
print('PASS passive attributed screen:',out)
