#!/usr/bin/env python3
"""Rename Tab/Pane typed into the window's title: rules, the production field and toolbar in owned never-shown windows, wiring."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(o/'home'),CFFIXED_USER_HOME=str(o/'home'),TMPDIR=str(o/'tmp'),CLANG_MODULE_CACHE_PATH=str(o/'cache'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
checks=[]
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent'];checks.append(name)
 # With the system log mirrored, SwiftUI's and AppKit's runtime complaints land in the log too.
 if mirrorsLog:t=log.read_text(errors='replace');assert 'Modifying state during view update' not in t and 'layoutSubtreeIfNeeded' not in t,(name,'runtime warning')
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']
# The complete real BoardItem declaration, not a replacement enum.
text=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();start=text.index('enum BoardItem:');end=text.index('/// The sidebar content',start);board=o/'BoardItem.swift';board.write_text('import SwiftUI\n'+text[start:end])
models=['Shepherd/HerdrKit/Models/JSONValue.swift','Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/TabModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift']
rules=models+['Shepherd/Hosts/Views/TitleRename.swift']
stage('model-build',90,flags+rules+['Tests/Terminal/TitleRenameTests.swift',str(board),'-o',str(o/'model-tests')]);stage('model-tests',20,[str(o/'model-tests')])
field=rules+['Shepherd/Hosts/Views/TitleRenameField.swift']
stage('field-build',90,flags+field+['Tests/Terminal/TitleRenameFieldTests.swift',str(board),'-framework','AppKit','-o',str(o/'field-tests')]);stage('field-tests',30,[str(o/'field-tests')],mirrorsLog=True)
split=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift']
stage('toolbar-build',90,flags+field+split+['Tests/Terminal/TitleRenameToolbarTests.swift',str(board),'-framework','AppKit','-o',str(o/'toolbar-tests')]);stage('toolbar-tests',30,[str(o/'toolbar-tests')],mirrorsLog=True)
sources=set(field+split+['Shepherd/ContentView.swift','Shepherd/Hosts/Views/AgentBoardView.swift','Shepherd/Terminal/AgentTerminalView.swift','Shepherd/Terminal/TabTerminalView.swift'])
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in sorted(sources)},indent=2))
# Where it is wired in.
b=(R/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text();c=(R/'Shepherd/ContentView.swift').read_text();f=(R/'Shepherd/Hosts/Views/TitleRenameField.swift').read_text()
agent=(R/'Shepherd/Terminal/AgentTerminalView.swift').read_text();tab=(R/'Shepherd/Terminal/TabTerminalView.swift').read_text()
# The board: no rename dialog; its Rename items start a rename in the title, of the item they select.
assert '.alert(renameTitle' not in b and 'TextField(renamePrompt' not in b and 'Button("Rename")' not in b,'no rename dialog'
assert 'Button("Rename Pane…") { beginRenaming(.pane(agent)) }' in b and 'Button("Rename Tab…") { beginRenaming(.tab(tab)) }' in b
begin=b[b.index('    private func beginRenaming('):b.index('    private func rename(')]
assert begin.index('selection = item')<begin.index('renaming = TitleRenameSession(item: item)'),'the item is selected first: the title is the selected item\'s'
# ⌘W closes nothing while a name is typed into the title, as over the dialog before.
assert 'guard renaming == nil, closing == nil, actionFailure == nil else { return }\n            closing = selection' in b
# A rename that doesn't go through: the same failure as before, and the title goes back.
assert 'perform(failureTitle: String(localized: "Couldn\'t Rename"), succeeded:' in b and 'if renameCommit?.id == commit.id { renameCommit = nil }' in b
assert b.count('settleRenameCommit(onHerdrMachine:')==3,'settled by reads of the host and of herdr machines'
# The title: the field in its place while a name is typed; the typed name shown on the terminal's title until herdr reports it.
assert '.toolbar(removing: titleRenameShown(on: machine) == nil ? nil : .title)' in c and 'ToolbarItem(placement: .navigation) {\n                        TitleRenameField(' in c
assert '.sharedBackgroundVisibility(.hidden)' in c and '.id(session.id)' in c
assert 'let typedTitle = renameCommit?.title(for: item)' in c and 'title: typedTitle)' in c and 'takesKeyboardWhenShown: titleRename == nil, title: typedTitle)' in c
assert '.navigationTitle(title ?? agent.title)' in agent and '.navigationTitle(title ?? tab.title)' in tab
assert 'focusesWhenShown: takesKeyboardWhenShown && shouldInitiallyFocus(pane)' in tab
assert 'return renameCommit?.title(for: item) ?? item.title' in c
# A new rename drops a stale request for a terminal to take the keyboard; a machine change sends nothing.
nb=c[c.index('    private func beginTitleRename('):c.index('    private func endTitleRename(')]
assert 'terminalPaneFocus = nil' in nb and 'endTitleRename(titleRename, .left)' in nb
assert 'if let titleRename {\n                _ = titleRename.end()\n                self.titleRename = nil\n            }\n            renameCommit = nil' in c
assert 'if let titleRename, titleRename.item.id != id {\n                endTitleRename(titleRename, .left)' in c
# The field: its text is only ever set when it is made; typing changes no SwiftUI state; Return/Escape only with nothing marked.
assert f.count('stringValue =')==0 and f.count('TitleRenameTextField(string: session.startText)')==1
update=f[f.index('    func updateNSView('):f.index('    static func dismantleNSView(')]
assert 'context.coordinator.parent = self' in update and 'field.' not in update,'nothing about the field changes on a refresh'
assert 'guard !session.isEnded, !textView.hasMarkedText() else { return false }' in f
assert 'session.text = textView.string' in f and 'DispatchQueue.main.async { onEnd(session, .left) }' in f
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'productionRulesFieldAndSplitViews':True,'ownedNeverShownWindows':True,'imeCompositionSimulatedThroughNSTextInputClient':True,'installedAppHerdrOrNetwork':False,'realGUIKeyboardOrFullScreen':'NOTRUN'},indent=2))
print('PASS',len(checks),'stages and source checks')
