#!/usr/bin/env python3
"""Real SwiftUI/SwiftTerm migration screen in its own app process and hc HOME.
Never opens/replaces the user's app/core, browser, credentials or CLI settings.
Requires built Debug products; captures only this fixture's own content view.
"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,socket,subprocess,sys,tempfile,time
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as artifacts
p=argparse.ArgumentParser()
p.add_argument('--official-017-archive',type=Path,required=True)
p.add_argument('--products',type=Path,required=True)
a=p.parse_args()
out=Path(tempfile.mkdtemp(prefix='hc-screen-app.',dir='/private/tmp')).resolve()
print(out,flush=True)
for name in ['bin','home','tmp','core']:(out/name).mkdir(mode=0o700)
binary=out/'bin/herdr-core'
provenance=artifacts.extract(artifacts.select(official_017_archive=a.official_017_archive),binary)
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
products=a.products.resolve();app=products/'hrdrhrdrhrdr.app'
exe=app/'Contents/MacOS/hrdrhrdrhrdr'
assert exe.is_file(),'build macOS Debug products first'
tracked=[*sorted((ROOT/'ShepherdKit/Sources/ShepherdKit/CoreKit').glob('*.swift')),
         *sorted((ROOT/'Shepherd/HcBackend').glob('*.swift')),ROOT/'Shepherd/Shepherd.swift',Path(__file__).resolve()]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):digest(p) for p in tracked}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
product=app/'Contents/MacOS/hrdrhrdrhrdr.debug.dylib'
assert all(p.stat().st_mtime<=product.stat().st_mtime for p in tracked if p.suffix=='.swift'),'build current sources first'
(out/'products.json').write_text(json.dumps({str(p.relative_to(app)):digest(p) for p in [exe,product]},indent=2))
(out/'ui-peer.py').write_text("import sys,time\nprint('CJK 한글 😀 real SwiftTerm UI',flush=True)\nprint('HC-UI-RENDER-DONE',flush=True)\ntime.sleep(60)\n")
profile=out/'private-unix.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(out/'core'))+'))\n')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),
     'LANG':'en_US.UTF-8','DO_NOT_TRACK':'1','SHEPHERD_HC_UI_ROOT':str(out),'SHEPHERD_HC_UI_BINARY':str(binary)}
# Network denial canary against only an owned loopback listener.
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0));listener.listen(1)
    probe="import socket,sys,errno\ntry: socket.create_connection(('127.0.0.1',int(sys.argv[1])))\nexcept OSError as e: sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)"
    assert subprocess.run(sandbox+[sys.executable,'-I','-c',probe,str(listener.getsockname()[1])],env=env,timeout=10).returncode==0
log=out/'app.log';report=out/'ui-report.json';failed=None
try:
    code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','60','--natural-exit-grace','10','--log',str(log),'--',*sandbox,str(exe)],env=env,cwd=out,timeout=100).returncode
    stage=json.loads(log.with_suffix('.stage.json').read_text())
    assert code==0 and stage['naturalExitConfirmed'] and not stage['signalsSent'] and stage['cleanupVerified'],'app stage failed'
except BaseException as error:failed=error
finally:
    result=json.loads(report.read_text()) if report.exists() else {}
    sock=out/'core/c.sock'
    if sock.exists():
        core_env={'PATH':'/usr/bin:/bin','HOME':str(out/'core'),'XDG_STATE_HOME':str(out/'core/state'),'XDG_CONFIG_HOME':str(out/'core/config'),
                  'XDG_RUNTIME_DIR':str(out/'core/runtime'),'HC_SESSION':'owned','HC_SOCKET':str(sock),'SSH_CONNECTION':'owned-fixture-no-launchd'}
        stopped=subprocess.run(sandbox+[str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
        (out/'cleanup.json').write_text(json.dumps({'exitCode':stopped.returncode}))
    end=time.monotonic()+5
    while True:
        alive=[]
        for pid in result.get('ownedPIDs',[]):
            try:os.kill(pid,0);alive.append(pid)
            except ProcessLookupError:pass
        if not alive and not sock.exists():break
        if time.monotonic()>end:raise RuntimeError('owned core/holder/program cleanup unconfirmed')
        time.sleep(.025)
passed=failed is None and result.get('passed') is True and bool(result.get('ownedPIDs')) and result.get('screenshot') is True and result.get('sidebarAccessibilityVerified') is True
assert hashes=={str(p.relative_to(ROOT)):digest(p) for p in tracked},'sources changed during validation'
(out/'validation.json').write_text(json.dumps({'passed':passed,'checks':result.get('checks'),'renderedBytes':result.get('renderedBytes'),
    'actualSwiftUI':True,'nativeSwiftTerm':True,'sidebarAccessibilityVerified':result.get('sidebarAccessibilityVerified'),'screenshot':result.get('screenshot'),'browserAuthorityUsed':False,'legacyServicesStarted':False,
    'ownedProcessesExited':bool(result.get('ownedPIDs')),'socketRemoved':not sock.exists(),'releaseCutover':False},indent=2))
if failed:raise failed
assert passed,'UI rendering/cleanup incomplete'
print('PASS hc native workspace UI:',out)
