#!/usr/bin/env python3
"""The version Settings shows, built with and without DEBUG; no app or GUI."""
from pathlib import Path
import argparse,os,json,hashlib,plistlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/AppVersion.swift','Tests/Settings/AppVersionTests.swift']
view='Shepherd/Hosts/Views/MachinesSettingsView.swift'
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+[view,'Shepherd/Localizable.xcstrings']},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
# Bundle.main of a bare executable reads the Info.plist linked into it.
plist=out/'Info.plist';plist.write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.app-version','CFBundleShortVersionString':'9.8.7','CFBundleVersion':'65'}))
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library','-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(plist)]
for mode,defines in [('debug',['-D','DEBUG']),('release',[])]:
 stage(mode+'-build',60,flags+defines+sources+['-o',str(out/(mode+'-tests'))])
 stage(mode+'-tests',20,[str(out/(mode+'-tests')),mode])
m=(ROOT/view).read_text();s=json.loads((ROOT/'Shepherd/Localizable.xcstrings').read_text())['strings']
assert m.index('updatesSection(softwareUpdater)')<m.index('                versionSection\n')<m.index('.formStyle(.grouped)')
assert 'Text(verbatim: AppVersion.current.displayString)' in m and 'currentVersion' not in m
assert {l:s['Version']['localizations'][l]['stringUnit']['value'] for l in ['ko','ja']}=={'ko':'버전','ja':'バージョン'}
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':4,'debugSuffixOnlyWithDEBUG':True,'missingValuesShowQuestionMarks':True,'versionLastOnDefaultPage':True,'appOrGUI':False},indent=2))
