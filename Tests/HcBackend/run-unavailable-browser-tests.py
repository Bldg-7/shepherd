#!/usr/bin/env python3
"""Actual unavailable product Debug/Release ABI; no app/core/service launch."""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tests/Terminal'))
from native_test_env import settings
from hc_release_bundle import check_no_cef_symbols
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,mode=0o700,exist_ok=False)
for name in ['home','tmp','cache']:(out/name).mkdir(mode=0o700)
env,sdk_flags=settings(out)
sources=['Shepherd/Browser/Engine/BrowserEngine.mm','Tests/HcBackend/HcUnavailableBrowserTests.mm']
tracked=[*sources,'Shepherd/Browser/Engine/BrowserEngine.h',str(Path(__file__).relative_to(ROOT))]
def hashes():return {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in tracked}
before=hashes();(out/'source-hashes.json').write_text(json.dumps(before,indent=2))
profile=out/'isolation.sb'
profile.write_text('(version 1)\n(allow default)\n(deny network*)\n(deny file-read* (subpath '+json.dumps(str(ROOT/'Vendor/CEF'))+'))\n')
def stage(name,command):
    log=out/(name+'.log')
    subprocess.run([sys.executable,'-B',str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout','90',
        '--natural-exit-grace','5','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,check=True,timeout=120)
    receipt=json.loads(log.with_suffix('.stage.json').read_text())
    assert receipt['naturalExitConfirmed'] and receipt['cleanupVerified'] and not receipt['signalsSent']
for name,flags in [('release',['-DNDEBUG=1']),('debug-zero',['-DDEBUG=0']),('product-debug',['-DDEBUG=1'])]:
    exe=out/('unavailable-'+name)
    stage(name+'-build',['/usr/bin/sandbox-exec','-f',profile,'xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks',
          '-Werror','-isysroot',sdk_flags[1],'-I',ROOT/'Shepherd/Browser/Engine',*flags,*sources,
          '-framework','AppKit','-o',exe])
    check_no_cef_symbols(exe)
    stage(name+'-tests',['/usr/bin/sandbox-exec','-f',profile,exe])
assert hashes()==before
(out/'validation.json').write_text(json.dumps({'passed':True,'checksPerMode':10,'modes':['release','debug-zero','product-debug'],
    'cefReadDenied':True,'cefSymbolsAbsent':True,'applicationCreated':False,'providerOrServiceUsed':False},indent=2))
print('PASS unavailable browser interface:',out)
