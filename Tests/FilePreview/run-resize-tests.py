#!/usr/bin/env python3
"""Real SwiftUI resize regression on an owned, never-shown NSWindow."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--legacy-panel',type=Path);args=p.parse_args();out=args.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/FilePreview/SourceFilePreview.swift','Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Tests/FilePreview/SourceResizeTests.swift']
syntax=['Shepherd/FilePreview/PreviewSyntaxHighlighter.swift','Shepherd/FilePreview/PreviewSyntaxRendering.swift','Shepherd/FilePreview/MarkdownPreview.swift','Tests/FilePreview/SyntaxHighlightTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+syntax},indent=2))
def stage(name,seconds,args,expect_layout_failure=False):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert not v['signalsSent'] and v['cleanupVerified'],name
 if expect_layout_failure:
  assert code!=0 and 'source must' in log.read_text(), 'legacy renderer did not reproduce the layout failure'
 else:assert code==0 and v['naturalExitConfirmed'],name
stage('syntax-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*syntax,'-o',str(out/'syntax-tests')])
stage('syntax-tests',30,[str(out/'syntax-tests')])
compiled=list(sources)
if args.legacy_panel:
 import textwrap
 old=args.legacy_panel.read_text()
 start=old.index('                    ScrollViewReader { proxy in')
 end=old.index('\n                }\n            }\n        case .image',start)
 body=textwrap.dedent(old[start:end]).replace('rendered','text').replace('model.link?.line','selectedLine')
 legacy=out/'LegacySource.swift';legacy.write_text('import SwiftUI\nstruct SourceFilePreview: View { let text: String; var selectedLine: Int?; var language: PreviewSyntaxLanguage = .plain; var body: some View {\n'+body+'\n} }\n')
 compiled[0]=str(legacy)
 (out/'legacy-panel-sha256').write_text(hashlib.sha256(args.legacy_panel.read_bytes()).hexdigest())
stage('resize-build',90,['xcrun','swiftc','-target',platform.machine()+'-apple-macos26.6.2','-swift-version','6','-default-isolation','MainActor','-parse-as-library',*compiled,'-o',str(out/'resize-tests')])
stage('resize-tests',30,[str(out/'resize-tests'),str(out/'layout.json')],expect_layout_failure=bool(args.legacy_panel))
(out/'validation.json').write_text(json.dumps({'passed':not bool(args.legacy_panel),'expectedLegacyFailureConfirmed':bool(args.legacy_panel),'ownedUnshownWindow':True,'userGUIInput':False,'networkAccess':False,'stages':4},indent=2))
