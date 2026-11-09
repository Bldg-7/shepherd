#!/usr/bin/env python3
from pathlib import Path
import os,json,hashlib,subprocess,sys,argparse,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(parents=True,mode=0o700,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Terminal/TerminalWebLink.swift','Shepherd/Terminal/TerminalPageLink.swift','Shepherd/FilePreview/FilePreviewLink.swift','Shepherd/Terminal/TerminalFileGesture.swift','Shepherd/Terminal/LinkDestinationPolicy.swift','Tests/Terminal/WebLinkTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,timeout,args):
 log=out/(name+'.log');subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout',str(timeout),'--natural-exit-grace','10','--log',str(log),'--',*args],env=env,cwd=ROOT,check=True,timeout=timeout+40)
 j=json.loads(log.with_suffix('.stage.json').read_text());assert j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified']
stage('web-link-build',90,['xcrun','swiftc','ShepherdKit/Sources/ShepherdKit/Resources.swift','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'web-link-tests')])
stage('web-link-tests',30,[str(out/'web-link-tests')])
# Where it is wired in: the terminal pane routes a click with TerminalLinkRoute,
# opening pages only on This Mac; a file goes to the preview, a web link to
# the default browser, and a page to the app that opens https links rather
# than to what opens .html, which can be an editor.
pane=(ROOT/'Shepherd/HcBackend/HcTerminalPane.swift').read_text();opener=pane[pane.index('    private func open(_ link: String) {'):]
assert 'TerminalLinkRoute(link: link, directory: record.cwd, hostname: machine.hostname,' in opener and 'opensPages: machine.isLocal)' in opener
assert 'case .file(let raw):\n            presentation.open(FilePreviewRequest(' in opener
assert 'if case .page = route, let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!) {\n                NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())\n            } else { NSWorkspace.shared.open(url) }' in opener
# The preview still shows HTML as inert source, for every other pane.
assert '// HTML/SVG are displayed as inert source, never loaded into WebKit.' in (ROOT/'Shepherd/FilePreview/FilePreviewLink.swift').read_text()
assert not (ROOT/'Shepherd/Terminal/LinkDestinationPrompt.swift').exists()
assert not any('"links.destination"' in f.read_text() for f in (ROOT/'Shepherd').rglob('*.swift')),'the old setting is not read'
host=(ROOT/'Shepherd/Terminal/TerminalHostView.swift').read_text()
assert 'at: point, clickCount: event.clickCount)' in host and 'windowPoint' not in host and 'topLeftWindowPoint' not in host
strings=json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings']
for gone in ['Open links in','Ask first','Default Browser','About opening links','Open in In-app Browser',"Don't ask again",'⌘-click opens a link in the other browser.','In-app Browser is off, so the link opened in the default browser.']:
 assert gone not in strings,gone
assert not any(k.startswith('Where http and https links clicked') for k in strings)
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'linkDestinationPolicy':True,'htmlPageLinks':True,'linkRoutes':True,'noPromptOrSetting':True,'localizationKeys':True,'hcPaneWiringStaticAudit':True,'realSSH':'NOTRUN','installedGUI':'NOTRUN'},indent=2))
