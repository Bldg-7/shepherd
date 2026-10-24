#!/usr/bin/env python3
"""Callback-driven List activation + production terminal focus; native mouse delivery is manual."""
from pathlib import Path
import argparse, hashlib, json, os, platform, shutil, subprocess, sys
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--swiftterm-products', type=Path, required=True)
a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, mode=0o700, exist_ok=False)
for name in ['home', 'tmp', 'cache', 'modules']: (out/name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'cache'), DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
products = a.swiftterm_products.resolve()
shutil.copytree(products/'SwiftTerm_SwiftTerm.bundle', out/'SwiftTerm_SwiftTerm.bundle')
def stage(name, seconds, command):
    log = out/(name+'.log')
    subprocess.run([sys.executable, str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'), '--timeout', str(seconds), '--natural-exit-grace', '10', '--log', str(log), '--', *command], cwd=ROOT, env=env, timeout=seconds+40, check=True)
    status = json.loads(log.with_suffix('.stage.json').read_text())
    assert status['naturalExitConfirmed'] and status['cleanupVerified'] and not status['signalsSent'], name
    text = log.read_text(errors='replace')
    assert 'Modifying state during view update' not in text, name
sources = ['Shepherd/Hosts/Views/BoardRowActivation.swift', 'Shepherd/Terminal/TerminalFileGesture.swift', 'Shepherd/Terminal/TerminalWebLink.swift', 'Shepherd/Terminal/TerminalHostView.swift', 'Shepherd/FilePreview/TerminalFileHit.swift', 'Shepherd/FilePreview/FilePreviewLink.swift', 'Shepherd/Terminal/AgentTerminalViewModel.swift', 'Shepherd/Terminal/HerdrAttachInput.swift', 'ShepherdKit/Sources/ShepherdKit/HerdrKit/Terminal/TerminalSessionProviding.swift', 'Tests/Terminal/BoardRowFocusTests.swift']
# Extract the production request type, rather than replacing its fresh-token behavior.
switcher = (ROOT/'Shepherd/Hosts/Views/PaneSwitcher.swift').read_text()
focus = out/'FocusRequest.swift'
focus.write_text('import Foundation\n'+switcher[switcher.index('nonisolated struct TerminalPaneFocus:'):switcher.index('extension EnvironmentValues')])
nio = out/'TestNIO.swift'
nio.write_text('public struct ByteBuffer: Sendable { public var readableBytesView: [UInt8] = []; public init() {}; public mutating func writeString(_ s: String) { readableBytesView += Array(s.utf8) }; public mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 { readableBytesView += Array(bytes) } }\n')
target = platform.machine()+'-apple-macos26.6.2'
stage('test-nio', 60, ['xcrun', 'swiftc', '-target', target, '-emit-library', '-emit-module', '-module-name', 'NIOCore', str(nio), '-emit-module-path', str(out/'modules/NIOCore.swiftmodule'), '-o', str(out/'modules/libNIOCore.dylib')])
stage('focus-build', 120, ['xcrun', 'swiftc', '-target', target, '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library', '-I', str(out/'modules'), '-I', str(products), '-L', str(out/'modules'), '-lNIOCore', '-Xlinker', '-rpath', '-Xlinker', str(out/'modules'), *sources, str(focus), str(products/'SwiftTerm.o'), '-framework', 'AppKit', '-framework', 'QuartzCore', '-framework', 'CoreText', '-o', str(out/'focus-tests')])
stage('focus-tests', 30, [str(out/'focus-tests')])
gesture = (ROOT/'Shepherd/Hosts/Views/BoardRowActivation.swift').read_text()
assert '.simultaneousGesture(TapGesture().onEnded { perform() })' in gesture
assert 'contentShape(Rectangle())' in gesture
board = (ROOT/'Shepherd/Hosts/Views/AgentBoardView.swift').read_text()
content = (ROOT/'Shepherd/ContentView.swift').read_text()
assert '.onBoardRowActivation { activate(.pane(agent)) }' in board
assert '.onBoardRowActivation { activate(.tab(tab)) }' in board
activation = board[board.index('    private func activate('):board.index('    /// A status dot')]
assert activation.index('selection = item') < activation.index('onActivate(item)')
assert 'onActivate: { item in activateBoardItem(item, on: machine) }' in content
handoff = content[content.index('    private func activateBoardItem('):content.index('    /// The pane in `item`')]
for guard in ['machineStore.isCurrentConnection(machine)', 'machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity', 'selection(on: machine).wrappedValue?.id == item.id']:
    assert guard in handoff
assert 'endTitleRename(titleRename, .left)' in handoff and 'expandedPreview = nil' in handoff
assert 'keyboardPane(in: item).map { TerminalPaneFocus(paneID: $0) }' in handoff
assert 'activatedPanes[identity] ?? tab.focusedPaneID' in content
stage('source-parse', 60, ['xcrun', 'swiftc', '-frontend', '-parse', 'Shepherd/ContentView.swift', 'Shepherd/Hosts/Views/AgentBoardView.swift'])
tracked = sources + ['Shepherd/ContentView.swift', 'Shepherd/Hosts/Views/AgentBoardView.swift', 'Shepherd/Hosts/Views/PaneSwitcher.swift']
(out/'source-hashes.json').write_text(json.dumps({n: hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in tracked}, indent=2))
(out/'validation.json').write_text(json.dumps({'passed': True, 'ownedUnshownWindow': True, 'productionTerminalFocus': True, 'gestureDelivery': 'NOTRUN: callback-driven fixture', 'actualContentView': 'wiring/source checks only', 'herdrOrNetworkOrUserInput': False}, indent=2))
print('PASS board row focus: callback-driven activation/reselection/tab targeting/refresh checks and app wiring; live mouse delivery NOTRUN')
