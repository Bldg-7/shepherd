#!/usr/bin/env python3
"""Focused source-contract checks for the iOS-only Board cache composition.

These use no device, credential store, transport, or persisted user data. The
storage and monitor runners exercise their synthetic runtime behavior; this
runner protects the mobile wiring that combines those completed contracts.
"""
from pathlib import Path
import argparse
import json

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, mode=0o700, exist_ok=False)

mobile = (ROOT / "ShepherdMobile" / "MobileAgentListCache.swift").read_text()
board = (ROOT / "ShepherdMobile" / "BoardView.swift").read_text()
app = (ROOT / "ShepherdMobile" / "ShepherdMobileApp.swift").read_text()
store = (ROOT / "ShepherdKit" / "Sources" / "ShepherdKit" / "Machines" / "MachineStore.swift").read_text()
monitor = (ROOT / "ShepherdKit" / "Sources" / "ShepherdKit" / "Machines" / "MachineMonitor.swift").read_text()

checks = {
    "ios_application_support_only": "applicationSupportDirectory" in app and "AgentListCache" in app,
    "selected_board_only": "func snapshot(for machine: Machine)" in mobile and "allMachines" not in mobile,
    "cache_before_access_refresh": "cachedSnapshot = await agentListCache.snapshot(for: machine)" in board
        and board.index("cachedSnapshot = await agentListCache.snapshot(for: machine)") < board.index("monitor.refreshNow()"),
    "pull_awaits_monitor_completion": "_ = await monitor.refresh()" in board,
    "successful_publication_mapping": "observePublication" in mobile and "case .host:" in mobile
        and "case .herdrMachines:" in mobile,
    "partial_nested_retention": "return previous[group.machine.id]" in mobile
        and "pendingNestedGroups" in mobile,
    "nested_before_host_is_retained": "state.pendingNestedGroups = groups" in mobile
        and "state.snapshot?.nestedGroups ?? state.pendingNestedGroups ?? []" in mobile,
    "authoritative_empty_nested": "nestedGroups: groups" in mobile,
    "safe_cached_taps": "CachedPaneRow(pane: pane)" in board
        and "NavigationLink(value: PaneDestination" not in board[board.index("private func cachedSection"):board.index("private struct BoardSection")],
    "cache_excludes_session_material": all(word not in mobile for word in ["sessionReference", "conversationID", "transcript", "output"]),
    "precommit_identity_invalidation": "connectionWillInvalidate?(current.connectionIdentity)" in store
        and "connectionWillInvalidate?(machine.connectionIdentity)" in store
        and "machineWillRemove?(current.id)" in store,
    "revision_ordered_write_guard": "state.revision == revision" in mobile
        and "states[identity]?.generation == generation" in mobile,
    "durable_retirement_before_commit": "RetiredCacheIdentities" in mobile
        and "guard retired.retire(identity) else { return false }" in mobile
        and "cacheInvalidationFailed" in store,
    "bounded_debounce_and_flush": "debounceNanoseconds" in mobile
        and "func flush(for machine" in mobile,
    "monitor_refresh_contract_unchanged": "public func refresh() async -> RefreshResult" in monitor,
}
failed = [name for name, passed in checks.items() if not passed]
(out / "results.json").write_text(json.dumps({"passed": not failed, "checks": checks,
    "realNetwork": False, "ssh": False, "credentials": False, "device": False}, indent=2))
if failed:
    raise SystemExit("FAIL mobile cache integration checks: " + ", ".join(failed))
print(f"PASS {len(checks)} mobile cache integration checks; source-only, no network, SSH, credentials, or device")
