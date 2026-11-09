#!/usr/bin/env python3
"""Explicitly authorized real CLI version/help probes, never a model prompt.
OS sandbox denies personal files, networking, credential brokers and external
process inspection; an inert canary checks the boundary before any CLI runs.
"""
from pathlib import Path
import argparse, json, os, shutil, socket, subprocess, sys, tempfile
sys.dont_write_bytecode=True
import cli_isolation as isolation
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
for name in ['claude','codex','pi','node']:p.add_argument('--'+name,type=Path,default=shutil.which(name))
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
paths={name:Path(getattr(a,name)).resolve(strict=True) for name in ['claude','codex','pi','node']}
packages=isolation.package_roots(paths['pi'])
executables=[paths['node'],paths['claude'],paths['codex']]
profile=out/'cli.sb';profile.write_text(isolation.profile(out,executables,packages))
home=out/'home';home.mkdir(mode=0o700)
env=isolation.environment(home,paths['node'])
work=home/'work';work.mkdir(mode=0o700)
manifest={name:{'path':str(path),'sha256':isolation.digest(path)} for name,path in paths.items()}
manifest['packages']=[{'path':str(q),'manifestSHA256':isolation.digest(q/'package.json')} for q in packages]
(out/'executables.json').write_text(json.dumps(manifest,indent=2))
probe=out/'probe.cjs'
shutil.copyfile(Path(__file__).with_name('cli-boundary-probe.cjs'),probe)
inside=home/'canary';inside.write_text('nonsecret-canary')
with tempfile.TemporaryDirectory(prefix='cli-denied-canary.') as d, socket.socket() as listener:
    outside=Path(d).resolve()/'canary';outside.write_text('nonsecret-canary')
    listener.bind(('127.0.0.1',0));listener.listen(1)
    result=subprocess.run(['/usr/bin/sandbox-exec','-f',str(profile),str(paths['node']),str(probe),str(inside),str(outside),str(listener.getsockname()[1])],
        cwd=work,env=env,capture_output=True,timeout=10,start_new_session=True)
    (out/'boundary-probe.log').write_bytes(result.stdout+result.stderr)
    if result.returncode or outside.read_text()!='nonsecret-canary':raise RuntimeError('sandbox boundary probe failed; no CLI started')
    boundary=json.loads(result.stdout)
    if not all(boundary.values()):raise RuntimeError('sandbox boundary not enforced')
(out/'boundary.json').write_text(json.dumps(boundary,indent=2))
# Prove the special missing-policy lookup rule with inert files, not /etc or
# personal policies. Existing regular files and symlink targets stay unreadable.
policy_probe=out/'cli-policy-probe.cjs';shutil.copyfile(Path(__file__).with_name('cli-policy-probe.cjs'),policy_probe)
with tempfile.TemporaryDirectory(prefix='cli-policy-canary.') as d:
    protected=Path(d).resolve();present=protected/'present';present.write_text('nonsecret-canary')
    (protected/'alias').symlink_to(present)
    policy=out/'missing-policy-probe.sb';policy.write_text(isolation.profile(out,executables,packages,missing_config_roots=[protected]))
    checked=subprocess.run(['/usr/bin/sandbox-exec','-f',str(policy),str(paths['node']),str(policy_probe),str(present),str(protected/'missing'),str(protected/'alias')],
        cwd=work,env=env,capture_output=True,timeout=10,start_new_session=True)
    (out/'missing-policy-probe.log').write_bytes(checked.stdout+checked.stderr)
    if checked.returncode:raise RuntimeError('policy guard failed; no CLI started')
    policy_guard=json.loads(checked.stdout)
records=[]
for name in ['claude','codex','pi']:
    base=[str(paths[name])] if name!='pi' else [str(paths['node']),str(paths['pi']),*isolation.PI_FLAGS]
    for option in ['--version','--help']:
        label=name+option;log=out/(label+'.log')
        command=['/usr/bin/sandbox-exec','-f',str(profile),*base,option]
        print(label+': start',flush=True)
        code=subprocess.run([sys.executable,str(ROOT/'Tests/Support/run-stage.py'),'--timeout','20','--natural-exit-grace','5',
            '--log',str(log),'--',*command],cwd=work,env=env,timeout=50).returncode
        record=json.loads(log.with_suffix('.stage.json').read_text())
        ok=code==0 and record['naturalExitConfirmed'] and not record['signalsSent'] and record['cleanupVerified']
        records.append({'name':label,'passed':ok,'exitCode':record.get('exitCode'),'log':log.name})
        print(label+(': passed' if ok else ': failed'),flush=True)
for name,path in paths.items():
    if isolation.digest(path)!=manifest[name]['sha256']:raise RuntimeError('executable changed during probe')
result={'passed':all(r['passed'] for r in records),'boundary':boundary,'records':records,'modelPrompts':0,
    'realCredentialsUsed':False,'parentDescriptorForwarded':False,'browserAuthorityGranted':False,
    'missingPolicyGuard':policy_guard,
    'sourceHashes':{name:isolation.digest(ROOT/'Tests/CoreObservation'/name) for name in ['cli_isolation.py','run-cli-inventory.py','cli-policy-probe.cjs','cli-boundary-probe.cjs']},
    'profileSHA256':isolation.digest(profile)}
(out/'validation.json').write_text(json.dumps(result,indent=2))
print('CLI inventory artifacts: '+str(out),flush=True)
if not result['passed']:raise SystemExit(1)
