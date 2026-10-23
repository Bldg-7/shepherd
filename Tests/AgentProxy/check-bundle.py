#!/usr/bin/env python3
"""The agent proxy as a built app carries it (SHPHRD-105), read from the
app's files without running anything in it:

  check-bundle.py --app <hrdrhrdrhrdr.app> --configuration Debug|Release [--team TEAM]

- Contents/MacOS/hrdrhrdrhrdr-agent-proxy: a signed Mach-O executable with
  every architecture the app's own executable has, linking no framework of
  the app's (the Swift packages it uses are linked into it, not loaded from
  the app's Frameworks), and the app's Frameworks holding no package
  framework Xcode would make if it linked them dynamically.
- Contents/Library/LaunchAgents: the configuration's LaunchAgent and no
  other, with the label, program, arguments and keys AgentProxyPaths and
  Config/LaunchAgents give it.
- With --team (the release script's exported app): signed by that team with
  the hardened runtime, as notarization requires.

Used by Tests/AgentProxy/run-app-tests.py on a Debug build and by
scripts/release-macos.sh on the exported release.
"""
import argparse, plistlib, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--app', type=Path, required=True)
p.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
p.add_argument('--team')
a = p.parse_args()
app = a.app.resolve()
problems = []


def expect(condition, message):
    if not condition:
        problems.append(message)
    return condition


paths = (ROOT / 'AgentProxy/Sources/AgentProxyProtocol/AgentProxyPaths.swift').read_text()
def constant(name):
    match = re.search(r'public static let ' + name + r' = "([^"]+)"', paths)
    assert match, f'AgentProxyPaths.{name}'
    return match.group(1)
label = constant('launchAgentLabel')
executable_name = constant('executableName')
folder = constant('applicationFolder')
if a.configuration == 'Debug':
    label += '.debug'
    state = constant('stateFolderName') + '-Debug'
    sock = constant('debugControlSocketName')
expected_files = [label + '.plist']

# The executable.
executable = app / 'Contents/MacOS' / executable_name
main = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
if expect(executable.is_file() and not executable.is_symlink(), f'{executable_name} is not in Contents/MacOS'):
    expect(executable.read_bytes()[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'), 'it is not a Mach-O executable')
    expect(executable.stat().st_mode & 0o111 == 0o111, 'it is not executable')
    archs = lambda f: set(subprocess.run(['lipo', '-archs', str(f)], capture_output=True, text=True, check=True, timeout=30).stdout.split())
    expect(archs(main) <= archs(executable), f'it lacks architectures the app has: {sorted(archs(main) - archs(executable))}')
    linked = subprocess.run(['otool', '-L', str(executable)], capture_output=True, text=True, check=True, timeout=30).stdout.splitlines()
    # A universal executable repeats the filename header for every architecture.
    # Ignore only those exact headers, never an arbitrary colon-ended dylib path.
    header = re.compile(re.escape(str(executable)) + r'(?: \(architecture [A-Za-z0-9_]+\))?:')
    own = [line.strip() for line in linked if line.strip() and not header.fullmatch(line.strip())
           and not re.match(r'\s*(/usr/lib/|/System/Library/)', line)]
    expect(not own, f'it loads libraries of its own: {own}')
    expect(subprocess.run(['codesign', '--verify', '--strict', str(executable)], capture_output=True, timeout=60).returncode == 0,
           'its signature does not verify')
    signature = subprocess.run(['codesign', '--display', '--verbose=2', str(executable)], capture_output=True, text=True, timeout=60).stderr
    if a.team:
        expect(f'TeamIdentifier={a.team}' in signature, f'it is not signed by team {a.team}')
        flags = re.search(r'flags=0x[0-9a-f]+\(([^)]*)\)', signature)
        expect(flags is not None and 'runtime' in flags.group(1).split(','), 'it is not signed with the hardened runtime')
frameworks = app / 'Contents/Frameworks'
packaged = sorted(f.name for f in frameworks.iterdir() if f.name.endswith('_PackageProduct.framework') or f.name.startswith(('NIO', 'CNIO', '_NIO'))) \
    if frameworks.is_dir() else []
expect(not packaged, f'the app carries package frameworks: {packaged}')

# The LaunchAgent.
agents = app / 'Contents/Library/LaunchAgents'
if expect(agents.is_dir(), 'Contents/Library/LaunchAgents is missing'):
    present = sorted(f.name for f in agents.iterdir())
    expect(present == expected_files, f'LaunchAgents holds {present}, not {expected_files}')
    plist_file = agents / expected_files[0]
    if plist_file.is_file():
        agent = plistlib.loads(plist_file.read_bytes())
        keys = {'Label', 'BundleProgram', 'RunAtLoad', 'KeepAlive', 'ThrottleInterval', 'StandardErrorPath'}
        if a.configuration == 'Debug':
            keys.add('ProgramArguments')
        expect(set(agent) == keys, f'its keys are {sorted(agent)}, not {sorted(keys)}')
        expect(agent.get('Label') == label, f'its label is {agent.get("Label")}, not {label}')
        expect(agent.get('BundleProgram') == 'Contents/MacOS/' + executable_name, 'its BundleProgram is not the executable')
        expect(agent.get('RunAtLoad') is True and agent.get('KeepAlive') is True, 'it is not RunAtLoad and KeepAlive')
        expect(agent.get('ThrottleInterval') == 1, 'its ThrottleInterval is not 1')
        expect(agent.get('StandardErrorPath') == '/dev/null', 'its standard error is not thrown away')
        if a.configuration == 'Debug':
            support = '~/Library/Application Support/' + folder
            expect(agent.get('ProgramArguments') == [executable_name, '--state-dir', support + '/' + state, '--control-socket', support + '/' + sock],
                   f'its ProgramArguments are {agent.get("ProgramArguments")}')
        source = ROOT / 'Config/LaunchAgents' / expected_files[0]
        expect(plistlib.loads(source.read_bytes()) == agent, f'it differs from {source.relative_to(ROOT)}')

if problems:
    print('agent proxy bundle check failed:\n- ' + '\n- '.join(problems), file=sys.stderr)
    sys.exit(1)
print(f'agent proxy bundle check passed ({a.configuration}{", team " + a.team if a.team else ""}): '
      f'{executable_name} and {expected_files[0]}')
