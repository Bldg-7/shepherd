#!/usr/bin/env python3
"""Foundation-only Swift 6 gate: no core, SSH, sockets or user accounts."""
from pathlib import Path
import argparse, hashlib, json, os, re, subprocess, sys
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache']:(out/n).mkdir(mode=0o700)
sources=['ShepherdKit/Sources/ShepherdKit/CoreKit/CoreByteTransport.swift','ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/HerdrLineStream.swift','ShepherdKit/Sources/ShepherdKit/Conversations/ConversationLineConnection.swift','Tests/HcBackend/ConversationLineTests.swift']
hashes={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources}
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer','HOME':str(out/'home'),'CFFIXED_USER_HOME':str(out/'home'),'TMPDIR':str(out/'tmp'),'CLANG_MODULE_CACHE_PATH':str(out/'cache')}
flags=['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-parse-as-library','-warnings-as-errors']
for f in ['MemberImportVisibility','NonisolatedNonsendingByDefault','InferIsolatedConformances']:flags+=['-enable-upcoming-feature',f]
checks={}
for mode in ['debug','optimized']:
 exe=out/(mode+'-tests')
 for name,args,timeout in [(mode+'-build',flags+(['-O'] if mode=='optimized' else [])+sources+['-o',str(exe)],90),(mode,[str(exe)],45)]:
  log=out/(name+'.log')
  with log.open('wb') as f:r=subprocess.run(args,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=timeout)
  assert r.returncode==0,str(log)
  if name==mode:
   text=log.read_text();assert 'PASS independent conversation line transport:' in text
   checks[mode]=int(re.search(r'(\d+) checks',text)[1]);print(text.strip(),flush=True)
assert hashes=={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},'source changed during gate'
(out/'validation.json').write_text(json.dumps({'passed':True,'checks':checks,'sourcesUnchanged':True,'networkOrCoreUsed':False},indent=2))
print('PASS independent capture transport:',out,flush=True)
