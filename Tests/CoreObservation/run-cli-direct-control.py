#!/usr/bin/env python3
"""Codex privacy-boundary control without hc. No prompts, login or user config."""
from pathlib import Path
import argparse,errno,fcntl,json,os,select,signal,subprocess,sys,termios,time
sys.dont_write_bytecode=True
import cli_isolation as isolation
p=argparse.ArgumentParser();p.add_argument('--inventory',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
m=json.loads((a.inventory.resolve()/'executables.json').read_text())
codex=Path(m['codex']['path']);node=Path(m['node']['path'])
if isolation.digest(codex)!=m['codex']['sha256']:raise ValueError('Codex changed')
home=out/'home';home.mkdir(mode=0o700);env=isolation.environment(home,node);work=home/'work';work.mkdir()
master,slave=os.openpty();tty=os.ttyname(slave)
fcntl.ioctl(slave,termios.TIOCSWINSZ,__import__('struct').pack('HHHH',32,100,0,0))
profile=out/'control.sb';profile.write_text(isolation.profile(out,[codex],[],tty_path=tty,missing_config_roots=['/etc/codex']))
def own_session():
    os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
child=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(profile),str(codex),'--no-daemon','--sandbox','read-only','--strict-config'],
    stdin=slave,stdout=slave,stderr=slave,cwd=work,env=env,preexec_fn=own_session,close_fds=True)
os.close(slave);data=bytearray();forced=False;tty_closed=False
try:
    deadline=time.monotonic()+8
    while time.monotonic()<deadline:
        if select.select([master],[],[],.1)[0]:
            try:
                part=os.read(master,65536)
                if not part:tty_closed=True;break
                data.extend(part)
                if len(data)>2<<20:raise RuntimeError('output limit')
                # A standard response only if the private CLI queries cursor position.
                if b'\x1b[6n' in part:os.write(master,b'\x1b[1;1R')
            except OSError as error:
                if error.errno==errno.EIO:tty_closed=True;break
                raise
        if child.poll() is not None:break
    if child.poll() is None:
        if not tty_closed:
            try:os.write(master,b'\x03\x03')
            except OSError as error:
                if error.errno!=errno.EIO:raise
        try:child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            forced=True;child.terminate()
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
    child.wait(timeout=3)
finally:
    os.close(master)
    if child.poll() is None:
        forced=True;child.kill();child.wait(timeout=3)
(out/'output.vt').write_bytes(data)
observed=b'Failed to synchronize managed preferences' in data
(out/'validation.json').write_text(json.dumps({'observationCompleted':True,'sameManagedPreferencesFailureWithoutHC':observed,
    'exitCode':child.returncode,'forced':forced,'childReaped':child.returncode is not None,
    'binarySHA256':isolation.digest(codex),'profileSHA256':isolation.digest(profile),'modelPrompts':0,'credentialsUsed':False},indent=2))
print('Direct owned PTY control:',out,'same failure:',observed)
if forced:raise SystemExit(1)
