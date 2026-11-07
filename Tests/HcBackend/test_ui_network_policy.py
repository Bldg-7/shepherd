#!/usr/bin/env python3
"""Actual SB grammar and scoped socket canaries; no app/core/credential use."""
from pathlib import Path
import errno,json,os,socket,subprocess,sys,tempfile
from ui_network_policy import policy
root=Path(tempfile.mkdtemp(prefix='hc-ui-network.',dir='/private/tmp')).resolve()
for n in ['a','b','outside','home']:(root/n).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin','HOME':str(root/'home'),'CFFIXED_USER_HOME':str(root/'home'),'TMPDIR':str(root/'home')}
checks=[]
def run(name,text,code,args=()):
 path=root/(name+'.sb');path.write_text(text)
 r=subprocess.run(['/usr/bin/sandbox-exec','-f',str(path),sys.executable,'-I','-c',code,*map(str,args)],env=env,capture_output=True,text=True,timeout=5)
 (root/(name+'.json')).write_text(json.dumps({'exitCode':r.returncode,'stderr':r.stderr,'stdout':r.stdout},indent=2))
 assert r.returncode==0,(name,r.stderr,r.stdout)
 checks.append(name)
with socket.socket() as allowed,socket.socket() as blocked:
 allowed.bind(('127.0.0.1',0));allowed.listen(1)
 blocked.bind(('127.0.0.1',0));blocked.listen(1)
 port=allowed.getsockname()[1];text=policy(root/'a',root/'b',port)
 run('allowed-owned-port',text,"import socket,sys\ns=socket.socket();s.connect(('127.0.0.1',int(sys.argv[1])));s.close()",[port])
 run('denied-other-local-port',text,"import socket,sys,errno\ns=socket.socket()\ntry:s.connect(('127.0.0.1',int(sys.argv[1])))\nexcept OSError as e:sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)",[blocked.getsockname()[1]])
for name in ['a','b','outside']:
 path=root/name/'c.sock'
 with socket.socket(socket.AF_UNIX) as listener:
  listener.bind(str(path));listener.listen(1)
  if name=='outside':code="import socket,sys,errno\ns=socket.socket(socket.AF_UNIX)\ntry:s.connect(sys.argv[1])\nexcept OSError as e:sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)\nsys.exit(1)"
  else:code="import socket,sys\ns=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.close()"
  run('unix-'+name,text,code,[path])
 path.unlink()
with socket.socket() as reserve:reserve.bind(('127.0.0.1',0));port=reserve.getsockname()[1]
run('owned-server-bind',policy(root/'a',root/'b',port),"import socket,sys\ns=socket.socket();s.bind(('127.0.0.1',int(sys.argv[1])));s.listen(1);s.close()",[port])
for port in [0,65536,True]:
 try:policy(root/'a',root/'b',port);raise AssertionError('invalid port admitted')
 except ValueError:checks.append('invalid-port')
(root/'validation.json').write_text(json.dumps({'passed':True,'checks':checks,'actualSandbox':True,'singleLoopbackPort':True,'guiOrCoreStarted':False},indent=2))
print('PASS',len(checks),'private UI network policy checks:',root)
