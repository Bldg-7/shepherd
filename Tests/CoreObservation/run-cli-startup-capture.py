#!/usr/bin/env python3
"""Real CLI startup in owned hc PTYs; no prompts, account login or browser lease.
Requires the locally verified inventory and pinned passive core candidate.
"""
from pathlib import Path
import argparse,json,os,shutil,subprocess,sys,time,uuid
sys.dont_write_bytecode=True
import candidate_artifact as artifact
import cli_isolation as isolation
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--inventory',type=Path,required=True)
p.add_argument('--candidate-receipt',type=Path,required=True)
p.add_argument('--products',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();products=a.products.resolve();inventory=a.inventory.resolve()
checked=json.loads((inventory/'validation.json').read_text());artifact.require(checked['passed'] and all(checked['boundary'].values()),'inventory boundary failed')
manifest=json.loads((inventory/'executables.json').read_text())
paths={name:Path(manifest[name]['path']) for name in ['claude','codex','pi','node']}
for name,path in paths.items():artifact.require(isolation.digest(path)==manifest[name]['sha256'],'CLI changed since inventory')
packages=[Path(p['path']) for p in manifest['packages']]
for package,record in zip(packages,manifest['packages']):artifact.require(isolation.digest(package/'package.json')==record['manifestSHA256'],'package changed')
original,provenance=artifact.select(a.candidate_receipt)
out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['bin','core','home','tmp','cache','harness']:(out/name).mkdir(mode=0o700)
binary=out/'bin/herdr-core';shutil.copyfile(original,binary);binary.chmod(0o700)
artifact.require(artifact.digest(binary)==provenance['binarySHA256'],'copied core changed')
(out/'provenance.json').write_text(json.dumps({'core':provenance,'cli':manifest},indent=2))
executables=[str(paths[k]) for k in ['node','claude','codex']]
cases=[]
pi_session=str(uuid.uuid4())
probe_extension=out/'harness/CLIIdentityObserver.ts'
shutil.copyfile(ROOT/'Tests/CoreObservation/CLIIdentityObserver.ts',probe_extension)
claude_common=['--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--disable-slash-commands','--no-chrome','--session-id',str(uuid.uuid4())]
commands={'claude-clean':[str(paths['claude']),*claude_common],
          'claude-bare':[str(paths['claude']),'--bare',*claude_common[:-1],str(uuid.uuid4())],
          'codex':[str(paths['codex']),'--no-daemon','--sandbox','read-only','--strict-config'],
          'pi':[str(paths['node']),str(paths['pi']),*isolation.PI_FLAGS,'--session-id',pi_session,'--extension',str(probe_extension)]}
for name,argv in commands.items():
    home=out/name;home.mkdir(mode=0o700)
    env=isolation.environment(home,paths['node']);env['TERM_PROGRAM']='3rdr-fixture'
    work=home/'work';work.mkdir(mode=0o700)
    case={'name':name,'argv':argv,'cwd':str(work),'environment':env}
    if name=='pi':
        trace=home/'lifecycle.jsonl';env['HC_CLI_TRACE']=str(trace)
        case.update(tracePath=str(trace),expectedSessionID=pi_session)
    cases.append(case)
plan=out/'plan.json';plan.write_text(json.dumps({'binary':str(binary),'coreHome':str(out/'core'),'output':str(out),'cases':cases},indent=2))
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),
     'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8',
     'DEVELOPER_DIR':os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')}
core=out/'core';sock=core/'c.sock';artifact.require(len(str(sock).encode())<104,'shorter output path required')
core_env={'PATH':'/usr/bin:/bin','HOME':str(core),'XDG_STATE_HOME':str(core/'state'),'XDG_CONFIG_HOME':str(core/'config'),
          'XDG_RUNTIME_DIR':str(core/'runtime'),'HC_SESSION':'owned','HC_SOCKET':str(sock),'DO_NOT_TRACK':'1'}
exe=out/'cli-capture'
profile=out/'inherited-cli.sb'
profile.write_text(isolation.profile(out,[*executables,str(binary),str(exe)],packages,core_runtime=True,core_home=core,missing_config_roots=['/etc/codex']))
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
# Different nested seatbelt profiles are refused by macOS. Apply the one
# checked policy to the controller/core before spawning; every CLI inherits it.
import tempfile,socket
probe=out/'probe.cjs';shutil.copyfile(ROOT/'Tests/CoreObservation/cli-boundary-probe.cjs',probe)
canary=out/'home/canary';canary.write_text('nonsecret-canary')
with tempfile.TemporaryDirectory(prefix='cli-capture-denied.') as d,socket.socket() as listener:
    outside=Path(d).resolve()/'canary';outside.write_text('nonsecret-canary')
    listener.bind(('127.0.0.1',0));listener.listen(1)
    probe_result=subprocess.run(sandbox+[str(paths['node']),str(probe),str(canary),str(outside),str(listener.getsockname()[1])],env=env,cwd=out/'home',capture_output=True,timeout=10,start_new_session=True)
    (out/'boundary-probe.log').write_bytes(probe_result.stdout+probe_result.stderr)
    artifact.require(probe_result.returncode==0 and outside.read_text()=='nonsecret-canary','inherited boundary probe failed; no CLI started')
    boundary=json.loads(probe_result.stdout);artifact.require(all(boundary.values()),'boundary not enforced')
    (out/'boundary.json').write_text(json.dumps(boundary,indent=2))
test='Tests/CoreObservation/CLIStartupCapture.swift'
tracked=[test,'Tests/CoreObservation/cli-boundary-probe.cjs','Tests/CoreObservation/CLIIdentityObserver.ts','Tests/CoreObservation/cli_isolation.py','Tests/CoreObservation/run-cli-startup-capture.py']
tracked += [str(f.relative_to(ROOT)) for f in (ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift')]
hashes={n:artifact.digest(ROOT/n) for n in tracked};(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
artifact.require(all((ROOT/n).stat().st_mtime<=(products/'ShepherdKit.o').stat().st_mtime for n in tracked if n.startswith('ShepherdKit/')),'build current macOS products')
(out/'product-hashes.json').write_text(json.dumps({f.name:artifact.digest(f) for f in products.glob('*.o')},indent=2))
for bundle in ['SwiftTerm_SwiftTerm.bundle','ShepherdKit_ShepherdKit.bundle']:shutil.copytree(products/bundle,out/bundle)
maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
    maps+=sorted(m for m in base.rglob('module.modulemap') if 'Benchmarks' not in m.parts)
flags=['/usr/bin/xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-target','arm64-apple-macos26.6.2','-I',str(products)]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',feature]
for m in maps:flags+=['-Xcc','-fmodule-map-file='+str(m)]
exe=out/'cli-capture';report=out/'report.json'
def stage(name,seconds,args):
    log=out/(name+'.log')
    code=subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10',
                         '--log',str(log),'--',*map(str,args)],cwd=ROOT,env=env,timeout=seconds+40).returncode
    result=json.loads(log.with_suffix('.stage.json').read_text())
    artifact.require(code==0 and result['naturalExitConfirmed'] and not result['signalsSent'] and result['cleanupVerified'],str(log))
stage('build',180,flags+[test,*sorted(str(f) for f in products.glob('*.o')),'-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore','-lz','-lsqlite3','-o',exe])
failure=None
try:stage('capture',180,sandbox+[exe,plan])
except Exception as error:failure=error
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
        if time.monotonic()>end:raise RuntimeError('owned CLI/core cleanup unconfirmed')
        time.sleep(.025)
artifact.require(hashes=={n:artifact.digest(ROOT/n) for n in tracked},'source changed during capture')
for name,path in paths.items():artifact.require(isolation.digest(path)==manifest[name]['sha256'],'CLI changed during capture')
complete=failure is None and result.get('captureCompleted') is True and bool(result.get('ownedPIDs'))
rows=result.get('cases',[])
usable=len(rows)==4 and not result.get('eventCaptureError',True) and all(not r.get('captureError') and not r.get('streamError') and r.get('capturedBytes',0)>0 for r in rows)
pi=next((r for r in rows if r.get('name')=='pi'),{})
pi_lifecycle=all(pi.get(k) is True for k in ['expectedExecutableObserved','nativeSessionStartObserved','sessionIDChanged','oldSessionShutdownObserved','sameProcessAcrossSessionSwitch']) and pi.get('unexpectedInputBlocked') is False
(out/'validation.json').write_text(json.dumps({'captureCompleted':complete,'ownedProcessesExited':bool(result.get('ownedPIDs')),'socketRemoved':True,
    'requestedRealCLIs':True,'observationsUsable':usable,'piLifecycleSmokePassed':pi_lifecycle,'inheritedSandbox':True,'boundary':boundary,'modelPrompts':0,'realCredentialsUsed':False,'parentDescriptorForwarded':False,'browserAuthorityGranted':False,
    'fullAgentParityQualified':False,'cases':result.get('cases',[])},indent=2))
if failure:raise failure
artifact.require(complete and usable and pi_lifecycle,'capture or Pi lifecycle observation incomplete')
print('Completed isolated real CLI measurements, NOT ready/auth qualification:',out)
