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
        self.assertIn('guard scopeIsCurrent(), presentation.hasSelection, let tab', board)
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

    def test_workspace_row_drag_is_scoped_and_separate_from_files(self):
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        drag = source('Shepherd/HcBackend/HcWorkspaceItemDrag.swift')
        self.assertIn('.itemProvider { itemProvider(.tab(tab.id)) }', board)
        self.assertIn('.itemProvider { itemProvider(.pane(pane.id)) }', board)
        self.assertIn('textDrop: rowDrop', pane)
        row = pane[pane.index('private var rowDrop:'):pane.index('private var currentScope:')]
        self.assertNotIn('TerminalFileDropFeature', row)
        for guard in ['dragged.machine == machine.connectionIdentity','dragged.sourceIsCurrent()', 'model.workspace?.epoch == epoch', 'model.workspace?.canWrite == true']:
            self.assertIn(guard, drag)
        self.assertIn('visibility:.ownProcess', drag)
        self.assertNotIn('HerdrItemDrag.Item', drag)

    def test_deferred_close_uses_original_scope_and_revision(self):
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        root = source('Shepherd/HcBackend/HcRootView.swift')
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        self.assertIn('let stamp: HcWorkspaceMutationStamp', board)
        self.assertIn('guard matches(request.stamp)', board)
        self.assertIn('stamp.matches(epoch:model.workspace?.epoch,coreID:model.coreID,version:model.workspace?.snapshot?.version)', board)
        self.assertIn('presentation.beginSelectedClose(focus:beforeFocus)', board)
        self.assertIn('presentation.finishSelectedClose(intent,focus:focus)', board)
        self.assertIn('connection.model === candidate && connection.identity == machine.connectionIdentity', root)
        self.assertIn('[weak connection, machineStore]', root)
        self.assertIn('guard isCurrentScope(), model.state == .connected else { return false }', pane)

    def test_new_text_editor_intent_retires_deferred_terminal_focus(self):
        state = source('Shepherd/HcBackend/HcWorkspacePresentation.swift')
        pane = source('Shepherd/HcBackend/HcTerminalPane.swift')
        tracker = source('Shepherd/HcBackend/HcTextInputOwnership.swift')
        self.assertIn('@ObservationIgnored private(set) var inputGeneration', state)
        self.assertIn('keyboardIntent?.inputGeneration == request.inputGeneration', pane)
        self.assertIn('keyboardIntent?.keyboardRequest?.token == request.token', pane)
        self.assertIn('keyboardIntent?.textFieldOwnsKeyboard != true', pane)
        self.assertIn('guard focused == actual else { return false }', pane)
        self.assertIn('control.window === window', tracker)
        self.assertIn('NSControl.textDidBeginEditingNotification', tracker)
        self.assertNotIn('addLocalMonitorForEvents', tracker)
        self.assertNotIn('makeFirstResponder', tracker)

    def test_existing_terminals_use_explicit_canonical_switcher_choices(self):
        switcher = source('Shepherd/HcBackend/HcLaunchSheet.swift')
        policy = source('Shepherd/HcBackend/HcWorkspaceSwitcherCandidates.swift')
        model = source('ShepherdKit/Sources/ShepherdKit/CoreKit/HcWorkspaceModel.swift')
        show = model[model.index('@discardableResult public func showTerminal('):model.index('public func closePane(')]
        self.assertIn('case .terminal(let id)', switcher)
        self.assertIn('CoreTerminalID.isCanonical($0.address)', policy)
        self.assertIn('guard snapshotAvailable', policy)
        self.assertIn('counts[$0.address] == 1', policy)
        self.assertIn('terminal: .init(coreID: coreID, terminalID: record.address)', show)
        self.assertIn('record.address == address', show)
        self.assertNotIn('terminal.run', show)
        self.assertNotIn('terminal.kill', show)

    def test_program_end_is_separate_and_durable_not_default_close(self):
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        model = source('ShepherdKit/Sources/ShepherdKit/CoreKit/HcWorkspaceModel.swift')
        self.assertIn('close(closing) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("hc.close.confirm")', board)
        self.assertIn('close(closing,endPrograms:true)', board)
        self.assertIn('hc.close.end-programs.confirm', board)
        self.assertIn('public func closeTab(_ id: UUID, endPrograms: Bool = false)', model)
        ending = model[model.index('private func endClosedPrograms('):model.index('public func prepareOperationReview(')]
        self.assertLess(ending.index('journal.beginStop('), ending.index('board.kill('))
        self.assertIn('CoreTerminalID.isCanonical(reference.terminalID)', ending)
        self.assertIn('after.state == "finished"', ending)
        self.assertIn('journal.finishStop(stop,confirmedEnded:false)', ending)

    def test_launch_directories_are_resolved_before_placeholder_cas(self):
        model = source('ShepherdKit/Sources/ShepherdKit/CoreKit/HcWorkspaceModel.swift')
        tab = model[model.index('public func launchTab('):model.index('private func launchDirectory(')]
        split = model[model.index('public func launchSplit('):model.index('private func launchInto(')]
        self.assertLess(tab.index('launchDirectory('),tab.index('commit(.appendTab'))
        self.assertLess(split.index('confirmedDirectory('),split.index('commit(.splitPane'))
        self.assertIn('source.terminal.map({ $0.coreID == coreID',split)
        self.assertIn('cwd: record.cwd.isEmpty ? nil : record.cwd',model)
        board = source('Shepherd/HcBackend/HcWorkspaceView.swift')
        action = board[board.index('private func split('):board.index('private func mutationStamp(')]
        self.assertNotIn('record(pane)?.cwd',action)

    def test_recovery_sheet_separates_layout_and_program_outcomes(self):
        sheet = source('Shepherd/HcBackend/HcOperationReviewSheet.swift')
        policy = source('Shepherd/HcBackend/HcRecoveryPresentationText.swift')
        self.assertIn('HcRecoveryPresentationText.title(review.record)',sheet)
        self.assertIn('ForEach(review.record.targets,id:\\.terminal)',sheet)
        self.assertIn('HcRecoveryPresentationText.stop(target.state)',sheet)
        self.assertIn('.frame(maxHeight:180)',sheet)
        for state in ['pending','inFlight','uncertain','confirmed','shared','foreign']:
            self.assertIn('case .'+state+':',policy)
        self.assertNotIn('terminal.kill',policy)
        self.assertNotIn('terminal.run',policy)

    def test_machine_owner_tracks_initialization_and_serializes_retirement(self):
        owner = source('ShepherdKit/Sources/ShepherdKit/Machines/HcMachineConnection.swift')
        self.assertIn('private var retirement: Task<Void, Error>?',owner)
        self.assertIn('let previous = model ?? preparing',owner)
        self.assertIn('try await earlier?.value',owner)
        self.assertIn('opening = nil; starting = rpc',owner)
        self.assertIn('preparing = next',owner)
        closing = owner[owner.index('public func close()'):]
        self.assertIn('let cleanup = retireCurrent()',closing)
        self.assertGreaterEqual(closing.count('guard token == generation'),2)
        model = source('ShepherdKit/Sources/ShepherdKit/CoreKit/HcWorkspaceModel.swift')
        self.assertIn('if let closingTask { try await closingTask.value; return }',model)

    def test_default_close_audit_uses_one_real_return_event(self):
        host = source('Shepherd/HcBackend/HcMigrationHost.swift')
        action = host[host.index('func hcFixtureDefaultReturn('):host.index('func hcFixturePress(')]
        self.assertIn('hcFixtureNativeButtonReady(button)',action)
        self.assertIn('window.defaultButtonCell === button.cell',action)
        self.assertEqual(action.count('NSApp.sendEvent(event)'),1)
        self.assertNotIn('performClick',action)
        audit = source('Shepherd/HcBackend/HcWorkspaceLayoutAudit.swift')
        self.assertIn('hcFixtureDefaultReturn("hc.close.confirm",owner:window,root:root)',audit)
        self.assertIn('before.createdMs == after.createdMs && before.state == after.state',audit)

    def test_switcher_submit_resolves_only_the_current_available_results(self):
        switcher = source('Shepherd/Hosts/Views/PaneSwitcher.swift')
        self.assertIn('?? results.first(where: \\.isAvailable)',switcher)
        self.assertIn('WorkspaceSwitcherItem.submitted(in:results,highlightedID:highlightedID)',switcher)
        submit = switcher[switcher.index('private func chooseHighlighted()'):]
        self.assertNotIn('destinations.first',submit)

    def test_fullscreen_native_layout_never_counts_as_edge_hover(self):
        runner = source('Tests/HcBackend/run-ui-tests.py')
        audit = source('Shepherd/HcBackend/HcWorkspaceLayoutAudit.swift')
        self.assertIn('if a.fullscreen_native_layout and a.fullscreen_audit:p.error(',runner)
        self.assertIn("audit.get('fullscreenSpaceAndEdgeReveal') is False",runner)
        self.assertIn('if fullscreen && !nativeFullscreenLayout {',audit)
        self.assertIn('"fullscreenSpaceAndEdgeReveal":fullscreen && !nativeFullscreenLayout',audit)
        self.assertIn('"fullscreenNativeLayout":fullscreen && nativeFullscreenLayout',audit)
        self.assertIn('for cycle in 1...3',audit)
        self.assertIn('"globalEventInjection":false',audit)

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
        self.assertIn('model.document?.pane(pane)?.terminal == pending.terminal', root)
        self.assertIn('model.workspace?.snapshot?.version == version', root)
        self.assertIn('selectOnSuccess:false', root)
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
        store = source('Shepherd/HcBackend/HcPanePresentation.swift')
        self.assertIn('let epoch: UUID; let item: HcPreviewSelection', store)
        self.assertIn('$0.id == source.id && $0.terminal == source.terminal', store)
        self.assertIn('case pane(UUID), tab(UUID)', store)
        self.assertIn('previewTabID: showsTabs ? tab.id : nil', workspace)
        self.assertIn('onClose: { shown.hide() }', workspace)
        self.assertIn('hc.preview.toggle', workspace)
        self.assertIn('.id(shown.previewModel.id)', workspace)
        self.assertLess(workspace.index('.previewExpansion('),workspace.index('.id(shown.previewModel.id)'))
        self.assertNotIn('@State private var presentation: HcPanePresentation', pane)

if __name__ == '__main__':
    unittest.main()
