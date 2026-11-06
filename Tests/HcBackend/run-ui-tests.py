#!/usr/bin/env python3
"""Real SwiftUI/SwiftTerm migration screen in its own app process and hc HOME.
Never opens/replaces the user's app/core, browser, credentials or CLI settings.
Requires built Debug products; captures only this fixture's own content view.
"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,socket,subprocess,sys,tempfile,time,plistlib,ctypes,signal
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/CoreProtocol'))
import core_test_artifact as artifacts
from ui_artifacts import remove_staged_bundles
p=argparse.ArgumentParser()
p.add_argument('--official-017-archive',type=Path,required=True)
p.add_argument('--products',type=Path,required=True)
p.add_argument('--human-activation',action='store_true',help='Allow time for a person to click only the owned helper window; all GUI assertions still required')
p.add_argument('--manual-inspection',action='store_true',help='Open an interactive private workspace, without running/claiming automated GUI checks')
p.add_argument('--manual-seconds',type=int,default=1200,help='Manual session lifetime, 60–1800 seconds; owned programs retire on exit')
p.add_argument('--layout-audit',action='store_true',help='Audit actual hc composition/sidebar using public native actions')
p.add_argument('--fullscreen-audit',action='store_true',help='Also exercise the owned fullscreen Space/edge reveal; moves and restores pointer')
p.add_argument('--pointer-warp-only',action='store_true',help='Fullscreen diagnostic: omit self-window synthetic mouse movement; never a physical gesture claim')
a=p.parse_args()
if a.pointer_warp_only and not a.fullscreen_audit:p.error('pointer-warp-only requires fullscreen-audit')
a.layout_audit=a.layout_audit or a.fullscreen_audit
if a.manual_inspection and a.layout_audit:p.error('manual inspection and layout audit are separate modes')
if not 60 <= a.manual_seconds <= 1800:p.error('manual-seconds must be 60–1800')
stage_seconds=a.manual_seconds+90 if a.manual_inspection else (270 if a.human_activation else (120 if a.layout_audit else 60))
out=Path(tempfile.mkdtemp(prefix='hc-screen-app.',dir='/private/tmp')).resolve()
print(out,flush=True)
for name in ['bin','home','tmp','core']:(out/name).mkdir(mode=0o700)
binary=out/'bin/herdr-core'
provenance=artifacts.extract(artifacts.select(official_017_archive=a.official_017_archive),binary)
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
products=a.products.resolve();app=products/'hrdrhrdrhrdr.app'
exe=app/'Contents/MacOS/hrdrhrdrhrdr'
assert exe.is_file(),'build macOS Debug products first'
tracked=[*sorted((ROOT/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift')),
         *sorted((ROOT/'Shepherd').rglob('*.swift')),ROOT/'Tests/HcBackend/OwnedUILauncher.swift',ROOT/'Tests/HcBackend/ui_artifacts.py',Path(__file__).resolve()]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):digest(p) for p in tracked}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
product=app/'Contents/MacOS/hrdrhrdrhrdr.debug.dylib'
assert all(p.stat().st_mtime<=product.stat().st_mtime for p in tracked if p.suffix=='.swift' and not p.is_relative_to(ROOT/'Tests')),'build current sources first'
(out/'products.json').write_text(json.dumps({str(p.relative_to(app)):digest(p) for p in [exe,product]},indent=2))
(out/'owned-preview.md').write_text('# HC-FILE-PREVIEW-CONTENT\n\nOwned hc file preview, not browser content.\n')
(out/"drop fixture's.png").write_bytes(b'owned-drop-fixture')
(out/'ui-peer.py').write_text("import sys,time,tty,pathlib\nroot=pathlib.Path(__file__).parent\nprint('CJK 한글 😀 real SwiftTerm UI',flush=True)\nprint('HC-UI-RENDER-DONE',flush=True)\ninput()\nlink=(root/'owned-preview.md').as_uri()\nprint('\\x1b]8;;'+link+'\\x1b\\\\Open owned preview\\x1b]8;;\\x1b\\\\',flush=True)\ntty.setraw(sys.stdin.fileno())\nprint('HC-DROP-READY',flush=True)\nexpected=(root/'drop-expected.txt').read_bytes()\ndata=sys.stdin.buffer.read(len(expected))\n(root/'drop-received.bin').write_bytes(data)\nprint('HC-DROP-RECEIVED',flush=True)\nrow=root/'row-drop-expected.txt'\nif row.exists():\n expected_row=row.read_bytes()\n (root/'row-drop-received.bin').write_bytes(sys.stdin.buffer.read(len(expected_row)))\n print('HC-ROW-DROP-RECEIVED',flush=True)\ntime.sleep(60)\n")
if a.human_activation:
    peer=out/'ui-peer.py';peer.write_text(peer.read_text().replace('time.sleep(60)','time.sleep(300)'))
profile=out/'private-unix.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network* (subpath '+json.dumps(str(out/'core'))+'))\n')
sandbox=['/usr/bin/sandbox-exec','-f',str(profile)]
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),
     'LANG':'en_US.UTF-8','DO_NOT_TRACK':'1','SHEPHERD_HC_UI_ROOT':str(out),'SHEPHERD_HC_UI_BINARY':str(binary)}
if a.human_activation or a.manual_inspection:env['SHEPHERD_HC_UI_HUMAN_ACTIVATION']='1'
if a.manual_inspection:env['SHEPHERD_HC_UI_MANUAL_SECONDS']=str(a.manual_seconds)
if a.layout_audit:env['SHEPHERD_HC_UI_LAYOUT_AUDIT']='1'
if a.fullscreen_audit:env['SHEPHERD_HC_UI_FULLSCREEN_AUDIT']='1'
if a.pointer_warp_only:env['SHEPHERD_HC_UI_POINTER_WARP_ONLY']='1'
# Network denial canary against only an owned loopback listener.
with socket.socket() as listener:
    listener.bind(('127.0.0.1',0));listener.listen(1)
    probe="import socket,sys,errno\ntry: socket.create_connection(('127.0.0.1',int(sys.argv[1])))\nexcept OSError as e: sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)"
    canary_port=listener.getsockname()[1]
    assert subprocess.run(sandbox+[sys.executable,'-I','-c',probe,str(canary_port)],env=env,timeout=10).returncode==0
# An owned, uniquely identified GUI helper voluntarily yields activation to
# its own sandboxed child. Product CFBundleExecutable and tested Mach-O bytes
# remain unchanged. The helper never opens a user's app or borrows its focus.
fixture_app=out/'OwnedShepherd.app'
subprocess.run(['/bin/cp','-cR',str(app),str(fixture_app)],check=True,timeout=90)
info_path=fixture_app/'Contents/Info.plist';info=plistlib.loads(info_path.read_bytes())
assert not info.get('SUFeedURL'),'only non-updating Debug builds may be staged'
bundle_id='com.bldg7.shepherd.owned-hc-ui.'+out.name.replace('.','-')
info['CFBundleIdentifier']=bundle_id;info['CFBundleName']='Owned HC UI'
for key in ['CFBundleURLTypes','CFBundleDocumentTypes','NSUserActivityTypes']:info.pop(key,None)
info_path.write_bytes(plistlib.dumps(info))
actual_exe=fixture_app/'Contents/MacOS/hrdrhrdrhrdr'
assert digest(actual_exe)==digest(exe) and digest(fixture_app/'Contents/MacOS/hrdrhrdrhrdr.debug.dylib')==digest(product),'fixture code must match built products'
env['SHEPHERD_HC_UI_CANARY_PORT']=str(canary_port)
(out/'launch-environment.json').write_text(json.dumps({**env,'__CFBundleIdentifier':bundle_id}))
helper=out/'OwnedUILauncher.app';(helper/'Contents/MacOS').mkdir(parents=True)
helper_exe=helper/'Contents/MacOS/helper'
(helper/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle_id+'.launcher','CFBundleName':'Owned hc UI launcher','CFBundleExecutable':'helper','CFBundlePackageType':'APPL','NSPrincipalClass':'NSApplication','LSUIElement':False}))
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(ROOT/'Tests/HcBackend/OwnedUILauncher.swift'),str(ROOT/'Shepherd/HcBackend/HcFixtureBundlePath.swift'),'-o',str(helper_exe)],check=True,timeout=60)
subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none',str(helper)],check=True,capture_output=True,timeout=30)
for name in ['app.stdout.log','app.stderr.log']:(out/name).touch(mode=0o600)
(out/'fixture-bundle.json').write_text(json.dumps({'bundleID':bundle_id,'bundle':str(fixture_app),'helper':str(helper),'originalExecutableSHA256':digest(exe),'fixtureExecutableSHA256':digest(actual_exe),'launcherSourceSHA256':digest(ROOT/'Tests/HcBackend/OwnedUILauncher.swift'),'sandboxBeforeAppExec':True},indent=2))
log=out/'app.log';report=out/'ui-report.json';failed=None
try:
    command=[sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(stage_seconds),'--natural-exit-grace','10','--log',str(log),'--','/usr/bin/open','-n','-W','--env','SHEPHERD_OWNED_UI_LAUNCH_ROOT='+str(out),'--env','HOME='+str(out/'home'),'--env','CFFIXED_USER_HOME='+str(out/'home'),'--env','TMPDIR='+str(out/'tmp'),str(helper)]
    child=subprocess.Popen(command,env=env,cwd=out)
    announced=False;focus_announced=False;focus_requested=None;deadline=time.monotonic()+stage_seconds+40
    try:
        while child.poll() is None:
            if not announced:
                if a.manual_inspection and (out/'manual-ready.json').exists():
                    print('MANUAL_READY: '+str(out),flush=True);announced=True
                elif not a.manual_inspection and (out/'ui-foreground-ready.json').exists():
                    print('UI_RUNNING_NO_INPUT: '+str(out),flush=True);announced=True
                elif not a.manual_inspection and (out/'ui-wants-focus.json').exists():
                    if focus_requested is None:focus_requested=time.monotonic()
                    # Let the owned activation handoff settle before asking for
                    # a human click that could arrive during an active test.
                    if not focus_announced and time.monotonic()-focus_requested>=1:
                        print('UI_FOCUS_REQUIRED: '+str(out),flush=True);focus_announced=True
            if time.monotonic()>=deadline:raise subprocess.TimeoutExpired(command,stage_seconds+40)
            time.sleep(.2)
        code=child.wait()
    finally:
        if child.poll() is None:child.terminate();child.wait(timeout=15)
    stage=json.loads(log.with_suffix('.stage.json').read_text())
    assert code==0 and stage['naturalExitConfirmed'] and not stage['signalsSent'] and stage['cleanupVerified'],'app stage failed'
except BaseException as error:failed=error
finally:
    identity=out/'launched-identities.json'
    identities=json.loads(identity.read_text()) if identity.exists() else {}
    app_pid=identities.get('appPID');helper_pid=identities.get('helperPID')
    libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
    for pid,expected_exe in [(app_pid,actual_exe),(helper_pid,helper_exe)]:
        if not pid:continue
        buf=ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(int(pid),buf,len(buf))>0 and os.fsdecode(buf.value)==str(expected_exe):
            os.kill(int(pid),signal.SIGTERM)
            failed=failed or RuntimeError('owned app/helper required forced cleanup; not a healthy pass')
    registration=[]
    for bundle in [fixture_app,helper]:
        try:
            result_code=subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(bundle)],capture_output=True,timeout=15).returncode
            registration.append({'bundle':str(bundle),'exitCode':result_code})
            if result_code:failed=failed or RuntimeError('owned LaunchServices cleanup failed')
        except BaseException as error:failed=failed or error
    (out/'launchservices-cleanup.json').write_text(json.dumps(registration))
    result=json.loads(report.read_text()) if report.exists() else {}
    sock=out/'core/c.sock'
    if sock.exists():
        core_env={'PATH':'/usr/bin:/bin','HOME':str(out/'core'),'XDG_STATE_HOME':str(out/'core/state'),'XDG_CONFIG_HOME':str(out/'core/config'),
                  'XDG_RUNTIME_DIR':str(out/'core/runtime'),'HC_SESSION':'owned','HC_SOCKET':str(sock),'SSH_CONNECTION':'owned-fixture-no-launchd'}
        if a.manual_inspection:
            # Only this owned scope: these CLI calls can autostart a private
            # core on a race, never inspect/start the user's daemon or launchd.
            for command in [['server','status','--json'],['ls','--all','--json']]:
                try:
                    latest=subprocess.run(sandbox+[str(binary),*command],env=core_env,capture_output=True,timeout=10)
                    if latest.returncode==0:
                        value=json.loads(latest.stdout)
                        extra=([value['pid']]+[v['pid'] for v in value.get('holders',[])]) if command[0]=='server' else [v['pid'] for v in value.get('terminals',[]) if v.get('pid')]
                        result['ownedPIDs']=sorted(set(result.get('ownedPIDs',[])+extra))
                except BaseException as error:failed=failed or error
            (out/'manual-cleanup-identities.json').write_text(json.dumps(result))
        stopped=subprocess.run(sandbox+[str(binary),'server','stop'],env=core_env,capture_output=True,timeout=10)
        (out/'cleanup.json').write_text(json.dumps({'exitCode':stopped.returncode}))
    end=time.monotonic()+5
    while True:
        alive=[]
        for pid in result.get('ownedPIDs',[])+[pid for pid in [app_pid,helper_pid] if pid]:
            try:os.kill(pid,0);alive.append(pid)
            except ProcessLookupError:pass
        if not alive and not sock.exists():break
        if time.monotonic()>end:raise RuntimeError('owned core/holder/program cleanup unconfirmed')
        time.sleep(.025)
    artifact_cleanup = {'removed': [], 'skipped': 'missing owned app/helper/core identities'}
    if bool(result.get('ownedPIDs')) and app_pid and helper_pid:
        try:
            removed = remove_staged_bundles(out, registration, retirement_verified=not alive and not sock.exists())
            artifact_cleanup = {'removed': removed, 'logsAndReportsPreserved': True}
        except BaseException as error:
            artifact_cleanup = {'removed': [], 'error': type(error).__name__}
            failed = failed or error
    (out/'artifact-cleanup.json').write_text(json.dumps(artifact_cleanup,indent=2))
if a.layout_audit:
    audit_path=out/'layout-audit.json'
    audit=json.loads(audit_path.read_text()) if audit_path.exists() else {}
    good=failed is None and audit.get('passed') is True and bool(result.get('ownedPIDs'))
    if a.fullscreen_audit:good=good and audit.get('fullscreenSpaceAndEdgeReveal') is True and audit.get('fullscreenExitRestored') is True
    (out/'validation.json').write_text(json.dumps({'passed':good,'checks':audit.get('checks'),'actualHcRoot':True,
        'fullscreenSpaceAndEdgeReveal':audit.get('fullscreenSpaceAndEdgeReveal',False),'fullscreenExitRestored':audit.get('fullscreenExitRestored',False),'wholeUIParityQualified':False,
        'physicalDividerDrag':'NOTRUN','physicalRowDragQualified':False,'rowDragComponentIntegration':audit.get('rowDragComponentIntegration',False),'ownedProcessesExited':not alive,'socketRemoved':not sock.exists(),'releaseCutover':False},indent=2))
    assert hashes=={str(p.relative_to(ROOT)):digest(p) for p in tracked},'source changed during audit'
    if failed:raise failed
    assert good,'actual hc composition/layout audit failed'
    print('PASS actual hc root layout audit:',out,flush=True)
    sys.exit(0)
if a.manual_inspection:
    (out/'manual-result.json').write_text(json.dumps({'sessionEnded':True,'cleanupVerified':failed is None,'automatedGUIQualified':False,'releaseCutover':False,'ownedPIDs':result.get('ownedPIDs',[])},indent=2))
    if failed:raise failed
    print('MANUAL SESSION CLOSED; no automated GUI qualification:',out,flush=True)
    sys.exit(0)
passed=failed is None and result.get('passed') is True and bool(result.get('ownedPIDs')) and result.get('screenshot') is True and result.get('sidebarAccessibilityVerified') is True and result.get('productFactoryVerified') is True and result.get('filePreviewVerified') is True and result.get('fileDropVerified') is True and result.get('windowCommandsVerified') is True and result.get('paneSwitcherVerified') is True and result.get('settingsVerified') is True and result.get('closeViewKeepsProgram') is True and result.get('recoveryReviewVerified') is True and result.get('forgetTrackingKeepsProgram') is True and result.get('originDirectoryVerified') is True
assert hashes=={str(p.relative_to(ROOT)):digest(p) for p in tracked},'sources changed during validation'
(out/'validation.json').write_text(json.dumps({'passed':passed,'checks':result.get('checks'),'renderedBytes':result.get('renderedBytes'),
    'actualSwiftUI':True,'nativeSwiftTerm':True,'humanActivationRequested':a.human_activation,'foregroundAssertionsRequired':True,'windowCommandsVerified':result.get('windowCommandsVerified'),'paneSwitcherVerified':result.get('paneSwitcherVerified'),'settingsVerified':result.get('settingsVerified'),'closeViewKeepsProgram':result.get('closeViewKeepsProgram'),'recoveryReviewVerified':result.get('recoveryReviewVerified'),'forgetTrackingKeepsProgram':result.get('forgetTrackingKeepsProgram'),'originDirectoryVerified':result.get('originDirectoryVerified'),'filePreviewVerified':result.get('filePreviewVerified'),'fileDropVerified':result.get('fileDropVerified'),'productFactoryVerified':result.get('productFactoryVerified'),'sidebarAccessibilityVerified':result.get('sidebarAccessibilityVerified'),'screenshot':result.get('screenshot'),'browserAuthorityUsed':False,'legacyServicesStarted':False,
    'ownedProcessesExited':bool(result.get('ownedPIDs')),'socketRemoved':not sock.exists(),'releaseCutover':False},indent=2))
if failed:raise failed
assert passed,'UI rendering/cleanup incomplete'
print('PASS hc native workspace UI:',out)
