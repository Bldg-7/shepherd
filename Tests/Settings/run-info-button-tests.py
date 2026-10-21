#!/usr/bin/env python3
"""The Settings ⓘ: clicks open and close its popover; owned offscreen window, no app."""
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
sources=['Shepherd/Hosts/Views/InfoButton.swift','Tests/Settings/InfoButtonTests.swift']
views=['Shepherd/Hosts/Views/ExperimentalFeaturesSettingsView.swift','Shepherd/Hosts/Views/AgentSkillRows.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources+views},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('build',90,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'info-button-tests')])
stage('tests',30,[str(out/'info-button-tests')])
# Every ⓘ in Settings is this button, never a bare icon with only a tooltip.
e,a=[(ROOT/v).read_text() for v in views]
assert e.count('InfoButton(accessibilityLabel: "About ')==2 and a.count('InfoButton(accessibilityLabel: "About ')==1
assert 'systemName: "info.circle"' not in e+a
assert 'Text("In-app Browser")' in e and 'Text("Terminal File Drop")' in e and '(Experimental)' not in e
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'toggleLabelAndPlainRow':True,'closesOnSecondClickOutsideClickEscape':True,'ownedOffscreenWindow':True,'appOrUserInput':False},indent=2))
