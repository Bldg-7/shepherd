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

    def test_preview_expansion_does_not_remove_live_terminal(self):
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        self.assertIn('WorkspaceDetailSplitView(showsPanel:', pane)
        self.assertIn('panelCoversTerminal: expandedPreview', pane)
        self.assertNotIn('if !expandedPreview', pane)
        self.assertIn('let epoch: UUID; let pane: UUID; let terminal:', pane)

if __name__ == '__main__':
    unittest.main()
