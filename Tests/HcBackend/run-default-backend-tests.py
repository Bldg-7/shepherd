#!/usr/bin/env python3
"""The product SDK's hc failure path at entry (no substitute backend), not deployment."""
from pathlib import Path
import argparse, hashlib, json, platform, subprocess, sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--products',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a = p.parse_args(); out = a.output.resolve(); out.mkdir(mode=0o700,parents=True,exist_ok=False)
for name in ['home','tmp','cache','fixture']: (out/name).mkdir(mode=0o700)
products = a.products.resolve()
tracked = ['Tests/HcBackend/HcDefaultBackendTests.swift','Tests/HcBackend/run-default-backend-tests.py']
tracked += [str(path.relative_to(ROOT)) for path in (ROOT/'ShepherdKit/Sources/ShepherdKit').rglob('*.swift')]
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def hashes(): return {name:digest(ROOT/name) for name in tracked}
before=hashes(); (out/'source-hashes.json').write_text(json.dumps(before,indent=2))
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),
     'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache'),
     'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer','LANG':'en_US.UTF-8'}
profile=out/'deny-network.sb'; profile.write_text('(version 1)\n(allow default)\n(deny network*)\n')
objects=sorted(products.glob('*.o')); object_hashes={str(path):digest(path) for path in objects}
(out/'product-hashes.json').write_text(json.dumps(object_hashes,indent=2))
assert objects and all((ROOT/name).stat().st_mtime <= (products/'ShepherdKit.o').stat().st_mtime for name in tracked if name.startswith('ShepherdKit/'))
maps=list((products.parents[2]/'Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'))
for base in [ROOT/'build/SourcePackages/checkouts',ROOT/'Vendor/Citadel',ROOT/'Vendor/swift-nio-ssh']:
    maps += [path for path in base.rglob('module.modulemap') if 'Benchmarks' not in path.parts]
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-warnings-as-errors','-parse-as-library',
       '-target',platform.machine()+'-apple-macos26.6.2','-I',str(products)]
for feature in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:
    flags += ['-enable-upcoming-feature',feature]
for module in maps: flags += ['-Xcc','-fmodule-map-file='+str(module)]
def stage(name,command):
    log=out/(name+'.log')
    subprocess.run([sys.executable,'-B',str(ROOT/'Tests/Support/run-stage.py'),'--timeout','120',
                    '--natural-exit-grace','10','--log',str(log),'--',*map(str,command)],cwd=ROOT,env=env,check=True,timeout=160)
    r=json.loads(log.with_suffix('.stage.json').read_text())
    assert r['naturalExitConfirmed'] and r['cleanupVerified'] and not r['signalsSent'], str(log)
for mode,extra in [('debug',['-D','DEBUG']),('release',['-O'])]:
    exe=out/('entry-'+mode)
    stage(mode+'-build',[*flags,*extra,'Tests/HcBackend/HcDefaultBackendTests.swift',*map(str,objects),
                        '-framework','AppKit','-framework','Security','-framework','CoreText','-framework','QuartzCore',
                        '-lz','-lsqlite3','-o',str(exe)])
    stage(mode+'-tests',['/usr/bin/sandbox-exec','-f',str(profile),str(exe),str(out/'fixture')])
assert before==hashes()
assert object_hashes=={name:digest(Path(name)) for name in object_hashes}
(out/'validation.json').write_text(json.dumps({'passed':True,'modes':['debug','release'],'checksPerMode':9,
    'failurePaths':'actual product SDK transport-start errors; pre-transport missing discovery is source-guarded','realCoreOrCLIOrUserCredential':False,
    'defaultRootSourceWiring':'separate guards','deploymentQualified':False},indent=2))
print('PASS default hc failure path:',out)
