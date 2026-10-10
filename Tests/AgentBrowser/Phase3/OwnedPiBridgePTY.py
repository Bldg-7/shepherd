#!/usr/bin/env python3
"""One owned Pi TUI, private configuration, no prompt/model request/global input."""
import errno, fcntl, json, os
from pathlib import Path
import select, signal, struct, subprocess, sys, termios, time
config=json.loads(Path(sys.argv[1]).read_text())
master,slave=os.openpty()
fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
config_home=Path(config['home']); agent=config_home/'pi-agent';agent.mkdir(mode=0o700)
env={'HOME':str(config_home),'PATH':str(Path(config['node']).parent)+':/usr/bin:/bin','TERM':'xterm-256color','LANG':'en_US.UTF-8',
     'PI_CODING_AGENT_DIR':str(agent),'PI_CODING_AGENT_SESSION_DIR':config['sessions'],'PI_OFFLINE':'1','PI_SKIP_VERSION_CHECK':'1',
     'PI_TELEMETRY':'0','PI_IMAGE_PROTOCOL':'none',
     'SHEPHERD_PI_FIXTURE_TRACE':str(Path(config['cwd'])/'trace.jsonl'),
     'OPENAI_API_KEY':'owned-synthetic-not-a-real-api-key'}
# The managed boot entry must supply its own bridge binding; do not mask a
# broken handoff by injecting it from the PTY driver.
if Path(config['entry']).name != 'pi-launch.mjs':env['SHEPHERD_PI_BRIDGE']=config['bootstrap']
def session():
 os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
child=subprocess.Popen([config['node'],config['entry'],*config['arguments']],stdin=slave,stdout=slave,stderr=slave,cwd=config['cwd'],env=env,preexec_fn=session)
os.close(slave)
identity=Path(config['pidFile']);identity.write_text(json.dumps({'pid':child.pid,'parentPID':os.getpid()}));identity.chmod(0o600)
log=bytearray();sent=False;forced=False;deadline=time.monotonic()+45
try:
 while child.poll() is None and time.monotonic()<deadline:
  if Path(config['stopFile']).exists() and not sent:
   # Only this owned master FD is written; never keyboard focus/global UI.
   os.write(master,b'\x04');sent=True
  readable,_,_=select.select([master],[],[],0.1)
  if readable:
   try:
    data=os.read(master,65536)
    if not data:break
    log.extend(data)
    if len(log)>2*1024*1024:raise RuntimeError('owned TUI output limit')
   except OSError as error:
    if error.errno==errno.EIO:break
    raise
 if child.poll() is None:
  try:child.wait(timeout=5)
  except subprocess.TimeoutExpired:
   forced=True;child.terminate()
   try:child.wait(timeout=5)
   except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
finally:
 os.close(master)
 if child.poll() is None:
  forced=True;child.terminate()
  try:child.wait(timeout=5)
  except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
Path(config['log']).write_bytes(log)
Path(config['result']).write_text(json.dumps({'pid':child.pid,'exitCode':child.returncode,'ctrlDSent':sent,'forced':forced,'modelPrompts':0}))
if child.returncode!=0 or forced or not sent:raise SystemExit(1)
print('PASS owned Pi TUI exit; no model prompt')
