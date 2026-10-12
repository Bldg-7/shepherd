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
def stage(name,timeout,command):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent'];checks.append(name)
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
markdown=['Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Tests/FilePreview/MarkdownParsingTests.swift']
stage('markdown-build',90,flags+markdown+['-o',str(o/'markdown-tests')]);stage('markdown-tests',20,[str(o/'markdown-tests')])
# Extract the complete real BoardItem declaration, not a replacement enum.
text=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();start=text.index('enum BoardItem:');end=text.index('/// The sidebar content',start);board=o/'BoardItem.swift';board.write_text('import SwiftUI\n'+text[start:end])
nav=['Shepherd/HerdrKit/Models/JSONValue.swift','Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/TabModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift','Shepherd/Hosts/Views/PaneSwitcher.swift','Tests/Terminal/PaneSwitcherTests.swift']
stage('navigation-build',90,flags+nav+[str(board),'-o',str(o/'navigation-tests')]);stage('navigation-tests',20,[str(o/'navigation-tests')])
modal=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Terminal/TerminalPaneFrame.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Tests/Terminal/PreviewModalLayoutTests.swift']
stage('modal-build',90,flags+['-I',str(products)]+modal+[str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(o/'modal-tests')]);stage('modal-tests',25,[str(o/'modal-tests')])
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in set(markdown+nav+modal+['Shepherd/ContentView.swift','Shepherd/Shepherd.swift','Shepherd/Hosts/Views/MachinesSettingsView.swift','Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/FilePreview/FilePreviewPanel.swift','Shepherd/Terminal/AgentTerminalView.swift','Shepherd/Terminal/AgentTerminalViewModel.swift'])},indent=2))
c=(R/'Shepherd/ContentView.swift').read_text();app=(R/'Shepherd/Shepherd.swift').read_text();m=(R/'Shepherd/Hosts/Views/MachinesSettingsView.swift').read_text()
assert '.keyboardShortcut("p", modifiers: .command)' in app and '.focusedSceneValue(\\.isShowingPaneSwitcher' in c
assert 'paneDestinations = []' in c and 'PaneDestination.resolve' in c and 'onDismiss: navigateToPendingPane' in c
assert m.count('.disabled(machine.isLocal || hoveredMachineID != machine.id)')==2 and '.onHover' in m
assert m.index('Label("Active", systemImage: "checkmark.circle.fill")')>m.index('Image(systemName: "trash")')
assert 'panelCoversTerminal: showsFilePreview && expandsFilePreview' in c and '.previewExpansion' in c
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'snapshotsOnlyNavigation':True,'actualSwiftTermOwnedKernelPTY':True,'singleModalPanelTerminalIdentityPreserved':True,'installedAppOrSSHOrNetwork':False,'realGUIKeyboardHover':'NOTRUN'},indent=2))
