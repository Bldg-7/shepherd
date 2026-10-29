#!/usr/bin/env python3
"""The main window's minimum size (SHPHRD-141): the policy, the production split views at each minimum in owned never-shown windows, and where it is wired in."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(o/'home'),CFFIXED_USER_HOME=str(o/'home'),TMPDIR=str(o/'tmp'),CLANG_MODULE_CACHE_PATH=str(o/'cache'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent']
 if mirrorsLog:t=log.read_text(errors='replace');assert 'Modifying state during view update' not in t and 'layoutSubtreeIfNeeded' not in t,(name,'runtime warning')
flags=['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
# The complete real BoardItem declaration, for the rename field.
text=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();start=text.index('enum BoardItem:');end=text.index('/// The sidebar content',start);board=o/'BoardItem.swift';board.write_text('import SwiftUI\n'+text[start:end])
models=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/'+n for n in ['JSONValue.swift','AgentModels.swift','AgentLaunchModels.swift','AgentTitleDisplay.swift','TabModels.swift','HerdrMachine.swift']]
sources=models+['Shepherd/Hosts/Views/TitleRename.swift','Shepherd/Hosts/Views/TitleRenameField.swift','Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift']
stage('minimum-build',120,flags+sources+['Tests/Terminal/WindowMinimumSizeTests.swift',str(board),'-framework','AppKit','-o',str(o/'minimum-tests')])
stage('minimum-tests',60,[str(o/'minimum-tests'),str(o/'geometry.json')],mirrorsLog=True)
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in sorted(sources+['Shepherd/ContentView.swift','Shepherd/Shepherd.swift'])},indent=2))
# Where it is wired in: the one main window, by its content's minimum.
app=(R/'Shepherd/Shepherd.swift').read_text();c=(R/'Shepherd/ContentView.swift').read_text();t=(R/'Tests/Terminal/WindowMinimumSizeTests.swift').read_text()
assert app.count('Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main")')==1 and 'WindowGroup(' not in app and 'WindowGroup {' not in app and 'Settings {' not in app,'one main window, no other scene'
assert app.count('.windowResizability(.contentMinSize)')==1 and app.index('id: "main")')<app.index('.windowResizability(.contentMinSize)')<app.index('.commands {')
for banned in ['.defaultSize','setContentSize','contentMinSize =','setFrame','.windowResizability(.contentSize)']:assert banned not in app and banned not in c,banned
# The 1×1 debug fixtures get no main-content minimum: it is applied inside ContentView.
assert 'Color.clear.frame(width: 1, height: 1)' in app and 'minWidth' not in app
expr='let detailMinimumWidth: CGFloat = 320 + (shownPreview != nil ? 1 + 320 : browserShown ? 1 + 360 : 0)'
assert c.count(expr)==1 and t.count(expr)==1,'the fixture computes the detail minimum as ContentView does'
assert c.count('WorkspaceNavigationSplitView(detailMinimumWidth: detailMinimumWidth) {')==1
assert 'panelMinimum: shownPreview != nil ? 320 : 360,' in c and '.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)' in c
assert '.frame(minWidth: 320, idealWidth: 560,' in c and '.frame(minWidth: 360, idealWidth: 640,' in c,'the panel minimums the expression adds'
g=json.loads((o/'geometry.json').read_text());assert len(g)==6
(o/'validation.json').write_text(json.dumps({'passed':True,'ownedUnshownWindows':True,'geometry':g,'realSceneResize':'NOTRUN','fullscreen':'NOTRUN','userGUI':False},indent=2))
print('PASS window minimum size; geometry in',o/'geometry.json')
