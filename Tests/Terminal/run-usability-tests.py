#!/usr/bin/env python3
"""Private-HOME, bounded parsing/navigation/native modal checks; no app/session operations."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform,shutil
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(o/'home'),CFFIXED_USER_HOME=str(o/'home'),TMPDIR=str(o/'tmp'),CLANG_MODULE_CACHE_PATH=str(o/'cache'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
products=a.swiftterm_products.resolve();shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle',o/'SwiftTerm_SwiftTerm.bundle')
checks=[]
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent'];checks.append(name)
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
markdown=['Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Tests/FilePreview/MarkdownParsingTests.swift']
stage('markdown-build',90,flags+markdown+['-o',str(o/'markdown-tests')]);stage('markdown-tests',20,[str(o/'markdown-tests')])
# Extract the complete real BoardItem declaration, not a replacement enum.
text=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();start=text.index('enum BoardItem:');end=text.index('/// The sidebar content',start);board=o/'BoardItem.swift';board.write_text('import SwiftUI\n'+text[start:end])
models=['Shepherd/HerdrKit/Models/JSONValue.swift','Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/TabModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift']
nav=models+['Shepherd/Hosts/Views/PaneSwitcher.swift','Tests/Terminal/PaneSwitcherTests.swift']
stage('navigation-build',90,flags+nav+[str(board),'-o',str(o/'navigation-tests')]);stage('navigation-tests',20,[str(o/'navigation-tests')])
# Likewise the launcher's real targets and preset rule, without its view.
text=(R/'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text();start=text.index('struct LaunchTarget:');end=text.index('nonisolated enum LaunchProgram',start);launch=o/'LaunchModels.swift';launch.write_text('import SwiftUI\n'+text[start:end])
preset=models+['Tests/Terminal/LaunchPresetTests.swift']
stage('launch-preset-build',90,flags+preset+[str(board),str(launch),'-o',str(o/'launch-preset-tests')]);stage('launch-preset-tests',20,[str(o/'launch-preset-tests')])
# And what ⌘W closes, which the extract carries along with BoardItem.
close=models+['Tests/Terminal/CloseCommandTests.swift']
stage('close-command-build',90,flags+close+[str(board),'-o',str(o/'close-command-tests')]);stage('close-command-tests',20,[str(o/'close-command-tests')])
modal=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Terminal/TerminalPaneFrame.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Tests/Terminal/PreviewModalLayoutTests.swift']
stage('modal-build',90,flags+['-I',str(products)]+modal+[str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(o/'modal-tests')]);stage('modal-tests',25,[str(o/'modal-tests')])
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in set(markdown+nav+preset+close+modal+['Shepherd/ContentView.swift','Shepherd/Shepherd.swift','Shepherd/Hosts/Views/MachinesSettingsView.swift','Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/Hosts/Views/NewTabLauncher.swift','Shepherd/FilePreview/FilePreviewPanel.swift','Shepherd/Terminal/AgentTerminalView.swift','Shepherd/Terminal/AgentTerminalViewModel.swift','Tests/Terminal/LauncherFieldTests.swift'])},indent=2))
# And the launcher's real field, driven as the Korean input method drives it. SwiftUI's faults go to the log, which must not say state was changed during a view update.
text=(R/'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text();start=text.index("/// The launcher's text field");end=text.index('#endif',start);launcherField=o/'LauncherField.swift';launcherField.write_text('import SwiftUI\nimport AppKit\n'+text[start:end].replace('private struct LauncherField','struct LauncherField',1))
stage('launcher-field-build',90,flags+[str(launcherField),'Tests/Terminal/LauncherFieldTests.swift','-framework','AppKit','-o',str(o/'launcher-field-tests')]);stage('launcher-field-tests',20,[str(o/'launcher-field-tests')],mirrorsLog=True)
assert 'Modifying state during view update' not in (o/'launcher-field-tests.log').read_text()
c=(R/'Shepherd/ContentView.swift').read_text();app=(R/'Shepherd/Shepherd.swift').read_text();m=(R/'Shepherd/Hosts/Views/MachinesSettingsView.swift').read_text()
assert '.keyboardShortcut("p", modifiers: .command)' in app and '.focusedSceneValue(\\.isShowingPaneSwitcher' in c
assert 'Window(Text(verbatim: "Shepherd"), id: "main")' in app and 'WindowGroup {' not in app and 'applicationShouldTerminateAfterLastWindowClosed' in app
assert 'CommandGroup(replacing: .newItem)' in app and app.index('show(.blank)')<app.index('.keyboardShortcut("n")')<app.index('show(.currentWorkspace)')<app.index('.keyboardShortcut("t")')
assert '.focusedSceneValue(\\.launcherStart' in c and 'LaunchPreset.current(for: selection(on: machine).wrappedValue, in: launchTargets)' in c
assert 'paneDestinations = []' in c and 'PaneDestination.resolve' in c and 'onDismiss: navigateToPendingPane' in c
assert m.count('.disabled(machine.isLocal || hoveredMachineID != machine.id)')==2 and '.onHover' in m
assert m.index('Label("Active", systemImage: "checkmark.circle.fill")')>m.index('Image(systemName: "trash")')
assert 'panelCoversTerminal: showsFilePreview && expandsFilePreview' in c and '.previewExpansion' in c
b=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();s=json.loads((R/'Shepherd/Localizable.xcstrings').read_text())['strings']
assert 'CommandGroup(replacing: .saveItem)' in app and 'CloseCommands()' in app and app.count('.keyboardShortcut("w")')==1
assert app.index('Button("Close Window")')<app.index('performClose')<app.index('"Close Tab" : "Close Pane"')<app.index('.keyboardShortcut("w")')
assert '.focusedSceneValue(\\.closeCommand' in c and 'closeRequests: closeRequests' in c
assert 'coversTerminal: launcherStart != nil || isShowingSettings || isShowingPaneSwitcher\n                || (showsFilePreview && expandsFilePreview) || webLinkFailure != nil' in c
assert 'guard renaming == nil, closing == nil, actionFailure == nil else { return }\n            closing = selection' in b
assert all(s['Close Window']['localizations'][l]['stringUnit']['state']=='translated' for l in ['ko','ja'])
# The pane switcher and Settings close for a quit, an update's Install and Relaunch included, instead of stopping it with a beep.
assert c.count('.presentationPreventsAppTermination(false)')==2
for k,e in [('.sheet(isPresented: $isShowingPaneSwitcher','.onChange(of: showsTabs)'),('.sheet(isPresented: $isShowingSettings)','.onAppear {')]:i=c.index(k);assert '.presentationPreventsAppTermination(false)' in c[i:c.index(e,i)],k
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'snapshotsOnlyNavigation':True,'actualSwiftTermOwnedKernelPTY':True,'singleModalPanelTerminalIdentityPreserved':True,'installedAppOrSSHOrNetwork':False,'realGUIKeyboardHover':'NOTRUN'},indent=2))
