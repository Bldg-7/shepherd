#!/usr/bin/env python3
"""Offline source contracts for Pi state authority; no Herdr, app, or provider."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)

sources = [
    'Shepherd/Agents/PiHostBridge.swift',
    'Shepherd/Agents/PiLaunchCoordinator.swift',
    'ShepherdKit/Sources/ShepherdKit/HerdrKit/HerdrClient.swift',
    'Shepherd/Agents/AgentRuntime/pi-entry.ts',
    'Tests/AgentBrowser/Phase3/PiBridgeClientFixture.mjs',
    'docs/pi-agent-support.md',
]
text = {name: (ROOT / name).read_text() for name in sources}
(out / 'source-hashes.json').write_text(json.dumps({
    name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sources
}, indent=2))

for name in sources[:4]:
    for retired in ('reportPiState', 'reportState', 'reportSequence', 'herdrReporting', 'herdrState'):
        assert retired not in text[name], f'{name} retains {retired}'

client = text['ShepherdKit/Sources/ShepherdKit/HerdrKit/HerdrClient.swift']
assert 'pane.report_agent' not in client and 'clear_agent_authority' not in client
fixture = text['Tests/AgentBrowser/Phase3/PiBridgeClientFixture.mjs']
assert "control(config.bootstrap,'herdrState'" in fixture
assert "retiredStateReport.error,'invalidRequest'" in fixture
entry = text['Shepherd/Agents/AgentRuntime/pi-entry.ts']
assert 'captureSession = identity.sessionID' in entry
assert 'registration.ensureConnected()' in entry
support = text['docs/pi-agent-support.md']
assert '앱은 Pi 상태를 Herdr에 보고하지 않는다.' in support
assert '사용자가 Pi를 재시작해야 한다.' in support

(out / 'validation.json').write_text(json.dumps({
    'passed': True,
    'syntheticOnly': True,
    'realHerdr': 'NOTRUN',
    'app': 'NOTRUN',
    'providersOrCredentials': 'NOTRUN',
}, indent=2))
print('PASS Pi state authority source contracts: no app reporter; bridge rejects retired command')
