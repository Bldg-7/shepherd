#!/usr/bin/env python3
"""Bounded, owned-file-only preview checks; never uses user files/credentials."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform,difflib
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--swiftterm-products',type=Path);p.add_argument('--prepare-restore-completion',action='store_true');p.add_argument('--static-contracts-only',action='store_true');args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','files']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))

# The never-shown panel fixture needs to distinguish transient initial point
# placement from completion of PreviewScrollPlace's private anchor restoration.
# Generate observer-bearing copies rather than expanding the production API.
DERIVED_HASHES={
 'Shepherd/FilePreview/FilePreviewPanel.swift':'fdbb7e360d0741973f7095f043e00bfece7addd450d227d7bf4ade59b60234e3',
 'Shepherd/FilePreview/SourceFilePreview.swift':'9d07eec8d9b1dd8cbbdc5d6a20b1a7c8cb3bccaa5b64f52ea8f692e64637d9f6',
 'Tests/FilePreview/PanelWindowTests.swift':'5ea00c7483a2bdb8d2a159f9dd2d9bb457caded3fd9ccc2b0539ea2b46b1103a'
}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def once(text,old,new,label):
 assert text.count(old)==1,label
 return text.replace(old,new,1)
def replace_op(text,op,inverse=False):
 old,new,label,*scope=op
 if inverse:old,new=new,old
 if not scope:return once(text,old,new,('inverse ' if inverse else '')+label)
 marker=scope[0];at=text.index(marker);return text[:at]+once(text[at:],old,new,('inverse ' if inverse else '')+label)
def inverse_ops(result,ops):
 inverse=result
 for op in reversed(ops):inverse=replace_op(inverse,op,True)
 return inverse
def derived(path,ops,markers,folder):
 original=(ROOT/path).read_text();assert hashlib.sha256(original.encode()).hexdigest()==DERIVED_HASHES[path],path
 result=original
 for op in ops:result=replace_op(result,op)
 for marker in markers:assert marker in result,marker
 inverse=inverse_ops(result,ops)
 assert inverse==original,'inverse '+path
 # Meaningful negative guard: mutate generated content, then run the same
 # inverse/cardinality sequence. The unique sentinel must survive inversion.
 sentinel='\n// restore-completion inverse guard sentinel: '+path+'\n'
 mutated_inverse=inverse_ops(result+sentinel,ops)
 assert mutated_inverse!=original,'negative inverse '+path
 target=folder/Path(path).name;target.write_text(result)
 return target,{'source':path,'sourceSha256':DERIVED_HASHES[path],'generated':str(target),'generatedSha256':sha(target),'markers':markers,'diffSha256':hashlib.sha256(''.join(difflib.unified_diff(original.splitlines(True),result.splitlines(True),fromfile=path,tofile=str(target))).encode()).hexdigest(),'negativeInverseRejected':True}
def prepare_restore_completion():
 folder=out/'restore-completion-derived';folder.mkdir(mode=0o700)
 panel_ops=[
 ('''    var onFileLink: (FilePreviewRequest) -> Void
    var isExpanded = false''','''    var onFileLink: (FilePreviewRequest) -> Void
    /// Derived-test-only callback; production source is generated unchanged.
    var onRestoreFinished: (() -> Void)? = nil
    var isExpanded = false''','panel callback'),
 ('''                                                         navigationID: model.scrollRequest?.id,
                                                         onScroll: keepScrollOffset, onAnchor: { model.scrollAnchor = $0 }))''','''                                                         navigationID: model.scrollRequest?.id,
                                                         onScroll: keepScrollOffset, onAnchor: { model.scrollAnchor = $0 },
                                                         onRestoreFinished: onRestoreFinished))''','markdown callback'),
 ('''                                              onScroll: keepScrollOffset,
                                              onVisibleLines: { model.visibleLines = $0 }, marks: marks)''','''                                              onScroll: keepScrollOffset,
                                              onVisibleLines: { model.visibleLines = $0 }, onRestoreFinished: onRestoreFinished,
                                              marks: marks)''','source callback')]
 source_ops=[
 ('''    var onVisibleLines: (([Int]) -> Void)? = nil
    /// The find bar's matches, by line number.''','''    var onVisibleLines: (([Int]) -> Void)? = nil
    /// Derived-test-only callback; generated source only.
    var onRestoreFinished: (() -> Void)? = nil
    /// The find bar's matches, by line number.''','source property'),
 ('''                                         onScroll: onScroll, onAnchor: onAnchor))''','''                                         onScroll: onScroll, onAnchor: onAnchor,
                                         onRestoreFinished: onRestoreFinished))''','source forwarding'),
 ('''struct PreviewScrollPlace: ViewModifier {
    let onScroll: ((CGPoint) -> Void)?''','''struct PreviewScrollPlace: ViewModifier {
    let onScroll: ((CGPoint) -> Void)?
    private var onRestoreFinished: (() -> Void)?''','modifier property'),
 ('''    init(restoring offset: CGPoint?, onScroll: ((CGPoint) -> Void)?) {
        self.onScroll = onScroll''','''    init(restoring offset: CGPoint?, onScroll: ((CGPoint) -> Void)?,
         onRestoreFinished: (() -> Void)? = nil) {
        self.onScroll = onScroll
        self.onRestoreFinished = onRestoreFinished''','point init'),
 ('''                       onScroll: ((CGPoint) -> Void)?, onAnchor: ((PreviewScrollAnchor) -> Void)?) {
        let kept = anchor.flatMap''','''                       onScroll: ((CGPoint) -> Void)?, onAnchor: ((PreviewScrollAnchor) -> Void)?,
                       onRestoreFinished: (() -> Void)? = nil) {
        let kept = anchor.flatMap''','generic init signature'),
 ('''        self.onScroll = onScroll
        self.rows = rows''','''        self.onScroll = onScroll
        self.onRestoreFinished = onRestoreFinished
        self.rows = rows''','generic init assignment'),
 ('''        if wasRestoring, let top = rows?.viewTop {
            onScroll?(CGPoint(x: 0, y: top))
        }
    }''','''        if wasRestoring, let top = rows?.viewTop {
            onScroll?(CGPoint(x: 0, y: top))
        }
        if wasRestoring { onRestoreFinished?() }
    }''','finish callback')]
 token='''
@MainActor final class RestoreCompletionToken {
    private(set) var generation = UUID()
    private(set) var panelID: UUID?
    private(set) var count = 0
    func begin(panelID: UUID) -> UUID { generation = UUID(); self.panelID = panelID; count = 0; return generation }
    func receive(panelID: UUID, generation: UUID) { guard self.panelID == panelID, self.generation == generation else { return }; count += 1 }
}
'''
 test_ops=[
 ('''final class CloseCount { var count = 0 }
''','''final class CloseCount { var count = 0 }
'''+token,'completion token'),
 ('''    var expanded = false
    var body: some View {
        if let entry {
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store, onClose: { closes.count += 1 }, onFileLink: { _ in })''','''    var expanded = false
    var onRestoreFinished: (() -> Void)? = nil
    var body: some View {
        if let entry {
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store, onClose: { closes.count += 1 }, onFileLink: { _ in }, onRestoreFinished: onRestoreFinished)''','root forwarding'),
 ('''        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = FindRoot(entry: states.entry(for: item, panes: [pane]), store: store, closes: closes, expanded: expanded)
        }''','''        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false, onRestoreFinished: (() -> Void)? = nil) {
            host.rootView = FindRoot(entry: states.entry(for: item, panes: [pane]), store: store, closes: closes, expanded: expanded, onRestoreFinished: onRestoreFinished)
        }''','reload select callback','    static func reload('),
 ('''        let rItem = TerminalIdentity(connection: local.connectionIdentity, itemID: r.id)
        let sItem = TerminalIdentity(connection: local.connectionIdentity, itemID: s.id)''','''        let rItem = TerminalIdentity(connection: local.connectionIdentity, itemID: r.id)
        let sItem = TerminalIdentity(connection: local.connectionIdentity, itemID: s.id)
        let restoreCompletion = RestoreCompletionToken()''','token owner','    static func reload('),
 ('''        check(abs(place().y - 900) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 900) < 2, "at the place it was scrolled to")
        check(!rModel.showsSource && rModel.link?.line == nil && isEnabled(reloadButton()), "still rendered, Reload enabled again")''','''        check(abs(place().y - 900) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 900) < 2, "at the place it was scrolled to")
        guard let savedRestoreAnchor = rModel.scrollAnchor else { preconditionFailure("saved semantic anchor after first reload") }
        check(!rModel.showsSource && rModel.link?.line == nil && isEnabled(reloadButton()), "still rendered, Reload enabled again")''','save semantic anchor'),
 ('''        select(rItem, r)
        check(await settleAsync(host.view) { abs(place().y - 900) < 2 } && text(rModel) == plan(1), "R comes back at 900, not read again")
        drain(host.view)
        scroll(documentScroll(in: host.view)!, to: 1500)''','''        let restoreGeneration = restoreCompletion.begin(panelID: rModel.id)
        select(rItem, r, onRestoreFinished: { restoreCompletion.receive(panelID: rModel.id, generation: restoreGeneration) })
        check(await settleAsync(host.view) { abs(place().y - 900) < 2 } && text(rModel) == plan(1), "R initially reaches its retained point; restoration completion is observed separately")
        check(await settleAsync(host.view) { restoreCompletion.count == 1 }, "R semantic restoration finishes once")
        guard let completedAnchor = rModel.scrollAnchor else { preconditionFailure("completed semantic anchor") }
        let scaledOffset = savedRestoreAnchor.offset <= 0 || savedRestoreAnchor.height <= 0 || abs(completedAnchor.height - savedRestoreAnchor.height) < 0.5 ? savedRestoreAnchor.offset : savedRestoreAnchor.offset / savedRestoreAnchor.height * completedAnchor.height
        check(completedAnchor.inSource == savedRestoreAnchor.inSource && completedAnchor.row == savedRestoreAnchor.row && abs(completedAnchor.offset - scaledOffset) <= 0.5, "completed restoration keeps R's semantic anchor")
        drain(host.view)
        scroll(documentScroll(in: host.view)!, to: 1500)''','completion gate')]
 panel,pc=derived('Shepherd/FilePreview/FilePreviewPanel.swift',panel_ops,['onRestoreFinished: onRestoreFinished'],folder)
 source,sc=derived('Shepherd/FilePreview/SourceFilePreview.swift',source_ops,['if wasRestoring { onRestoreFinished?() }'],folder)
 test,tc=derived('Tests/FilePreview/PanelWindowTests.swift',test_ops,['RestoreCompletionToken','R semantic restoration finishes once'],folder)
 contract={'kind':'restore-completion-derived','sources':[pc,sc,tc],'inverseByteEquality':True,'negativeInverseMutationRejected':True,'observer':'per-panel optional closure at finishRestoring only after state/rows/anchor/onScroll'}
 (folder/'contract.json').write_text(json.dumps(contract,indent=2))
 return panel,source,test,folder
panel_derived,source_derived,test_derived,derived_folder=prepare_restore_completion()
if args.prepare_restore_completion:
 print(json.dumps(json.loads((derived_folder/'contract.json').read_text()),indent=2));sys.exit(0)
def source_path(n):return Path(n) if Path(n).is_absolute() else ROOT/n
if not args.static_contracts_only:
 sources=['ShepherdKit/Sources/ShepherdKit/Rendering/PreviewMarkdownBlock.swift','ShepherdKit/Sources/ShepherdKit/Rendering/PreviewSyntaxLanguage.swift']+['Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/FilePreview/FilePreviewReader.swift','Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','Tests/FilePreview/FilePreviewTests.swift']
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
 productionPanel=['ShepherdKit/Sources/ShepherdKit/Rendering/PreviewMarkdownBlock.swift','ShepherdKit/Sources/ShepherdKit/Rendering/PreviewSyntaxLanguage.swift']+paneStates+['Shepherd/FilePreview/FilePreviewPanel.swift','Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewOutline.swift','Shepherd/FilePreview/PreviewOutlineHover.swift','Shepherd/FilePreview/SourceFilePreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewFindBar.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift']
 derivedCompletionPanel=['ShepherdKit/Sources/ShepherdKit/Rendering/PreviewMarkdownBlock.swift','ShepherdKit/Sources/ShepherdKit/Rendering/PreviewSyntaxLanguage.swift']+paneStates+[str(panel_derived),'Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewOutline.swift','Shepherd/FilePreview/PreviewOutlineHover.swift',str(source_derived),'Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewFindBar.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift']
 (out/'production-panel-source-hashes.json').write_text(json.dumps({n:hashlib.sha256(source_path(n).read_bytes()).hexdigest() for n in productionPanel},indent=2))
 (out/'panel-files').mkdir(mode=0o700)
 # This explicit derived stage is the completion-gate infrastructure test. It
 # is not an ordinary production-panel/full-pass receipt.
 stage('derived-restore-completion-panel-build',120,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*derivedCompletionPanel,str(test_derived),'-framework','AppKit','-o',str(out/'derived-restore-completion-panel-tests')])
 stage('derived-restore-completion-panel-tests',60,[str(out/'derived-restore-completion-panel-tests'),str(out/'panel-files')],mirrorsLog=True)
 assert 'Modifying state during view update' not in (out/'derived-restore-completion-panel-tests.log').read_text()
 (out/'derived-restore-completion-source-hashes.json').write_text(json.dumps({n:hashlib.sha256(source_path(n).read_bytes()).hexdigest() for n in derivedCompletionPanel+[str(test_derived)]},indent=2))
 # Row anchors: mixed-height blocks, wrapped source, Retry, width changes
 # while away, missing rows and explicit navigation during restoration. This
 # normal stage compiles the tracked product panel/source, never derived copies.
 (out/'restore-files').mkdir(mode=0o700)
 stage('scroll-restore-build',120,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*productionPanel,'Tests/FilePreview/ScrollRestoreTests.swift','-framework','AppKit','-o',str(out/'scroll-restore-tests')])
 stage('scroll-restore-tests',90,[str(out/'scroll-restore-tests'),str(out/'restore-files')],mirrorsLog=True)
 assert 'Modifying state during view update' not in (out/'scroll-restore-tests.log').read_text()
 (out/'restore-source-hashes.json').write_text(json.dumps({n:hashlib.sha256(source_path(n).read_bytes()).hexdigest() for n in productionPanel+['Tests/FilePreview/ScrollRestoreTests.swift']},indent=2))
 # Find: what it looks in and matches, where it goes next, its marks and the
 # preview's keys, without a window.
 find=['ShepherdKit/Sources/ShepherdKit/Rendering/PreviewMarkdownBlock.swift','ShepherdKit/Sources/ShepherdKit/Rendering/PreviewSyntaxLanguage.swift']+['Shepherd/FilePreview/MarkdownPreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/PreviewFind.swift','Shepherd/FilePreview/PreviewKeyCatcher.swift','Shepherd/FilePreview/PreviewFindBar.swift','Tests/FilePreview/FindTests.swift']
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
# The Markdown table of contents: its strings in Korean and Japanese; an
# accessible viewport trigger reveals it, while hover state stays view-local;
# a heading chosen in it goes through the preview's own scroll request.
strings=json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings']
for key in ['Table of Contents','Show Table of Contents','Hide Table of Contents','No Headings']:
 assert all(strings[key]['localizations'][l]['stringUnit']['state']=='translated' and strings[key]['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']),key
for name in sorted((ROOT/'Shepherd/FilePreview').glob('*.swift')):
 source=name.read_text();assert not any(word in source for word in ['UserDefaults','@AppStorage','@SceneStorage']),name.name
fp=(ROOT/'Shepherd/FilePreview/FilePreviewPanel.swift').read_text()
assert 'model.reveal(inSource ? .line(heading.line) : .block(heading.id))' in fp and 'systemImage: "list.bullet.indent"' in fp
assert 'preview.outline.trigger' in fp and 'PreviewOutlineHover.isPresented' in fp and 'preview.outline.toggle' not in fp
# The 32-point trigger declaration and the larger panel/bridge hover region
# are intentionally separate source scopes. This contract is not an AX-frame
# or pixel measurement; the accepted scratch geometry observation records the
# runtime 32×32 post-modifier control layout for this exact composition.
overlay=fp[fp.index('private struct PreviewOutlineOverlay'):]
trigger=overlay[overlay.index('Button(action: {})'):overlay.index('            // This is deliberately intrinsically tall:')]
style=trigger.index('.buttonStyle(.borderless)')
frame=trigger.index('.frame(width: triggerSize, height: triggerSize)',style)
shape=trigger.index('.contentShape(Rectangle())',frame)
identifier=trigger.index('.accessibilityIdentifier("preview.outline.trigger")',shape)
action=trigger.index('.accessibilityAction {',identifier)
assert style<frame<shape<identifier<action,'the trigger control keeps style, outer frame, shape, identifier and action in order'
region=overlay[overlay.index('            // This is deliberately intrinsically tall:'):]
assert '.contentShape(Rectangle())\n            .accessibilityElement(children: .contain)\n            .accessibilityIdentifier("preview.outline.region")\n            .onHover' in region,'the panel/bridge hover region stays separate from the trigger control'
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
assert 'PreviewKeyCatcher(keyboard: keyboard, perform: perform' in fp and '.focusable()' in fp
exit_handler=fp[fp.index('.onExitCommand {'):fp.index('        #endif',fp.index('.onExitCommand {'))]
def ordered(fragment,parts):
 positions=[fragment.index(part) for part in parts]
 assert positions==sorted(positions),parts
ordered(exit_handler,['if outlineFocused || outlineExplicitlyRevealed {','outlineFocused = false','outlineExplicitlyRevealed = false','keyboard.focusPreview()','} else if model.find.isShown {','closeFind()','} else if isExpanded {','onToggleExpanded?()','} else {','onClose()'])
assert exit_handler.count('closeFind()')==1 and exit_handler.count('onToggleExpanded?()')==1 and exit_handler.count('onClose()')==1
if args.static_contracts_only:
 (out/'static-contracts.json').write_text(json.dumps({'passed':True,'mode':'post-runtime-static-contracts-only','productionPanelHash':sha(ROOT/'Shepherd/FilePreview/FilePreviewPanel.swift'),'derivedContract':json.loads((derived_folder/'contract.json').read_text())},indent=2))
else:
 (out/'validation.json').write_text(json.dumps({'passed':True,'userFilesRead':False,'realKeychainAccess':False,'networkAccess':False,'actualSwiftTerm':bool(args.swiftterm_products),'stages':19 if args.swiftterm_products else 17},indent=2))
