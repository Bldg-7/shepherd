#!/usr/bin/env python3
from pathlib import Path
import os,json,hashlib,subprocess,sys,argparse,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(parents=True,mode=0o700,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalWebLinkRequest.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/LinkDestinationPolicy.swift','ShepherdKit/Sources/ShepherdKit/Machines/Machine.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentTitleDisplay.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrMachine.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/JSONValue.swift','Tests/Terminal/WebLinkTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,timeout,args):
 log=out/(name+'.log');subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*args],env=env,cwd=ROOT,check=True,timeout=timeout+40)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified']
stage('web-link-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'web-link-tests')])
stage('web-link-tests',30,[str(out/'web-link-tests')])
content=(ROOT/'Shepherd/ContentView.swift').read_text();route=content[content.index('    private func openWeb('):content.index('    private func previewPanel(')]
assert 'isCurrentConnection' in route and 'selected.connection' in route and 'request.pane(in:' in route
assert 'BrowserKey(machine: machine, pane: pane)' in route and 'terminalID: pane.terminalID, url: url' in route
assert 'activatedPanes[identity] = pane.paneID' in route and 'showsBrowser = true' in route
# A preview in the browser column's place makes way for the link's page, in
# that pane or tab only; its file is kept for the toolbar.
assert 'filePreviews.hide(identity)' in route and 'expandedPreview = nil' in route and 'showsFilePreview' not in route
# Every link is validated the same way first, and only then sent where the
# policy says; the default browser gets a validated URL and nothing else.
assert route.index('TerminalWebLink.validatedURL(request.rawURL)')<route.index('LinkDestinationPolicy.destination(')
assert route.count('NSWorkspace.shared.open(')==1 and 'guard let target = URL(string: url) else { webLinkFailure = .invalidURL; return }\n        NSWorkspace.shared.open(target)' in route
assert '.setEnabled' not in route and '.register' not in route
# A click goes to In-app Browser and ⌘-click to the default browser, with
# nothing to set and nothing asked: no prompt, no setting, no notice for a
# browser that is off.
assert 'LinkDestinationPolicy.destination(commandHeld: commandHeld, browserEnabled: browserEnabled, engineAvailable: engineAvailable)' in route
assert 'LinkDestinationPolicy.saysBrowserUnavailable(' in route and 'guard browserUnavailable else { return }' in route
assert '"In-app Browser isn\'t available on this Mac, so the link opened in the default browser."' in route and 'is off, so the link' not in content
for gone in ['linkChoice','LinkChoice','LinkDestinationPrompt','@AppStorage(LinkDestinationPolicy','resolveLinkChoice','terminalColumnFrame','.popover(item: $link']:
 assert gone not in content,gone
assert 'webLinkFailure != nil\n                || herdrMachineSetup != nil' in content
settings=(ROOT/'Shepherd/Hosts/Views/ExperimentalFeaturesSettingsView.swift').read_text()
assert 'Picker' not in settings and 'LinkDestinationPolicy' not in settings and 'link-destination' not in settings
assert 'explanation: "An in-app pane browser. Links clicked in a terminal open in In-app Browser; ⌘-click opens them in the default browser. ' in settings
assert not (ROOT/'Shepherd/Terminal/LinkDestinationPrompt.swift').exists()
assert 'struct LinkDestinationPrompt' not in (ROOT/'Shepherd/Terminal/LinkOpenedNotice.swift').read_text()
assert not any('"links.destination"' in f.read_text() for f in (ROOT/'Shepherd').rglob('*.swift')),'the old setting is not read'
host=(ROOT/'Shepherd/Terminal/TerminalHostView.swift').read_text()
assert 'at: point, clickCount: event.clickCount)' in host and 'windowPoint' not in host and 'topLeftWindowPoint' not in host
strings=json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings']
for gone in ['Open links in','Ask first','Default Browser','About opening links','Open in In-app Browser',"Don't ask again",'⌘-click opens a link in the other browser.','In-app Browser is off, so the link opened in the default browser.']:
 assert gone not in strings,gone
assert not any(k.startswith('Where http and https links clicked') for k in strings)
for kept in ['Open in Default Browser','Could Not Open Link',"In-app Browser isn't available on this Mac, so the link opened in the default browser.",'In-app Browser']:
 assert all(strings[kept]['localizations'][l]['stringUnit']['state']=='translated' for l in ['ko','ja']),kept
info=[k for k in strings if k.startswith('An in-app pane browser.') and 'extractionState' not in strings[k]]
assert len(info)==1 and '⌘-click opens them in the default browser.' in info[0]
loc={l:strings[info[0]]['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']}
assert 'In-app Browser에서 열리고, ⌘를 누른 채 클릭하면 기본 브라우저에서 열립니다.' in loc['ko'] and 'In-app Browser で開き、⌘を押しながらクリックするとデフォルトブラウザで開きます。' in loc['ja']
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'actualProductionPolicyAndScopeModels':True,'linkDestinationPolicy':True,'noPromptOrSetting':True,'localizationKeys':True,'contentWiringStaticAudit':True,'actualCEFNavigation':'NOTRUN','realSSH':'NOTRUN','installedGUI':'NOTRUN'},indent=2))
