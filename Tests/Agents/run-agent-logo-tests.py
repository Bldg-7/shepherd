#!/usr/bin/env python3
"""The marks the sidebar shows for Claude and Pi in place of their names (SHPHRD-107): which herdr names have one, the path
data against the makers' SVGs by sha256, the parser, the marks drawn by ImageRenderer at 1x, 2x and 3x in light and dark and
in a selected row, in their own colors and inside the room around them, and a pane row as tall with a mark as in words;
then where the board uses them, the search, the iOS app left as it is, and the trademark notice. No window, herdr or app."""
from pathlib import Path
import argparse,os,json,subprocess,sys,hashlib,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
kit='ShepherdKit/Sources/ShepherdKit/'
models=[kit+'Resources.swift',kit+'Agents/AgentKind.swift']+[kit+'HerdrKit/Models/'+n for n in ['JSONValue.swift','AgentModels.swift','AgentLaunchModels.swift','AgentTitleDisplay.swift','HerdrMachine.swift']]
sources=models+['Shepherd/Hosts/Views/AgentLogo.swift','Tests/Agents/AgentLogoTests.swift']
checked=['Shepherd/Hosts/Views/AgentBoardView.swift','ShepherdMobile/BoardView.swift','Shepherd/ThirdPartyNotices.txt','ShepherdMobile/ThirdPartyNotices.txt']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+checked},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 v=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and v['naturalExitConfirmed'] and not v['signalsSent'] and v['cleanupVerified'],name+': '+log.read_text(errors='replace')[-3000:]
stage('logo-build',120,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-framework','AppKit','-o',str(out/'logo-tests')])
stage('logo-tests',60,[str(out/'logo-tests')])
assert 'agent logo checks:' in (out/'logo-tests.log').read_text(),'the tests ran to the end'

def read(n):return (ROOT/n).read_text()
# The pane row's second line, and nothing else of the board changed for it.
b=read('Shepherd/Hosts/Views/AgentBoardView.swift')
pane=b[b.index('    private func row(for agent:'):b.index("    /// A tab's row")]
assert 'AgentPaneCaption(subtitle(for: agent), agentName: agent.agentName)' in pane,'the row shows the caption'
assert 'Text(subtitle(for: agent))' not in b and b.count('AgentPaneCaption(')==1,'in one place'
assert 'private func subtitle(for agent: AgentSummary) -> String {\n        if agent.hasAgent {\n            return agent.agentName ?? agent.source ?? agent.paneID\n        }' in b,'the words as they were'
assert '[pane.title, subtitle(for: pane)]' in b[b.index('    private func searchTexts(for pane:'):],'a search goes by the words'
assert 'AgentLogo' not in b,'the board knows only the caption'
assert b.count('.herdrItemDrag(')==2
# The mark: its own colors, read as the agent's name, no image of its own.
l=read('Shepherd/Hosts/Views/AgentLogo.swift')
caption=l[l.index('struct AgentPaneCaption: View {'):l.index('struct AgentLogoMark: View {')]
assert 'if let logo, let outline = logo.outline {\n            AgentLogoMark(logo: logo, outline: outline)\n        } else {\n            Text(text)\n                .font(.caption)\n                .foregroundStyle(.secondary)\n        }' in caption,'a mark, or the words as before'
mark=l[l.index('struct AgentLogoMark: View {'):]
for needed in ['.accessibilityElement(children: .ignore)','.accessibilityLabel(Text(logo.kind.title))','.accessibilityAddTraits(.isStaticText)','.help(Text(logo.kind.title))','.fill(logo.color(in: colorScheme))','.padding(Self.side * AgentLogo.clearSpace)']:
 assert needed in mark,needed
for gone in ['foregroundStyle','.tint(','foregroundColor','colorMultiply','hueRotation','saturation','grayscale','.blendMode','.opacity(','.isImage','Image(','renderingMode','scaleEffect','aspectRatio']:
 assert gone not in mark,gone
for gone in ['™','(TM)','Image(','NSImage','UIImage','Bundle','xcassets','systemName']:
 assert gone not in l,gone
assert 'case claude, codex, pi\n' in read(kit+'Agents/AgentKind.swift'),'AgentKind as it was'
# macOS only: the iOS app and the package know nothing of the marks.
for f in sorted(list((ROOT/'ShepherdMobile').rglob('*.swift'))+list((ROOT/'ShepherdKit').rglob('*.swift'))):
 t=f.read_text()
 assert 'AgentLogo' not in t and 'AgentPaneCaption' not in t,f
assert 'Text(verbatim: pane.agentName ?? String(localized: "Shell"))' in read('ShepherdMobile/BoardView.swift'),'the iOS board shows the name'
# Who the marks belong to, in the macOS app's notices.
n=read('Shepherd/ThirdPartyNotices.txt')
assert '\n\n========================================================================\nTrademarks\n========================================================================\n' in n
assert 'Claude is a trademark of Anthropic, PBC. The Pi logo belongs to Earendil Inc.\nhrdrhrdrhrdr is not affiliated with or endorsed by them.\n' in n
m=read('ShepherdMobile/ThirdPartyNotices.txt')
assert '\nTrademarks\n' not in m and 'Claude is a trademark' not in m,'the iOS app shows no marks'
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'pathDataSha256':True,'imageRenderer':True,'scales':[1,2,3],'colorSchemes':['light','dark'],
 'selectedRowProminence':True,'unshownHostingViews':True,'window':False,'herdr':False,'app':False,'sourceChecks':True},indent=2))
print('PASS agent logo runner: 2 stages and source checks')
