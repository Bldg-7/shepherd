#!/usr/bin/env python3
"""Build already-prepared, explicitly pinned passive-observer candidate sources.
No installer, daemon launch, user credentials or global toolchain changes.
"""
from pathlib import Path
import argparse
import json
import platform
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import candidate_artifact as artifact
p = argparse.ArgumentParser()
p.add_argument('--workspace', type=Path, required=True)
p.add_argument('--tools-workspace', type=Path, help='isolated compiler/cache directory; defaults to workspace')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root, out = a.workspace.resolve(), a.output.resolve()
tools = a.tools_workspace.resolve() if a.tools_workspace else root
artifact.require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'macOS ARM64 required')
r = artifact.verify_sources(root)
_, base = artifact.recipes()
builder_hash, validator_hash = artifact.digest(Path(__file__).resolve()), artifact.digest(Path(artifact.__file__))
cargo_dir = tools/'rustup-home/toolchains/1.95.0-aarch64-apple-darwin/bin'
zig = tools/'zig-aarch64-macos-0.16.0/zig'
artifact.require(artifact.digest(zig) == base['zigBinarySHA256'], 'wrong Zig binary')
out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','state','config']:
    (root/name).mkdir(mode=0o700,exist_ok=True)
env = {'PATH':str(cargo_dir)+':/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(root/'home'),'TMPDIR':str(root/'tmp'),
       'CARGO_HOME':str(tools/'cargo-home'),'CARGO_TARGET_DIR':str(root/'target'),'CARGO_BUILD_JOBS':'4','RUSTC':str(cargo_dir/'rustc'),
       'ZIG_GLOBAL_CACHE_DIR':str(tools/'zig-global-cache'),'XDG_STATE_HOME':str(root/'state'),
       'XDG_CONFIG_HOME':str(root/'config'),'HC_SESSION':'parity','CI':'1','DO_NOT_TRACK':'1'}
import shlex
wrapper = out/'zig-wrapper'
wrapper.write_text('#!/bin/sh\nset -eu\nif [ "${1:-}" = build ]; then\n shift\n exec '+shlex.quote(str(zig))+' build '+
                   ' '.join(map(shlex.quote,base['zigBuildOptions']))+' "$@"\nfi\nexec '+shlex.quote(str(zig))+' "$@"\n')
wrapper.chmod(0o700); env['ZIG']=str(wrapper)
versions = {'rustc':subprocess.check_output([str(cargo_dir/'rustc'),'--version'],env=env,text=True).strip(),
            'zig':subprocess.check_output([str(zig),'version'],env=env,text=True).strip(),
            'zigSHA256':artifact.digest(zig),'rustcSHA256':artifact.digest(cargo_dir/'rustc'),'cargoSHA256':artifact.digest(cargo_dir/'cargo')}
artifact.require(versions['rustc'].startswith('rustc 1.95.0 ') and versions['zig']==base['zigVersion'],'wrong compiler versions')
checks = {}
def stage(name, cwd, args):
    print(name+': start',flush=True)
    log = out/(name+'.log')
    with log.open('wb') as f:
        result = subprocess.run(list(map(str,args)),cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=1200)
    passed = result.returncode == 0; count = None
    if name in {'formatter-tests','core-library-tests','vt-library-tests'}:
        pattern = r'([0-9]+)/[0-9]+ tests passed' if name=='formatter-tests' else r'test result: ok\. ([0-9]+) passed'
        counts = re.findall(pattern,log.read_text()); count=int(counts[-1]) if counts else 0
        passed = passed and count > 0
    checks[name]={'passed':passed,'testCount':count,'logSHA256':artifact.digest(log),'command':list(map(str,args))}
    (out/'checks.json').write_text(json.dumps(checks,indent=2))
    artifact.require(passed,'failed stage: '+str(log))
    print(name+': passed',flush=True)
core=root/'core'; ghostty=core/'vendor/ghostty'; cargo=cargo_dir/'cargo'
stage('formatter-format',ghostty,[zig,'fmt','--check','src/terminal/formatter.zig'])
stage('formatter-tests',ghostty,[wrapper,'build','test-lib-vt','-Demit-lib-vt','-Dtest-filter=formatter','--cache-dir',root/'formatter-cache','--prefix',root/'formatter-out','--summary','all'])
stage('build',core,[cargo,'build','--locked','--release','-p','herdr-core'])
stage('core-library-tests',core,[cargo,'test','--locked','--release','-p','herdr-core','--lib','--','--test-threads=1'])
stage('vt-library-tests',core,[cargo,'test','--locked','--release','-p','ghostty-vt','--lib'])
stage('notices',core,[core/'scripts/notices'])
artifact.verify_sources(root) # notices must remain unchanged too
artifact.require(builder_hash==artifact.digest(Path(__file__).resolve()) and validator_hash==artifact.digest(Path(artifact.__file__)),'build procedure changed while running')
with (root/'target/release/herdr-core').open('rb') as source, (out/'herdr-core').open('xb') as destination:
    shutil.copyfileobj(source,destination)
(out/'herdr-core').chmod(0o700)
for source, name in [(core/'LICENSE','CORE-LICENSE'),(core/'crates/herdr-core/THIRD-PARTY-NOTICES','THIRD-PARTY-NOTICES'),
                     (artifact.BASE.parent/'GHOSTTY-LICENSE','GHOSTTY-LICENSE')]:
    shutil.copyfile(source,out/name)
receipt={'schema':1,'variant':r['variant'],'officialRelease':False,'recipeSHA256':artifact.digest(artifact.RECIPE),
         'builderSHA256':builder_hash,'validatorSHA256':validator_hash,'binary':'herdr-core','binarySHA256':artifact.digest(out/'herdr-core'),
         'toolchain':versions,'checks':checks,'fullAgentParityQualified':False,'independentSignatureVerified':False}
(out/'candidate-receipt.json').write_text(json.dumps(receipt,indent=2))
print('PASS pinned candidate build, NOT full agent parity: '+str(out/'candidate-receipt.json'),flush=True)
