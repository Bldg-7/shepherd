#!/usr/bin/env python3
"""Native sidebar selection emphasis without changing keyboard focus or window activity."""
from pathlib import Path
import argparse, hashlib, json, os, platform, subprocess, sys
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); a = p.parse_args()
out = a.output.resolve(); out.mkdir(parents=True, mode=0o700, exist_ok=False)
for name in ['home', 'tmp', 'cache']: (out/name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', OS_ACTIVITY_DT_MODE='1')
def stage(name, seconds, command):
    log = out/(name+'.log')
    subprocess.run([sys.executable, str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout', str(seconds), '--natural-exit-grace', '10', '--log', str(log), '--', *command], cwd=ROOT, env=env, timeout=seconds+40, check=True)
    record = json.loads(log.with_suffix('.stage.json').read_text())
    assert record['naturalExitConfirmed'] and record['cleanupVerified'] and not record['signalsSent']
    text = log.read_text(errors='replace')
    assert 'Modifying state during view update' not in text and 'reentrant' not in text.lower(), name
sources = ['Shepherd/Hosts/Views/BoardSelectionEmphasis.swift', 'Tests/Terminal/BoardSelectionEmphasisTests.swift']
stage('style-build', 90, ['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-framework','AppKit','-o',str(out/'style-tests')])
stage('style-tests', 30, [str(out/'style-tests')])
board = (ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
assert '.onBoardRowActivation { activate(.pane(agent)) }\n        .boardSelectionEmphasized(selection?.id == agent.id)' in board
assert '.onBoardRowActivation { activate(.tab(tab)) }\n        .boardSelectionEmphasized(selection?.id == tab.id)' in board
assert board.count('.boardSelectionEmphasized(') == 2
style = (ROOT/sources[0]).read_text()
assert 'makeFirstResponder' not in style and 'controlActiveState' not in style and 'NSColor' not in style
assert 'method_exchangeImplementations' not in style and 'object_setClass' not in style
assert 'let windowIsKey = controlActiveState == .key' in board, 'seen state still follows the real window'
stage('board-parse', 60, ['xcrun','swiftc','-frontend','-parse','Shepherd/Hosts/Views/AgentBoardView.swift'])
sources += ['Shepherd/Hosts/Views/AgentBoardView.swift', 'Shepherd/Hosts/Views/BoardRowActivation.swift', 'Shepherd/ContentView.swift']
(out/'source-hashes.json').write_text(json.dumps({s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},indent=2))
(out/'validation.json').write_text(json.dumps({'passed':True,'nativeRowAppearance':True,'lightDarkHighContrast':True,'focusUnchanged':True,'realSwiftUIList':True,'ownedNeverShownWindow':True,'appLaunched':False,'liveMouseInput':False},indent=2))
print('PASS sidebar selection appearance and app wiring; keyboard and real window activity untouched')
