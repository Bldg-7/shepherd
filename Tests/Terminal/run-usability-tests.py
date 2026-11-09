#!/usr/bin/env python3
"""Private-HOME, bounded parsing/navigation/native modal checks; no app/session operations."""
from pathlib import Path
import argparse,json,os,hashlib,subprocess,sys,platform,shutil
sys.dont_write_bytecode=True
from native_test_env import settings
R=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path,required=True);a=p.parse_args();o=a.output.resolve();o.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(o/n).mkdir(mode=0o700)
env,sdk_flags=settings(o)
tracked=[*sorted((R/'Shepherd').rglob('*.swift')),*sorted((R/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift')),
         *sorted((R/'Tests/Terminal').glob('*.swift')),R/'Shepherd/Localizable.xcstrings',Path(__file__).resolve(),R/'Tests/Terminal/native_test_env.py']
def snapshot():return {str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
before=snapshot();(o/'all-source-hashes.json').write_text(json.dumps(before,indent=2))
products=a.swiftterm_products.resolve();shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle',o/'SwiftTerm_SwiftTerm.bundle')
checks=[]
def stage(name,timeout,command,mirrorsLog=False):
 log=o/(name+'.log');subprocess.run([sys.executable,str(R/'Tests/Support/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=R,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=timeout+40,check=True)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and j['cleanupVerified'] and not j['signalsSent'];checks.append(name)
flags=['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library']+sdk_flags
markdown=['ShepherdKit/Sources/ShepherdKit/Rendering/PreviewMarkdownBlock.swift','ShepherdKit/Sources/ShepherdKit/Rendering/PreviewSyntaxLanguage.swift']+['Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewOutline.swift','Shepherd/FilePreview/PreviewOutlineHover.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Tests/FilePreview/MarkdownParsingTests.swift']
stage('markdown-build',90,flags+markdown+['-o',str(o/'markdown-tests')]);stage('markdown-tests',20,[str(o/'markdown-tests')])
# The real BoardItem declaration, not a replacement enum.
board='Shepherd/Hosts/Views/BoardItem.swift'
models=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/TabModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift']
nav=['Shepherd/Hosts/Views/PaneSwitcher.swift','Tests/Terminal/PaneSwitcherTests.swift']
stage('navigation-build',90,flags+nav+['-o',str(o/'navigation-tests')]);stage('navigation-tests',20,[str(o/'navigation-tests')])
# Likewise the launcher's real targets and preset rule, without its view.
text=(R/'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text();start=text.index('struct LaunchTarget:');end=text.index('nonisolated enum LaunchProgram',start);launch=o/'LaunchModels.swift';launch.write_text('import SwiftUI\n'+text[start:end])
preset=models+['Tests/Terminal/LaunchPresetTests.swift']
stage('launch-preset-build',90,flags+preset+[board,str(launch),'-o',str(o/'launch-preset-tests')]);stage('launch-preset-tests',20,[str(o/'launch-preset-tests')])
# And what one Return on the tab name does with the launcher: the real LaunchAttempt, with the error it tells apart.
text=(R/'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text();start=text.index('nonisolated struct CreatedPaneLaunchError');end=text.index('/// What the launcher asks for once every step is done.',start);attempt=o/'LaunchAttempt.swift';attempt.write_text('import Foundation\n'+text[start:end])
assert 'final class LaunchAttempt' in attempt.read_text()
stage('launch-attempt-build',90,flags+[str(attempt),'Tests/Terminal/LaunchAttemptTests.swift','-o',str(o/'launch-attempt-tests')]);stage('launch-attempt-tests',20,[str(o/'launch-attempt-tests')])
modal=['Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift','Shepherd/Terminal/TerminalPaneFrame.swift','Shepherd/Terminal/SelectionKeepingTerminal.swift','Shepherd/Terminal/TerminalHostView.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/FilePreview/FilePreviewLink.swift','Tests/Terminal/PreviewModalLayoutTests.swift']
stage('modal-build',90,flags+['-I',str(products)]+modal+[str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(o/'modal-tests')]);stage('modal-tests',25,[str(o/'modal-tests')])
(o/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in set(markdown+nav+preset+modal+[board,'Shepherd/HcBackend/HcRootView.swift','Shepherd/HcBackend/HcWindowCommands.swift','Shepherd/Shepherd.swift','Shepherd/Hosts/Views/MachinesSettingsView.swift','Shepherd/Hosts/Views/NewTabLauncher.swift','Shepherd/FilePreview/FilePreviewPanel.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewFindBar.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift','Shepherd/FilePreview/FilePreviewPaneStates.swift','Tests/Terminal/LauncherFieldTests.swift','Tests/Terminal/LaunchAttemptTests.swift','Tests/Terminal/LauncherTabKeyTests.swift','Shepherd/Hosts/Views/LauncherMachineStep.swift'])},indent=2))
# And the launcher's real field, driven as the Korean input method drives it. SwiftUI's faults go to the log, which must not say state was changed during a view update.
text=(R/'Shepherd/Hosts/Views/NewTabLauncher.swift').read_text();start=text.index("/// The launcher's text field");end=text.index('#endif',start);launcherField=o/'LauncherField.swift';launcherField.write_text('import SwiftUI\nimport AppKit\n'+text[start:end].replace('private struct LauncherField','struct LauncherField',1))
stage('launcher-field-build',90,flags+[str(launcherField),'Tests/Terminal/LauncherFieldTests.swift','-framework','AppKit','-o',str(o/'launcher-field-tests')]);stage('launcher-field-tests',20,[str(o/'launcher-field-tests')],mirrorsLog=True)
assert 'Modifying state during view update' not in (o/'launcher-field-tests.log').read_text()
# And the whole launcher, Tab and ⇧Tab pressed on it: on the tab's name they go round the Launch picker, the field keeping the keyboard and what is typed in it; on the other steps they are AppKit's.
kit='ShepherdKit/Sources/ShepherdKit/';tabkeys=models+[kit+'Agents/AgentKind.swift',kit+'HerdrKit/Transport/ConnectionFailureDescription.swift','Shepherd/Hosts/Views/LauncherMachineStep.swift','Shepherd/Hosts/Views/NewTabLauncher.swift','Tests/Terminal/LauncherTabKeyTests.swift']
stage('launcher-tab-build',120,flags+tabkeys+[board,'-framework','AppKit','-o',str(o/'launcher-tab-tests')]);stage('launcher-tab-tests',30,[str(o/'launcher-tab-tests')],mirrorsLog=True)
assert 'Modifying state during view update' not in (o/'launcher-tab-tests.log').read_text()
app=(R/'Shepherd/Shepherd.swift').read_text();m=(R/'Shepherd/Hosts/Views/MachinesSettingsView.swift').read_text();root=(R/'Shepherd/HcBackend/HcRootView.swift').read_text()
commands=(R/'Shepherd/HcBackend/HcWindowCommands.swift').read_text()
assert 'HcPaneSwitcherMenuItem(actions: hcCommands.actions)' in app
assert '.keyboardShortcut("p", modifiers: .command)' in commands
assert 'Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main")' in app and 'WindowGroup {' not in app and 'applicationShouldTerminateAfterLastWindowClosed' in app
assert 'CommandGroup(replacing: .newItem)' in app and 'HcNewTabMenuItems(actions: hcCommands.actions)' in app
assert commands.index('perform(.launch)')<commands.index('.keyboardShortcut("n")')<commands.index('perform(.launchCurrentWorkspace)')<commands.index('.keyboardShortcut("t")')
assert m.count('.disabled(machine.isLocal || hoveredMachineID != machine.id)')==2 and '.onHover' in m
assert m.index('Label("Active", systemImage: "checkmark.circle.fill")')>m.index('Image(systemName: "trash")')
fp=(R/'Shepherd/FilePreview/FilePreviewPanel.swift').read_text()
assert '@State private var model' not in fp and 'await model.loadIfNeeded(request, store: machineStore)' in fp and 'showsSource = false' not in fp
s=json.loads((R/'Shepherd/Localizable.xcstrings').read_text())['strings']
assert 'CommandGroup(replacing: .saveItem)' in app and 'CloseCommands()' in app and commands.count('.keyboardShortcut("w")')==1
assert 'HcCloseMenuItems(actions: hcCommands.actions)' in app
assert commands.index('Button("Close Window")')<commands.index('performClose')<commands.index('actions?.closeTitle ?? "Close Pane"')<commands.index('.keyboardShortcut("w")')
assert all(s['Close Window']['localizations'][l]['stringUnit']['state']=='translated' for l in ['ko','ja'])
# The pane switcher and Settings close for a quit, an update's Install and Relaunch included, instead of stopping it with a beep.
for k,e in [('.sheet(isPresented: $switcher','.sheet(isPresented: $settings)'),('.sheet(isPresented: $settings)','.sheet(isPresented: $installation)')]:i=root.index(k);assert '.presentationPreventsAppTermination(false)' in root[i:root.index(e,i)],k
assert before==snapshot(),'source changed during original UI qualification'
(o/'validation.json').write_text(json.dumps({'passed':True,'stages':checks,'snapshotsOnlyNavigation':True,'actualSwiftTermOwnedKernelPTY':True,'singleModalPanelTerminalIdentityPreserved':True,'installedAppOrSSHOrNetwork':False,'realGUIKeyboardHover':'NOTRUN'},indent=2))
