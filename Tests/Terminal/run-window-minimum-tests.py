#!/usr/bin/env python3
"""The main window's minimum size (SHPHRD-141): the policy, the production split views at each minimum in owned never-shown windows, and where it is wired in."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
from native_test_env import settings
env,native_flags=settings(o)
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/Support/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent']
 if mirrorsLog:t=log.read_text(errors='replace');assert 'Modifying state during view update' not in t and 'layoutSubtreeIfNeeded' not in t,(name,'runtime warning')
flags=['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*native_flags]
sources=['Shepherd/Hosts/Views/TitleRename.swift','Shepherd/Hosts/Views/TitleRenameField.swift','Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift']
stage('minimum-build',120,flags+sources+['Tests/Terminal/WindowMinimumSizeTests.swift','-framework','AppKit','-o',str(o/'minimum-tests')])
stage('minimum-tests',60,[str(o/'minimum-tests'),str(o/'geometry.json')],mirrorsLog=True)
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in sorted(sources+['Shepherd/HcBackend/HcWorkspaceView.swift','Shepherd/Shepherd.swift','Tests/Terminal/native_test_env.py','Tests/Terminal/run-window-minimum-tests.py'])},indent=2))
# Where it is wired in: the one main window, by its content's minimum.
app=(R/'Shepherd/Shepherd.swift').read_text();c=(R/'Shepherd/HcBackend/HcWorkspaceView.swift').read_text();t=(R/'Tests/Terminal/WindowMinimumSizeTests.swift').read_text()
assert app.count('Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main")')==1 and 'WindowGroup(' not in app and 'WindowGroup {' not in app and 'Settings {' not in app,'one main window, no other scene'
assert app.count('.windowResizability(.contentMinSize)')==1 and app.index('id: "main")')<app.index('.windowResizability(.contentMinSize)')<app.index('.commands {')
for banned in ['.defaultSize','setContentSize','contentMinSize =','setFrame','.windowResizability(.contentSize)']:assert banned not in app and banned not in c,banned
# The main-content minimum is applied inside the workspace view, not on the scene.
assert 'minWidth' not in app
assert c.count('WorkspaceNavigationSplitView(detailMinimumWidth: activePreview?.isShown == true ? 641 : 320) {')==1
assert t.count('detailMinimumWidth: previewShown ? 641 : 320) {')==1,'the fixture takes the detail minimum HcWorkspaceView does'
assert 'panelMinimum: 320, panelIdeal: 560,' in c and '.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)' in c
assert '.frame(minWidth: 320, idealWidth: 560,' in c,'the panel minimum the expression adds'
g=json.loads((o/'geometry.json').read_text());assert len(g)==4
(o/'validation.json').write_text(json.dumps({'passed':True,'ownedUnshownWindows':True,'geometry':g,'realSceneResize':'NOTRUN','fullscreen':'NOTRUN','userGUI':False},indent=2))
print('PASS window minimum size; geometry in',o/'geometry.json')
