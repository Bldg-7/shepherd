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
    'Shepherd/Agents/AgentRuntime/pi-host.mjs',
    'Shepherd/Agents/AgentRuntime/pi-capture-proof.mjs',
    'Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs',
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
assert "host.acknowledgeCapture(identity),true" in fixture
assert "host.acknowledgeCapture({...identity,sessionID:crypto.randomUUID()}),false" in fixture
entry = text['Shepherd/Agents/AgentRuntime/pi-entry.ts']
assert 'const capture = createPiCaptureAuthority();' in entry
assert "import { createPiCaptureProof } from './pi-capture-proof.mjs';" in entry
assert 'captureProof.open(identity, signal, () => nativeHost.open(identity, signal))' in entry
assert entry.index('captureProof.open(identity, signal, () => nativeHost.open(identity, signal))') < entry.index('await registration.ensureConnected();')
lease = entry[entry.index('const lease = await captureProof.open'):entry.index('  const interactive =')]
assert 'capture.clear()' not in lease
assert "if (ctx?.mode === 'tui') captureProof.reset();" in entry
assert 'registration.ensureConnected()' in entry
host = text['Shepherd/Agents/AgentRuntime/pi-host.mjs']
assert "control(bootstrapFile,'captureAck'" in host
proof = text['Shepherd/Agents/AgentRuntime/pi-capture-proof.mjs']
assert "acknowledged === true && generation === expectedGeneration" in proof
assert 'return open();' in proof
bridge = text['Shepherd/Agents/PiHostBridge.swift']
assert 'case "captureAck":' in bridge and 'Self.matches(identity, launch: launch, process: process)' in bridge
proxy = text['Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs']
assert 'export function createPiCaptureAuthority()' in proxy
assert "typeof sessionID==='string' && sessionID===session" in proxy
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
