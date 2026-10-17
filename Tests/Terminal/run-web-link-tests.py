#!/usr/bin/env python3
from pathlib import Path
import os,json,hashlib,subprocess,sys,argparse,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(parents=True,mode=0o700,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalWebLinkRequest.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/LinkDestinationPolicy.swift','Shepherd/Hosts/Models/Machine.swift','Shepherd/HerdrKit/Models/AgentModels.swift','Shepherd/HerdrKit/Models/AgentTitleDisplay.swift','Shepherd/HerdrKit/Models/AgentLaunchModels.swift','Shepherd/HerdrKit/Models/HerdrMachine.swift','Shepherd/HerdrKit/Models/JSONValue.swift','Tests/Terminal/WebLinkTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,timeout,args):
 log=out/(name+'.log');subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*args],env=env,cwd=ROOT,check=True,timeout=timeout+40)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified']
stage('web-link-build',90,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'web-link-tests')])
stage('web-link-tests',30,[str(out/'web-link-tests')])
content=(ROOT/'Shepherd/ContentView.swift').read_text();route=content[content.index('    private func openWeb('):content.index('    private func previewPanel(')]
assert 'isCurrentConnection' in route and 'selected.connection' in route and 'request.pane(in:' in route
assert 'BrowserKey(machine: machine, pane: pane)' in route and 'terminalID: pane.terminalID, url: url' in route
assert 'activatedPanes[identity] = pane.paneID' in route and 'showsFilePreview = false' in route and 'showsBrowser = true' in route
# Every link is validated the same way first, and only then sent where the
# policy says; the default browser gets a validated URL and nothing else.
assert route.index('TerminalWebLink.validatedURL(request.rawURL)')<route.index('LinkDestinationPolicy.destination(')
assert route.count('NSWorkspace.shared.open(')==1 and 'guard let target = URL(string: url) else { webLinkFailure = .invalidURL; return }\n        NSWorkspace.shared.open(target)' in route
assert '.setEnabled' not in route and '.register' not in route
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'actualProductionPolicyAndScopeModels':True,'linkDestinationPolicy':True,'contentWiringStaticAudit':True,'actualCEFNavigation':'NOTRUN','realSSH':'NOTRUN','installedGUI':'NOTRUN'},indent=2))
