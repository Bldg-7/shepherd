#!/usr/bin/env python3
"""Source-wiring regression guards. NOT a visual/native parity qualification."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

def source(name):
    return (ROOT / name).read_text()

def reject_old_composition(root, board):
    for fragment in ['Picker("Machine"', 'Text("hc · "', 'Button("New Terminal…")']:
        if fragment in root:
            raise ValueError('full-window replacement header returned')
    for fragment in ['Section("Core terminals")', 'Section("Workspaces")', 'TextField("Workspace name"']:
        if fragment in board:
            raise ValueError('diagnostic/editor sidebar returned')

class PreservationWiring(unittest.TestCase):
    def test_rejected_composition_stays_removed(self):
        reject_old_composition(source('Shepherd/HcBackend/HcRootView.swift'), source('Shepherd/HcBackend/HcWorkspaceView.swift'))
        for root, board in [('Picker("Machine"',''), ('Text("hc · "',''), ('','Section("Core terminals")'), ('','TextField("Workspace name"')]:
            with self.assertRaises(ValueError):
                reject_old_composition(root, board)

    def test_same_actual_presentations_not_parallel_copies(self):
        old = source('Shepherd/Hosts/Views/AgentBoardView.swift')
        new = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        for name in ['WorkspaceBoardRow(', 'WorkspaceBoardSearchBar(', 'WorkspaceBoardTabModeBar(', 'WorkspaceBoardSectionLabel(']:
            self.assertIn(name, old)
            self.assertIn(name, new)
        self.assertIn('WorkspaceNavigationSplitView(', source('Shepherd/ContentView.swift'))
        self.assertIn('WorkspaceNavigationSplitView(', new)
        self.assertIn('TitleRenameField(session:', new)
        self.assertIn('TitleDoubleClick(rename:', new)
        self.assertNotIn('minWidth: 760', new)

    def test_real_launcher_without_browser_authority(self):
        root = source('Shepherd/HcBackend/HcRootView.swift')
        self.assertIn('NewTabLauncher(targets:', root)
        self.assertIn('standalonePrograms: true', root)
        self.assertNotIn('HcLaunchSheet(', root)
        self.assertNotIn('allowsBrowserAgents: true', root)
        self.assertIn('request.herdrMachine == nil', root)
        self.assertIn('UUID(uuidString: selected.workspaceID)', root)
        self.assertIn('scopedModel === model', root)

    def test_inspection_rejects_unsupported_launch_before_metadata(self):
        root = source('Shepherd/HcBackend/HcRootView.swift')
        launch = root[root.index('private func launch('):]
        self.assertLess(launch.index('guard !inspectionOnly || request.program == .shell'), launch.index('model.createWorkspace'))
        self.assertIn('allowedStandalonePrograms: inspectionOnly ? [.shell]', root)
        self.assertIn('describeFailure:', root)
        self.assertIn('return hcConnectionFailureDescription(error)', root)

    def test_selection_and_focus_are_explicit_ui_intents(self):
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        root = source('Shepherd/HcBackend/HcRootView.swift')
        self.assertIn('presentation.clearSelection(focus: selectionStamp)', board)
        self.assertIn('guard presentation.hasSelection, let tab', board)
        self.assertIn('requestKeyboard: false', board)
        self.assertIn('requestKeyboard: true', board)
        self.assertIn('request.epoch == model.workspace?.epoch', pane)
        self.assertIn('request.pane == pane.id', pane)
        self.assertIn('window.isKeyWindow', pane)
        self.assertIn('presentation.hasSelection && !presentation.previewCoversTerminal', root)

    def test_retry_uses_new_connect_not_recycled_stream(self):
        root = source('Shepherd/HcBackend/HcRootView.swift')
        host = source('Shepherd/HcBackend/HcMigrationHost.swift')
        self.assertIn('let transport = try localTransportFactory?()', root)
        self.assertIn('onReconnect: { Task { await openConnection() } }', root)
        self.assertNotIn('private let localTransport: (any CoreByteTransport)?', root)
        self.assertIn('let transport = try CoreProcessTransport(configuration: configuration)', host)
        self.assertIn('Button("Retry", action: onRetry).accessibilityIdentifier("workspace.board.retry")', source('Shepherd/HcBackend/HcWorkspaceView.swift'))

    def test_title_submit_retains_exact_epoch_and_version(self):
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        ending = board[board.index('private func endRename('):board.index('private var detailTitle:')]
        self.assertIn('model.workspace?.epoch == session.epoch', ending)
        self.assertIn('model.workspace?.snapshot?.version == session.version', ending)
        self.assertIn('session.end()', ending)
        self.assertIn('if case .cancel = ending { return }', ending)
        self.assertIn('model.renameTab(id, name: name)', ending)
        self.assertIn('model.renamePane(id, name: name)', ending)

    def test_actual_rendered_selection_not_hidden_siblings_is_viewed(self):
        root = source('Shepherd/HcBackend/HcRootView.swift')
        self.assertIn('controlActiveState == .key, presentation.hasSelection', root)
        self.assertIn('HcWorkspacePresentation.viewedPanes(', root)
        self.assertIn('all.filter { visible.contains($0.id) }', root)

    def test_switcher_selection_waits_for_real_sheet_dismissal(self):
        root = source('Shepherd/HcBackend/HcRootView.swift')
        switcher = source('Shepherd/HcBackend/HcLaunchSheet.swift')
        self.assertIn('onDismiss: completeSwitcherSelection', root)
        self.assertIn('model.workspace?.epoch == pending.epoch', root)
        self.assertIn('model.document?.pane(pending.pane)?.terminal == pending.terminal', root)
        self.assertNotIn('model.select(', switcher)
        self.assertGreaterEqual(root.count('.presentationPreventsAppTermination(false)'), 5)

    def test_preview_expansion_does_not_remove_live_terminal(self):
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        workspace = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        self.assertIn('WorkspaceDetailSplitView(showsPanel:', workspace)
        self.assertIn('panelCoversTerminal: shown?.expanded == true', workspace)
        self.assertNotIn('WorkspaceDetailSplitView(', pane)  # One preview beside the whole tab, not one split per pane.
        self.assertNotIn('if !expandedPreview', pane)
        self.assertIn('TerminalPaneFrame(isFocused:', pane)
        self.assertNotIn('HStack {', pane[pane.index('var body: some View'):pane.index('private func makeDrops')])
        self.assertIn('let epoch: UUID; let pane: UUID; let terminal:', pane)

if __name__ == '__main__':
    unittest.main()
