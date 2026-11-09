#!/usr/bin/env python3
"""Callback-driven List activation + production terminal view taking the keyboard; native mouse delivery is manual."""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, subprocess, sys
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--swiftterm-products', type=Path, required=True)
a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, mode=0o700, exist_ok=False)
for name in ['home', 'tmp', 'cache']: (out/name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
products = a.swiftterm_products.resolve()
shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle', out/'SwiftTerm_SwiftTerm.bundle')
def stage(name, seconds, command):
    log = out/(name+'.log')
    subprocess.run([sys.executable, str(ROOT/'Tests/Support/run-stage.py'), '--timeout', str(seconds), '--natural-exit-grace', '10', '--log', str(log), '--', *command], cwd=ROOT, env=env, timeout=seconds+40, check=True)
    status = json.loads(log.with_suffix('.stage.json').read_text())
    assert status['naturalExitConfirmed'] and status['cleanupVerified'] and not status['signalsSent'], name
    text = log.read_text(errors='replace')
    assert 'Modifying state during view update' not in text, name
sources = ['Shepherd/Hosts/Views/BoardRowActivation.swift', 'Shepherd/Hosts/Views/BoardSelectionEmphasis.swift', 'Shepherd/Terminal/TerminalFileGesture.swift', 'Shepherd/Terminal/TerminalWebLink.swift', 'Shepherd/Terminal/SelectionKeepingTerminal.swift','Shepherd/Terminal/TerminalHostView.swift', 'Shepherd/FilePreview/TerminalFileHit.swift', 'Shepherd/FilePreview/FilePreviewLink.swift', 'Tests/Terminal/BoardRowFocusTests.swift']
target = platform.machine()+'-apple-macos26.6.2'
stage('focus-build', 120, ['xcrun', 'swiftc', '-target', target, '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library', '-I', str(products), *sources, str(products/'SwiftTerm.o'), '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'CoreText', '-o', str(out/'focus-tests')])
stage('focus-tests', 30, [str(out/'focus-tests')])
gesture = (ROOT/'Shepherd/Hosts/Views/BoardRowActivation.swift').read_text()
assert '.simultaneousGesture(TapGesture().onEnded { perform() })' in gesture
assert 'contentShape(Rectangle())' in gesture
board = (ROOT/'Shepherd/HcBackend/HcWorkspaceView.swift').read_text()
# Each row is activated by a click, which selects its item, then hands it on.
assert '.onBoardRowActivation { selection.wrappedValue = .tab(tab.id); onActivate() }' in board
assert '.onBoardRowActivation { selection.wrappedValue = .pane(pane.id); onActivate() }' in board
assert 'onActivate: activateSelection' in board
activation = board[board.index('    private func activateSelection('):board.index('    private var currentSelection:')]
assert 'presentation.select(stamp, requestKeyboard: true)' in activation
tracked = sources + ['Shepherd/HcBackend/HcWorkspaceView.swift']
(out/'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}, indent=2))
(out/'validation.json').write_text(json.dumps({'passed': True, 'ownedUnshownWindow': True, 'productionTerminalView': True, 'focusRequest': 'test-local, as the pane does', 'gestureDelivery': 'NOTRUN: callback-driven fixture', 'actualWorkspaceView': 'wiring/source checks only', 'herdrOrNetworkOrUserInput': False}, indent=2))
print('PASS board row focus: callback-driven activation/reselection/tab targeting/refresh checks and app wiring; live mouse delivery NOTRUN')
