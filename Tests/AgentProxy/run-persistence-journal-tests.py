#!/usr/bin/env python3
"""Offline, owned-fixture journal check; no package resolution or network."""
import argparse, hashlib, json, os, subprocess, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); args = p.parse_args()
out = args.output.resolve(); out.mkdir(mode=0o700)
for name in ('home', 'tmp', 'cache', 'work'): (out / name).mkdir(mode=0o700)
env = dict(os.environ, HOME=str(out/'home'), CFFIXED_USER_HOME=str(out/'home'), TMPDIR=str(out/'tmp'), CLANG_MODULE_CACHE_PATH=str(out/'cache'))
protocol = sorted((root/'AgentProxy/Sources/AgentProxyProtocol').glob('*.swift'))
core = sorted((root/'AgentProxy/Sources/AgentProxyCore').glob('*.swift'))
files = root/'AgentProxy/Sources/AgentProxyForwarder/ConversationPersistenceFiles.swift'
journal = root/'AgentProxy/Sources/AgentProxyForwarder/ConversationPersistenceJournal.swift'
tests = root/'Tests/AgentProxy/PersistenceJournalTests.swift'
stage_runner = root/'Tests/AgentBrowser/Phase2/run-stage.py'
inputs = protocol + core + [files, journal, tests, Path(__file__).resolve(), stage_runner]
assert all(x.is_file() for x in inputs)
manifest = {'gitRevision': subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip(),
            'inputs': {str(x.relative_to(root)): hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs},
            'recipe': 'python3 Tests/AgentProxy/run-persistence-journal-tests.py --output <new-0700-output>',
            'network': 'denied for compiler and runtime'}
(out/'frozen-inputs.json').write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
profile = out/'sandbox.sb'; profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
stages=[]
def stage(name, command, seconds=120):
    log=out/(name+'.log')
    result=subprocess.run([sys.executable,str(stage_runner),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*command],cwd=root,env=env,timeout=seconds+40)
    receipt=json.loads(log.with_suffix('.stage.json').read_text()); stages.append(receipt); (out/'stages.json').write_text(json.dumps(stages,indent=2)+'\n')
    if result.returncode or not receipt['naturalExitConfirmed'] or receipt['signalsSent'] or not receipt['cleanupVerified']: raise RuntimeError(name)
for name,opt in [('debug','-Onone'),('optimized','-O')]:
    build=out/name; build.mkdir(mode=0o700); common=['/usr/bin/sandbox-exec','-f',str(profile),'/usr/bin/xcrun','swiftc','-swift-version','5',opt,'-parse-as-library','-module-cache-path',str(out/'cache')]
    stage(name+'-protocol',common+['-emit-module','-emit-library','-module-name','AgentProxyProtocol','-emit-module-path',str(build/'AgentProxyProtocol.swiftmodule'),'-o',str(build/'libAgentProxyProtocol.dylib'),*map(str,protocol)])
    stage(name+'-core',common+['-emit-module','-emit-library','-module-name','AgentProxyCore','-I',str(build),'-L',str(build),'-lAgentProxyProtocol','-Xlinker','-rpath','-Xlinker',str(build),'-emit-module-path',str(build/'AgentProxyCore.swiftmodule'),'-o',str(build/'libAgentProxyCore.dylib'),*map(str,core)])
    binary=build/'PersistenceJournalTests'
    stage(name+'-build',common+['-I',str(build),'-L',str(build),'-lAgentProxyCore','-lAgentProxyProtocol','-Xlinker','-rpath','-Xlinker',str(build),'-o',str(binary),str(files),str(journal),str(tests)])
    stage(name+'-run',['/usr/bin/sandbox-exec','-f',str(profile),str(binary),str(out/'work'/name)],30)
print('PASS: journal Debug and optimized owned synthetic tests; network denied')
