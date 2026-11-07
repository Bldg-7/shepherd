#!/usr/bin/env python3
"""Strict current board presentation rules; no window, CLI, service or account."""
from pathlib import Path
import argparse, hashlib, json, platform, subprocess, sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/Terminal'))
from native_test_env import settings
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
a = p.parse_args(); out = a.output.resolve(); out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache']: (out/name).mkdir(mode=0o700)
env, sdk_flags = settings(out)
sources = ['ShepherdKit/Sources/ShepherdKit/Resources.swift',
           'ShepherdKit/Sources/ShepherdKit/Agents/AgentKind.swift']
sources += ['ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/'+name+'.swift' for name in
            ['JSONValue','AgentModels','AgentLaunchModels','AgentTitleDisplay','TabModels','HerdrMachine']]
sources += ['Shepherd/Hosts/Views/WorkspaceBoardPresentation.swift','Tests/HcBackend/HcProgramStatusPresentationTests.swift']
tracked = [*sources,'Shepherd/HcBackend/HcWorkspaceView.swift','Tests/HcBackend/run-program-status-presentation-tests.py',
           'Tests/Terminal/native_test_env.py']
def hashes(): return {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in tracked}
before = hashes(); (out/'source-hashes.json').write_text(json.dumps(before,indent=2))
profile = out/'deny-network.sb'; profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
flags = ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-warnings-as-errors','-parse-as-library',
         '-target',platform.machine()+'-apple-macos26.6.2',*sdk_flags]
def stage(name, command):
    log = out/(name+'.log')
    subprocess.run([sys.executable,'-B',str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','90',
                    '--natural-exit-grace','5','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,check=True,timeout=120)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    assert record['naturalExitConfirmed'] and record['cleanupVerified'] and not record['signalsSent'], str(log)
for mode, extra in [('debug',[]),('optimized',['-O'])]:
    exe = out/('status-'+mode)
    stage(mode+'-build',[*flags,*extra,*sources,'-o',exe])
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',profile,exe])
assert before == hashes(), 'source changed'
(out/'validation.json').write_text(json.dumps({'passed':True,'modes':['debug','optimized'],'checksPerMode':32,
    'nativeGUIQualified':False,'actualCLIQualified':False,'userConfigOrCoreUsed':False},indent=2))
print('PASS native program status presentation:',out)
