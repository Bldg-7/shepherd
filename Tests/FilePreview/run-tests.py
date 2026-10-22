#!/usr/bin/env python3
"""Bounded, owned-file-only preview checks; never uses user files/credentials."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','files']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','Tests/FilePreview/FilePreviewTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args,mirrorsLog=False):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=dict(env,OS_ACTIVITY_DT_MODE='1') if mirrorsLog else env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name
stage('preview-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*sources,'-o',str(out/'preview-tests')])
stage('preview-tests',20,[str(out/'preview-tests'),str(out/'files')])
# Compile an explicit in-memory Citadel test module to enable the production
# SFTP routing branch. This module has no network or executeCommand API.
modules=out/'remote-modules';modules.mkdir(mode=0o700)
marker=out/'TestNIO.swift';marker.write_text('public enum OwnedNIOMarker {}\n')
helpers=out/'TestHelpers.swift';helpers.write_text('public final class NIOLockedValueBox<T>: @unchecked Sendable { public init(_ value: T) {} }\n')
for module,file in [('NIOCore',marker),('NIOConcurrencyHelpers',helpers),('Citadel',ROOT/'Tests/FilePreview/OwnedSFTPModule.swift')]:
 stage(module+'-owned-module',60,['xcrun','swiftc','-swift-version','6','-emit-library','-emit-module','-module-name',module,str(file),'-emit-module-path',str(modules/(module+'.swiftmodule')),'-o',str(modules/('lib'+module+'.dylib'))])
remote=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','Tests/FilePreview/RemoteReaderTests.swift']
stage('remote-reader-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(modules),'-L',str(modules),'-lCitadel','-lNIOCore','-lNIOConcurrencyHelpers','-Xlinker','-rpath','-Xlinker',str(modules),*remote,'-o',str(out/'remote-reader-tests')])
stage('remote-reader-tests',20,[str(out/'remote-reader-tests')])
(out/'remote-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in remote+['Tests/FilePreview/OwnedSFTPModule.swift']},indent=2))
model=['Shepherd/FilePreview/PreviewScrollAnchor.swift','Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/FilePreviewModel.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineStore.swift','ShepherdKit/Sources/ShepherdKit/Machines/KeychainStore.swift','Tests/FilePreview/ModelTests.swift']
stage('preview-model-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(modules),'-L',str(modules),'-lCitadel','-lNIOCore','-lNIOConcurrencyHelpers','-Xlinker','-rpath','-Xlinker',str(modules),*model,'-o',str(out/'preview-model-tests')])
stage('preview-model-tests',40,[str(out/'preview-model-tests'),str(out/'files')])
(out/'model-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in model},indent=2))
# The file preview of each pane or tab, kept while another one is selected:
# the actual store, request and model with the actual pane and tab models.
paneModels=['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/TabModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift']
paneStates=['Shepherd/FilePreview/PreviewScrollAnchor.swift','Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/FilePreviewModel.swift','Shepherd/FilePreview/FilePreviewPaneStates.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','ShepherdKit/Sources/ShepherdKit/Machines/MachineStore.swift','ShepherdKit/Sources/ShepherdKit/Machines/KeychainStore.swift']+paneModels
stage('pane-states-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*paneStates,'Tests/FilePreview/PaneStatesTests.swift','-o',str(out/'pane-states-tests')])
stage('pane-states-tests',20,[str(out/'pane-states-tests')])
# And the actual panel in an owned window that is never shown: P, Q and back
# to P, each with its own read, source choice and scroll place. SwiftUI's
# faults go to the log, which must not say state was changed during a view
# update.
panel=paneStates+['Shepherd/FilePreview/FilePreviewPanel.swift','Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewOutline.swift','Shepherd/FilePreview/SourceFilePreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewFindBar.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift']
(out/'panel-files').mkdir(mode=0o700)
stage('panel-window-build',120,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*panel,'Tests/FilePreview/PanelWindowTests.swift','-framework','AppKit','-o',str(out/'panel-window-tests')])
stage('panel-window-tests',60,[str(out/'panel-window-tests'),str(out/'panel-files')],mirrorsLog=True)
assert 'Modifying state during view update' not in (out/'panel-window-tests.log').read_text()
(out/'pane-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in panel+['Tests/FilePreview/PaneStatesTests.swift','Tests/FilePreview/PanelWindowTests.swift']},indent=2))
# Row anchors: mixed-height blocks, wrapped source, Retry, width changes
# while away, missing rows and explicit navigation during restoration.
(out/'restore-files').mkdir(mode=0o700)
stage('scroll-restore-build',120,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*panel,'Tests/FilePreview/ScrollRestoreTests.swift','-framework','AppKit','-o',str(out/'scroll-restore-tests')])
stage('scroll-restore-tests',90,[str(out/'scroll-restore-tests'),str(out/'restore-files')],mirrorsLog=True)
assert 'Modifying state during view update' not in (out/'scroll-restore-tests.log').read_text()
(out/'restore-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in panel+['Tests/FilePreview/ScrollRestoreTests.swift']},indent=2))
# Find: what it looks in and matches, where it goes next, its marks and the
# preview's keys, without a window.
find=['Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift','Shepherd/FilePreview/PreviewFindBar.swift','Tests/FilePreview/FindTests.swift']
stage('find-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*find,'-framework','AppKit','-o',str(out/'find-tests')])
stage('find-tests',30,[str(out/'find-tests')])
(out/'find-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in find},indent=2))
if args.swiftterm_products:
 import shutil
 products=args.swiftterm_products.resolve()
 bundle=products/'SwiftTerm_SwiftTerm.bundle'
 if bundle.exists():shutil.copytree(bundle,out/bundle.name)
 native=['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/TerminalFileHit.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalHostView.swift','Tests/FilePreview/TerminalLinkTests.swift']
 stage('terminal-link-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-I',str(products),*native,str(products/'SwiftTerm.o'),'-framework','AppKit','-framework','QuartzCore','-framework','CoreText','-o',str(out/'terminal-link-tests')])
 stage('terminal-link-tests',20,[str(out/'terminal-link-tests')])
 (out/'native-source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in native},indent=2))
# The Markdown table of contents: its strings in Korean and Japanese; whether
# it is shown kept with each preview in window memory, never in defaults; a
# heading chosen in it goes through the preview's own scroll request.
strings=json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings']
for key in ['Table of Contents','Show Table of Contents','Hide Table of Contents','No Headings']:
 assert all(strings[key]['localizations'][l]['stringUnit']['state']=='translated' and strings[key]['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']),key
for name in sorted((ROOT/'Shepherd/FilePreview').glob('*.swift')):
 source=name.read_text();assert not any(word in source for word in ['UserDefaults','@AppStorage','@SceneStorage']),name.name
fp=(ROOT/'Shepherd/FilePreview/FilePreviewPanel.swift').read_text()
assert 'model.reveal(inSource ? .line(heading.line) : .block(heading.id))' in fp and 'systemImage: "list.bullet.indent"' in fp and '.disabled(!hasHeadings)' in fp
assert '.scrollTargetLayout(' not in ''.join(n.read_text() for n in (ROOT/'Shepherd/FilePreview').glob('*.swift')),'scroll target layouts change how a kept scroll place comes back'
# Find: ⌘F is taken by the preview's own AppKit view only while the preview
# has the keyboard; a SwiftUI shortcut would take it from a terminal beside
# it. Its strings are in Korean and Japanese, and each new read starts it
# over in one place of the model's load.
previewSources=''.join(n.read_text() for n in (ROOT/'Shepherd/FilePreview').glob('*.swift'))
assert '.keyboardShortcut(' not in previewSources,'the preview takes its keys in PreviewKeyCatcher, not with SwiftUI shortcuts'
for key in ['Find','No Results','Find Previous','Find Next','Find Previous (⇧⌘G)','Find Next (⌘G)','Close Find Bar']:
 assert all(strings[key]['localizations'][l]['stringUnit']['state']=='translated' and strings[key]['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']),key
model=(ROOT/'Shepherd/FilePreview/FilePreviewModel.swift').read_text()
def body(name):
 start=model.index('    func '+name+'(');return model[start:model.index('\n    }\n',start)]
load=body('load');reload=body('reload')
assert [l.strip() for l in model.splitlines()].count('find = PreviewFindState()')==1 and load.index('find = PreviewFindState()')<load.index('await read(')
# Reload: the header's button, ⌘R and Retry read the file again keeping the
# find bar, one read at a time; ⌘R is taken in PreviewKeyCatcher like ⌘F.
# Only the close button is Liquid Glass. Its strings are in Korean and
# Japanese.
assert 'find = PreviewFindState()' not in reload and 'await read(' in reload
assert 'scrollAnchor = nil' in load and 'scrollAnchor = nil' not in reload
assert 'model.scrollAnchor = nil' in fp and 'navigationID: model.scrollRequest?.id' in fp
assert 'Button(action: reloadFile)' in fp and 'Button("Retry", action: reloadFile)' in fp and '.disabled(model.isReading)' in fp and 'guard !model.isReading else { return }' in fp
assert fp.count('.buttonStyle(.glass)')==1 and '("r", .command, .reload)' in (ROOT/'Shepherd/FilePreview/PreviewKeyCatcher.swift').read_text()
for key in ['Reload','Reload (⌘R)']:
 assert all(strings[key]['localizations'][l]['stringUnit']['state']=='translated' and strings[key]['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']),key
assert 'PreviewKeyCatcher(keyboard: keyboard, perform: perform' in fp and '.focusable()' in fp and 'if model.find.isShown { closeFind() }' in fp
(out/'validation.json').write_text(json.dumps({'passed':True,'userFilesRead':False,'realKeychainAccess':False,'networkAccess':False,'actualSwiftTerm':bool(args.swiftterm_products),'stages':19 if args.swiftterm_products else 17},indent=2))
