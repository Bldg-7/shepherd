#!/usr/bin/env python3
"""Actual existing launcher in never-shown owned windows; no CLI/account/core runs."""
from pathlib import Path
import argparse, hashlib, json, platform, subprocess, sys
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
out = a.output.resolve(); out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ['home', 'tmp', 'cache']: (out/name).mkdir(mode=0o700)
env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),
       'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),'LANG':'en_US.UTF-8',
       'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
models = ['JSONValue','AgentModels','AgentLaunchModels','AgentTitleDisplay','TabModels','HerdrMachine']
sources = ['ShepherdKit/Sources/ShepherdKit/Resources.swift'] + [f'ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/{n}.swift' for n in models]
sources += ['ShepherdKit/Sources/ShepherdKit/Agents/AgentKind.swift',
            'ShepherdKit/Sources/ShepherdKit/HerdrKit/Transport/ConnectionFailureDescription.swift',
            'Shepherd/Hosts/Views/LauncherMachineStep.swift','Shepherd/Hosts/Views/NewTabLauncher.swift',
            'Tests/Terminal/LauncherTabKeyTests.swift']
tracked = sources + ['Shepherd/Hosts/Views/AgentBoardView.swift', 'Tests/HcBackend/run-launcher-mode-tests.py']
def hashes(): return {n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}
baseline = hashes(); (out/'source-hashes.json').write_text(json.dumps(baseline,indent=2))
text = (ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
board = out/'BoardItem.swift'
board.write_text('import SwiftUI\n'+text[text.index('enum BoardItem:'):text.index('/// The sidebar content')])
sdk = subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],env=env,text=True).strip()
usr = Path(env['DEVELOPER_DIR'])/'Platforms/MacOSX.platform/Developer/usr'
flags = ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library',
         '-target',platform.machine()+'-apple-macos26.6.2','-sdk',sdk,
         '-external-plugin-path',str(usr/'lib/swift/host/plugins')+'#'+str(usr/'bin/swift-plugin-server')]
def stage(name, seconds, command):
    log = out/(name+'.log')
    r = subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),
        '--natural-exit-grace','10','--log',str(log),'--',*command],cwd=ROOT,env={**env,'OS_ACTIVITY_DT_MODE':'1'},timeout=seconds+40)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    assert r.returncode == 0 and record['naturalExitConfirmed'] and record['cleanupVerified'] and not record['signalsSent'], str(log)
    assert 'Modifying state during view update' not in log.read_text(errors='replace'), str(log)
exe = out/'launcher-tests'
stage('build',120,flags+sources+[str(board),'-framework','AppKit','-o',str(exe)])
stage('test',45,[str(exe)])
assert baseline == hashes(), 'source changed during validation'
(out/'validation.json').write_text(json.dumps({'passed':True,'actualLauncher':True,'ownedNeverShownWindows':True,
    'inspectionShellOnly':True,'tabCannotSelectHiddenCLI':True,'realCLIOrAccountRun':False,'productGUIQualification':False},indent=2))
print('PASS actual launcher modes:',out,flush=True)
