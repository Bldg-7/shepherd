import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync,spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {shellTokens,childCommand,quote,sessionName,injected,mergedInstructions,readCodex,resume,validateEndpoint,atomicWrite,detect,requireNode,nodeSupported} from '../../../Shepherd/Agents/AgentRuntime/runtime-core.mjs';
import {install,prepare,rewrite,cleanup,setMode,checkScope,registerPane,setupCodex,reserveLaunch,discardReservation,withLock} from '../../../Shepherd/Agents/AgentRuntime/runtime.mjs';
let checks=0;const check=(name,operation)=>{operation();checks++;console.log('PASS',name);};
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'shepherd-runtime-unit-'));
try {
 const root=path.join(directory,'runtime');const home=path.join(directory,'home');fs.mkdirSync(home,{mode:0o700});
 const codexHome=path.join(home,'.codex');fs.mkdirSync(codexHome,{mode:0o700});
 const claudeDir=path.join(home,'.claude');fs.mkdirSync(claudeDir,{mode:0o700});
 const environment={PATH:process.env.PATH,HOME:home,CODEX_HOME:codexHome,CLAUDE_CONFIG_DIR:claudeDir,TERM:'dumb'};
 for(const key of Object.keys(process.env)) delete process.env[key];Object.assign(process.env,environment);
 const claudeSettingsFile=path.join(claudeDir,'.claude.json');fs.writeFileSync(claudeSettingsFile,'{"userSetting":"preserve"}',{mode:0o600});
 const executable=path.join(directory,"CLI with 'quotes'");fs.writeFileSync(executable,'#!/bin/sh\nif [ "$*" = "plugin marketplace add --help" ]; then echo "local path"; exit 0; fi\ncase "$1" in --version) echo "fixture CLI 1.0";; --help) echo "--plugin-dir --config";; *) exit 1;; esac\n',{mode:0o700});
 const token=path.join(directory,'token');fs.writeFileSync(token,crypto.randomBytes(32).toString('base64'),{mode:0o600});
 const pane={machineID:'owned-machine',herdrMachineID:null,session:'owned session',paneID:'w1:p1',terminalID:'term-owned'};
 const endpoint={origin:'thisMac',url:'ws://127.0.0.1:19433/v1/herdr/owned%20session/pane/w1:p1',tokenFile:token};
 const request={root,kind:'claude',executable,pane,endpoint,codexHome,claudeSettingsFile};
 for(const command of ['herdr agent start name --kind claude --pane w1:p1','herdr agent start \'two words\' --pane w1:p1 --kind codex -- \'--prompt=hello world\'']) check('literal child grammar '+command,()=>assert(childCommand(command)));
 for(const command of ['herdr agent start n --kind claude --pane w1:p1 && echo x','herdr agent start n --kind claude --pane w1:p1\necho x','herdr agent start "$NAME" --kind claude --pane w1:p1','herdr agent start `whoami` --kind claude --pane w1:p1','herdr --machine remote agent start n --kind claude --pane w1:p1','herdr pane run w1:p1 "claude"','herdr agent start n --kind claude --pane w1:p1 > file','herdr agent start n --kind claude --kind codex --pane w1:p1','herdr agent start n --kind claude --pane bad','herdr agent start n --kind claude --pane w1:p1 --timeout nope']) check('unsupported child unchanged '+command.replaceAll('\n','\\n'),()=>assert.equal(childCommand(command),null));
 for(const id of ['wE:p1C','w1P:pB','w1:pD']) check('opaque alphanumeric pane ID '+id,()=>assert.equal(childCommand('herdr agent start n --kind claude --pane '+id)?.pane,id));
 for(const value of ["'wE:p1C;rm'",'wE:p1C;rm','../x',"''",'w:p1','wE:p','wE:p1C:x',"'wE:p1C '","'wÉ:p1'"]) check('malformed pane ID unchanged '+value,()=>assert.equal(childCommand('herdr agent start n --kind claude --pane '+value),null));
 check('shell quote round trip',()=>{const values=["a'b",'spaces here','literal $value','back\\slash',''];assert.deepEqual(shellTokens(values.map(quote).join(' ')),values);});
 check('unterminated quote fails',()=>assert.equal(shellTokens("'unterminated"),null));
 check('session from named socket',()=>assert.equal(sessionName('/tmp/sessions/owned/herdr.sock'),'owned'));
 check('default socket',()=>assert.equal(sessionName('/tmp/herdr.sock'),'default'));
 check('MCP endpoint pane match',()=>validateEndpoint(endpoint,pane));
 check('no remote Mac-network fallback',()=>assert.throws(()=>validateEndpoint({...endpoint,origin:'ssh'},pane),/remote-unavailable/));
 check('pane mismatch rejects',()=>assert.throws(()=>validateEndpoint(endpoint,{...pane,paneID:'w1:p2'}),/pane-endpoint-mismatch/));
 check('token reference symlink rejects',()=>{fs.symlinkSync(token,token+'.link');assert.throws(()=>validateEndpoint({...endpoint,tokenFile:token+'.link'},pane));});
 check('token reference permissions reject',()=>{fs.chmodSync(token,0o644);assert.throws(()=>validateEndpoint(endpoint,pane),/unsafe-token-reference/);fs.chmodSync(token,0o600);});
 check('actual script RPC rejection carries typed error without false success',()=>{const script=fileURLToPath(new URL('../../../Shepherd/Agents/AgentRuntime/runtime.mjs',import.meta.url));const output=execFileSync(process.execPath,[script],{input:JSON.stringify({...request,root:path.join(directory,'not-installed'),action:'prepare'}),encoding:'utf8',timeout:10000,killSignal:'SIGKILL'});assert.deepEqual(JSON.parse(output),{ok:false,error:'not-installed'});});
 check('Node20 minimum matches pinned dependency engines',()=>{assert(!nodeSupported('18.20.0'));assert(!nodeSupported('19.9.0'));assert(nodeSupported('20.0.0'));assert.throws(()=>requireNode('18.20.0'),/node-version-unsupported/);});
 check('old Node readiness and prepare/install reject before side effects',()=>{const descriptor=Object.getOwnPropertyDescriptor(process.versions,'node');Object.defineProperty(process.versions,'node',{...descriptor,value:'18.20.0'});try{assert.equal(detect('claude',executable).readiness,'unsupportedPrerequisite');const target=path.join(directory,'old-node-root');assert.throws(()=>install({root:target}),/node-version-unsupported/);assert.throws(()=>prepare({...request,root:target}),/node-version-unsupported/);assert(!fs.existsSync(target));}finally{Object.defineProperty(process.versions,'node',descriptor);}});
 check('missing CLI readiness',()=>assert.equal(detect('claude',path.join(directory,'no-cli')).readiness,'missing'));
 check('atomic local installation',()=>assert.match(install({root}).version,/^2.0.0-/));
 const preimage=fs.readFileSync(path.join(root,'installation.json'));
 check('idempotent install',()=>{install({root});assert.deepEqual(fs.readFileSync(path.join(root,'installation.json')),preimage);});
 check('failed atomic rename preserves existing target',()=>{const target=path.join(root,'not-file');fs.mkdirSync(target);assert.throws(()=>atomicWrite(target,'replacement'));assert(fs.statSync(target).isDirectory());assert(!fs.readdirSync(root).some(n=>n.startsWith('.new-')));});
 check('immutable copied dependency links remain relative',()=>{const installed=JSON.parse(fs.readFileSync(path.join(root,'installation.json'),'utf8'));assert(!path.isAbsolute(fs.readlinkSync(path.join(installed.resourceDirectory,'node_modules','.bin','playwright-mcp'))));});
 check('concurrent setup lock fails closed, keeping an older version\'s .lock folder made this boot',()=>{const lock=path.join(root,'.lock');fs.mkdirSync(lock);assert.throws(()=>install({root}),/setup-busy/);assert(fs.lstatSync(lock).isDirectory());fs.rmdirSync(lock);assert.deepEqual(fs.readFileSync(path.join(root,'installation.json')),preimage);});
 // The runtime lock across processes and versions (withLock), each case in its
 // own root. Every child and grandchild started here has exited when it ends.
 {
 const runtimeURL=new URL('../../../Shepherd/Agents/AgentRuntime/runtime.mjs',import.meta.url),runtimeScript=fileURLToPath(runtimeURL);
 const busy=/setup-busy/,lockFailed=/runtime-lock-failed/;
 const children=new Set(),grandchildren=new Set();
 const alive=pid=>{try{process.kill(pid,0);return true;}catch(error){return error.code !== 'ESRCH';}};
 const exited=child=>child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise(resolve=>child.once('exit',resolve));
 const gone=async pid=>{for(let i=0;i<100 && alive(pid);i++) await new Promise(resolve=>setTimeout(resolve,50));return !alive(pid);};
 const checkAsync=async(name,operation)=>{await operation();checks++;console.log('PASS',name);};
 let roots=0;const lockRoot=()=>{const r=path.join(directory,'lock-'+(++roots));fs.mkdirSync(r,{mode:0o700});return r;};
 const lockOf=r=>path.join(r,'.lock'),absent=file=>fs.lstatSync(file,{throwIfNoEntry:false}) === undefined;
 // This version holding the lock until killed; with 'detach' it first starts a
 // detached /bin/sleep that outlives it.
 const holderSource=`import fs from 'node:fs';import {spawn} from 'node:child_process';import {withLock} from ${JSON.stringify(runtimeURL.href)};
const [root,detach]=process.argv.slice(1);
withLock(root,()=>{let child=0;if(detach){const c=spawn('/bin/sleep',['60'],{detached:true,stdio:'ignore'});c.unref();child=c.pid;}
fs.writeSync(1,JSON.stringify({child})+'\\n');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0);});`;
 const holder=async(r,detach=false)=>{
  const child=spawn(process.execPath,['--input-type=module','-e',holderSource,r,...(detach?['detach']:[])],{stdio:['ignore','pipe','inherit']});children.add(child);
  const line=await new Promise((resolve,reject)=>{let text='';child.stdout.on('data',d=>{text+=d;if(text.includes('\n')) resolve(text);});child.once('exit',()=>reject(new Error('holder exited before holding')));});
  const {child:grandchild}=JSON.parse(line);if(grandchild) grandchildren.add(grandchild);
  return {child,grandchild};
 };
 const stop=async(child,signal)=>{child.kill(signal);await exited(child);children.delete(child);return child.signalCode;};
 // A worker of this version (withLock) or of an older one (mkdir .lock, as
 // before this change) entering a critical section until `until`. Finding
 // another worker inside counts as a violation.
 const workerSource=`import fs from 'node:fs';import path from 'node:path';import {withLock} from ${JSON.stringify(runtimeURL.href)};
const [root,kind,until]=process.argv.slice(1);const lock=path.join(root,'.lock'),inside=path.join(root,'inside');
const pause=ms=>Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,ms);
const result={kind,held:0,busy:0,violations:0,failed:[]};
const critical=()=>{let fd;try{fd=fs.openSync(inside,'wx');}catch(error){if(error.code !== 'EEXIST') throw error;result.violations++;return;}
fs.closeSync(fd);pause(Math.random()*2);fs.unlinkSync(inside);result.held++;};
while(Date.now() < Number(until)) {
 if(kind === 'new') {try{withLock(root,critical);}catch(error){if(error.code === 'setup-busy') result.busy++;else result.failed.push(String(error.code ?? error.message));}}
 else {let made=false;try{fs.mkdirSync(lock,{mode:0o700});made=true;}catch{result.busy++;}if(made) try{critical();}finally{fs.rmdirSync(lock);}}
 pause(Math.random());
}
fs.writeSync(1,JSON.stringify(result)+'\\n');`;
 const rpc=r=>JSON.parse(execFileSync(process.execPath,[runtimeScript],{input:JSON.stringify({action:'reserveLaunch',root:r}),encoding:'utf8',timeout:10000,killSignal:'SIGKILL'}));
 try {
  await checkAsync('a live holder keeps the lock: setup-busy without running the action, and its .lock stays',async()=>{
   const r=lockRoot();const {child}=await holder(r);
   let ran=false;assert.throws(()=>withLock(r,()=>{ran=true;}),busy);assert(!ran);assert(fs.lstatSync(lockOf(r)).isFile());
   await stop(child,'SIGKILL');
  });
  for(const signal of ['SIGKILL','SIGTERM']) await checkAsync(`a holder ended by ${signal} leaves .lock, and the next action takes the lock and removes it`,async()=>{
   const r=lockRoot();const {child}=await holder(r);
   assert.equal(await stop(child,signal),signal);assert(fs.lstatSync(lockOf(r)).isFile());
   let ran=false;withLock(r,()=>{ran=true;});assert(ran);assert(absent(lockOf(r)));
  });
  await checkAsync('a detached child of a killed holder does not keep the lock',async()=>{
   const r=lockRoot();const {child,grandchild}=await holder(r,true);
   assert(grandchild > 0 && alive(grandchild));await stop(child,'SIGKILL');assert(alive(grandchild));
   let ran=false;withLock(r,()=>{ran=true;});assert(ran);assert(absent(lockOf(r)));
   process.kill(grandchild,'SIGKILL');assert(await gone(grandchild));grandchildren.delete(grandchild);
  });
  await checkAsync('mixed contention: workers of this version and older mkdir workers never share the critical section',async()=>{
   const r=lockRoot();const until=Date.now()+2500;
   const results=await Promise.all([...Array(4).fill('new'),...Array(2).fill('old')].map(kind=>{
    const child=spawn(process.execPath,['--input-type=module','-e',workerSource,r,kind,String(until)],{stdio:['ignore','pipe','inherit']});children.add(child);
    let text='';child.stdout.on('data',d=>{text+=d;});
    return new Promise(resolve=>child.once('close',resolve)).then(()=>{children.delete(child);assert.equal(child.exitCode,0);return JSON.parse(text);});
   }));
   const sum=(kind,key)=>results.filter(w=>w.kind === kind).reduce((n,w)=>n+w[key],0);
   const totals={newHeld:sum('new','held'),newBusy:sum('new','busy'),oldHeld:sum('old','held'),oldBusy:sum('old','busy'),violations:sum('new','violations')+sum('old','violations'),failed:results.flatMap(w=>w.failed)};
   console.log('contention',JSON.stringify(totals));
   assert.equal(totals.violations,0);assert.deepEqual(totals.failed,[]);
   assert(totals.newHeld > 0 && totals.oldHeld > 0 && totals.newBusy > 0 && totals.oldBusy > 0);
   assert.deepEqual(fs.readdirSync(r),[]);withLock(r,()=>{});
  });
  check('by default an older version\'s .lock folder made this boot stays, and one made before boot is removed',()=>{
   const fresh=lockRoot();fs.mkdirSync(lockOf(fresh));assert.throws(()=>withLock(fresh,()=>{}),busy);assert(fs.lstatSync(lockOf(fresh)).isDirectory());
   const old=lockRoot();fs.mkdirSync(lockOf(old));const past=new Date(Date.UTC(2000,0,1));fs.utimesSync(lockOf(old),past,past);
   assert(fs.lstatSync(lockOf(old)).birthtimeMs < Date.now()-os.uptime()*1000,'APFS moves the birth time back with an earlier modification time');
   let ran=false;withLock(old,()=>{ran=true;});assert(ran);assert(absent(lockOf(old)));
  });
  check('an older version\'s .lock folder is removed only when predatesBoot answers true',()=>{
   for(const answer of [()=>null,()=>false,()=>undefined,()=>1,()=>{throw new Error('unreadable');}]) {
    const r=lockRoot();fs.mkdirSync(lockOf(r));let ran=false;
    assert.throws(()=>withLock(r,()=>{ran=true;},{predatesBoot:answer}),busy);assert(!ran);assert(fs.lstatSync(lockOf(r)).isDirectory());
   }
   const r=lockRoot();fs.mkdirSync(lockOf(r));let seen,ran=false;
   withLock(r,()=>{ran=true;assert(fs.lstatSync(lockOf(r)).isFile());},{predatesBoot:stat=>{seen=stat;return true;}});
   assert(ran && seen.isDirectory());assert(absent(lockOf(r)));
   const full=lockRoot();fs.mkdirSync(lockOf(full));fs.writeFileSync(path.join(lockOf(full),'owner'),'');
   assert.throws(()=>withLock(full,()=>{},{predatesBoot:()=>true}),lockFailed);assert(fs.existsSync(path.join(lockOf(full),'owner')));
  });
  check('a root that cannot hold .lock, or a .lock of another kind, fails with runtime-lock-failed and lets go of the root',()=>{
   const readOnly=lockRoot();fs.chmodSync(readOnly,0o500);
   try {assert.throws(()=>withLock(readOnly,()=>{}),lockFailed);assert.deepEqual(fs.readdirSync(readOnly),[]);} finally {fs.chmodSync(readOnly,0o700);}
   withLock(readOnly,()=>{});
   const linked=lockRoot();fs.symlinkSync(directory,lockOf(linked));
   assert.throws(()=>withLock(linked,()=>{}),lockFailed);assert(fs.lstatSync(lockOf(linked)).isSymbolicLink());
   fs.unlinkSync(lockOf(linked));withLock(linked,()=>{});
  });
  await checkAsync('the runtime script returns setup-busy and runtime-lock-failed as typed rejections',async()=>{
   const r=lockRoot();const {child}=await holder(r);
   assert.deepEqual(rpc(r),{ok:false,error:'setup-busy'});await stop(child,'SIGKILL');assert.equal(rpc(r).ok,true);
   const linked=lockRoot();fs.symlinkSync(directory,lockOf(linked));assert.deepEqual(rpc(linked),{ok:false,error:'runtime-lock-failed'});
  });
  check('an action that throws lets go of the lock and its error reaches the caller',()=>{
   const r=lockRoot(),failure=new Error('action failed');
   assert.throws(()=>withLock(r,()=>{throw failure;}),error=>error === failure);
   assert(absent(lockOf(r)));let ran=false;withLock(r,()=>{ran=true;});assert(ran);
  });
  check('while the lock is held, .lock is a 0600 file, an older version\'s mkdir fails with EEXIST, and a nested withLock with setup-busy',()=>{
   const r=lockRoot();
   withLock(r,()=>{
    const stat=fs.lstatSync(lockOf(r));assert(stat.isFile() && (stat.mode & 0o777) === 0o600);
    assert.throws(()=>fs.mkdirSync(lockOf(r),{mode:0o700}),{code:'EEXIST'});
    assert.throws(()=>withLock(r,()=>{}),busy);assert(fs.lstatSync(lockOf(r)).isFile());
   });
   assert(absent(lockOf(r)));
  });
 } finally {
  for(const child of children) {child.kill('SIGKILL');await exited(child);}
  for(const pid of grandchildren) if(alive(pid)) {process.kill(pid,'SIGKILL');await gone(pid);}
 }
 }
 const config='developer_instructions = "Keep user instructions"\n[mcp_servers.chrome]\ncommand = "owned-command"\n[profiles.legacy]\ndeveloper_instructions = "Legacy profile"\n';fs.writeFileSync(path.join(codexHome,'config.toml'),config,{mode:0o600});
 fs.writeFileSync(path.join(codexHome,'work.config.toml'),'developer_instructions = """Named profile\nmultiline"""\nmodel = "owned-model"\n',{mode:0o600});
 check('base instructions merge',()=>assert.match(mergedInstructions(readCodex(codexHome)),/^Keep user instructions\n\nFor web pages/));
 check('v2 profile instructions merge',()=>assert.match(mergedInstructions(readCodex(codexHome,'work')),/^Named profile\nmultiline\n\nFor web pages/));
 check('legacy profile merge',()=>assert.match(mergedInstructions(readCodex(codexHome,'legacy')),/^Legacy profile/));
 check('unknown profile rejects',()=>assert.throws(()=>readCodex(codexHome,'absent'),/missing-profile/));
 check('global Codex plugin setup rejected without writes or CLI execution',()=>{assert.throws(()=>setupCodex({root,codexHome,executable}),/session-only-policy/);assert.equal(fs.readFileSync(path.join(codexHome,'config.toml'),'utf8'),config);assert.deepEqual(fs.readFileSync(path.join(root,'installation.json')),preimage);assert(!fs.readdirSync(root).some(n=>n.startsWith('.codex-')));});
 check('scope inspection is read-only and accepts no global registration',()=>assert.deepEqual(checkScope(request),{sessionOnly:true}));
 for(const parent of [path.join(home,'.agents','skills'),path.join(claudeDir,'skills'),path.join(codexHome,'skills')]) check('legacy global skill rejected without removing it: '+parent,()=>{
  const skill=path.join(parent,'shepherd-browser');fs.mkdirSync(skill,{recursive:true});fs.writeFileSync(path.join(skill,'SKILL.md'),'preserve user installation');
  assert.throws(()=>checkScope(request),/legacy-global-skill-present/);
  assert.throws(()=>prepare(request),/legacy-global-skill-present/);
  assert.equal(fs.readFileSync(path.join(skill,'SKILL.md'),'utf8'),'preserve user installation');fs.rmSync(skill,{recursive:true});
 });
 check('legacy global runtime cannot be silently migrated',()=>{
  const file=path.join(root,'installation.json');const saved=fs.readFileSync(file);const legacy=JSON.stringify({...JSON.parse(saved),mode:'global'});fs.writeFileSync(file,legacy);
  try{assert.throws(()=>install({root}),/legacy-global-registration-present/);assert.equal(fs.readFileSync(file,'utf8'),legacy);}finally{fs.writeFileSync(file,saved);}
 });
 const oldCLI=path.join(directory,'old-cli');fs.writeFileSync(oldCLI,'#!/bin/sh\necho old-agent\n',{mode:0o700});
 check('old CLI fails explicitly',()=>assert.throws(()=>prepare({...request,executable:oldCLI}),/cli-unsupported/));
 const reserved=reserveLaunch({root});
 check('reservation environment before pane creation has no token',()=>{assert(!fs.existsSync(reserved.environment.SHEPHERD_AGENT_SESSION));assert(!JSON.stringify(reserved).includes(fs.readFileSync(token,'utf8')));});
 const reservedLaunch=prepare({...request,reservationID:reserved.reservationID});
 check('reservation binds actual pane without changing environment',()=>assert.deepEqual(reservedLaunch.environment,reserved.environment));
 check('prepared reservation cannot be reused/discarded',()=>{assert.throws(()=>prepare({...request,reservationID:reserved.reservationID}),/reservation-already-prepared/);assert.throws(()=>discardReservation({root,reservationID:reserved.reservationID}),/reservation-already-prepared/);});
 const abandoned=reserveLaunch({root});
 check('unbound reservation owned cleanup',()=>{discardReservation({root,reservationID:abandoned.reservationID});assert(!fs.existsSync(path.dirname(abandoned.environment.SHEPHERD_AGENT_SESSION)));});
 const launch=prepare(request);
 check('immutable prepared pane-specific plugin',()=>{assert.equal(launch.injection,'plugin');assert(launch.arguments.includes(launch.pluginDirectory));assert.equal(launch.outputFolder,path.join(path.dirname(launch.sessionFolder),'output'));});
 check('descriptor no token bytes',()=>assert(!fs.readFileSync(path.join(launch.sessionFolder,'session.json'),'utf8').includes(fs.readFileSync(token,'utf8'))));
 process.env.HERDR_SOCKET_PATH='/tmp/sessions/owned session/herdr.sock';
 check('registry-only child never appends stale selected-profile/override instructions',()=>{prepare({...request,kind:'codex',arguments:['-p','work']});for(const tail of ['-p legacy','-c \'developer_instructions="Child text"\'']){const command='herdr agent start child --kind codex --pane w1:p1 -- '+tail;const result=rewrite(command,root);assert.equal(result.command,command);assert.equal(result.reason,'fresh-child-context-unavailable');assert(!result.rewritten);}});
 registerPane({...request,executables:{claude:executable,codex:executable}});
 check('hook registered child injection',()=>{const result=rewrite('herdr agent start child --kind claude --pane w1:p1',root);assert(result.rewritten);const fresh=JSON.parse(fs.readFileSync(path.join(root,'panes.json'),'utf8')).find(p=>p.kind==='claude' && p.pane.paneID==='w1:p1');assert(shellTokens(result.command).includes(fresh.pluginDirectory));assert.notEqual(fresh.pluginDirectory,launch.pluginDirectory);assert(!result.command.includes(fs.readFileSync(token,'utf8')));});
 check('hook registered child injection with alphanumeric pane ID',()=>{registerPane({...request,pane:{...pane,paneID:'wE:p1C',terminalID:'term-alphanumeric'},endpoint:{...endpoint,url:endpoint.url.replace('w1:p1','wE:p1C')},executables:{claude:executable}});const result=rewrite('herdr agent start child --kind claude --pane wE:p1C',root);assert(result.rewritten);const fresh=JSON.parse(fs.readFileSync(path.join(root,'panes.json'),'utf8')).find(p=>p.kind==='claude' && p.pane.paneID==='wE:p1C');assert(shellTokens(result.command).includes(fresh.pluginDirectory));});
 check('lazy registered child prepare merges own arguments',()=>{registerPane({...request,pane:{...pane,paneID:'w1:p3',terminalID:'term-child'},endpoint:{...endpoint,url:endpoint.url.replace('w1:p1','w1:p3')},executables:{codex:executable}});const result=rewrite('herdr agent start child --kind codex --pane w1:p3 -- -p work',root);assert(result.rewritten);assert(result.command.includes('Named profile'));assert(result.command.includes('mcp_servers.shepherd-browser.args='));});
 check('endpoint child profile/override is freshly merged instead of previous launch instructions',()=>{for(const tail of ['-p legacy','-c \'developer_instructions="Child text"\'']){const result=rewrite('herdr agent start child --kind codex --pane w1:p3 -- '+tail,root);assert(result.rewritten);assert(result.command.includes(tail.includes('legacy')?'Legacy profile':'Child text'));assert(!result.command.includes('Named profile'));}});
 check('hook idempotence',()=>{const first=rewrite('herdr agent start child --kind claude --pane w1:p1',root);assert.equal(rewrite(first.command,root).reason,'already-injected');});
 check('hook unknown pane unchanged',()=>assert.equal(rewrite('herdr agent start child --kind claude --pane w1:p2',root).reason,'unregistered-or-ambiguous-pane'));
 check('hook unsupported shell unchanged',()=>{const command='herdr agent start child --kind claude --pane w1:p1; echo hi';assert.equal(rewrite(command,root).command,command);});
 check('Codex always uses descriptor-specific configuration, never old global plugin metadata',()=>{const file=path.join(root,'installation.json');const bytes=fs.readFileSync(file);const state=JSON.parse(bytes);fs.writeFileSync(file,JSON.stringify({...state,codexPluginReady:true,codexPluginKey:'plugins.shepherd@fixture.enabled'}));process.env.SHEPHERD_AGENT_SESSION='/owned/stale-parent.json';try{const existing=prepare({...request,kind:'codex',arguments:['-p','work']});assert.equal(existing.injection,'codexConfigurationFallback');assert.deepEqual(existing.environment,{});assert(existing.arguments.includes('mcp_servers.shepherd-browser.args='+JSON.stringify(existing.mcpArguments)));assert(!existing.arguments.includes('plugins.shepherd@fixture.enabled=true'));const reservation=reserveLaunch({root});const bound=prepare({...request,kind:'codex',reservationID:reservation.reservationID});assert.equal(bound.injection,'codexConfigurationFallback');assert.deepEqual(bound.environment,reservation.environment);assert(!bound.arguments.includes('plugins.shepherd@fixture.enabled=true'));}finally{fs.writeFileSync(file,bytes);delete process.env.SHEPHERD_AGENT_SESSION;}});
 const codexLaunch=prepare({...request,kind:'codex',arguments:['-p','work']});
 check('Codex tested config fallback instructions merge',()=>{assert.equal(codexLaunch.injection,'codexConfigurationFallback');assert(codexLaunch.arguments.some(a=>a.startsWith('developer_instructions="Named profile\\nmultiline')));assert(codexLaunch.arguments.some(a=>a.startsWith('mcp_servers.shepherd-browser.args=')));});
 check('user config/profile preimages unchanged',()=>{assert.equal(fs.readFileSync(path.join(codexHome,'config.toml'),'utf8'),config);assert.equal(fs.readFileSync(claudeSettingsFile,'utf8'),'{"userSetting":"preserve"}');});
 check('combined profile options preserve selected instructions',()=>{for(const arguments_ of [['--profile=work'],['-pwork']]){const p=prepare({...request,kind:'codex',arguments:arguments_});assert(p.arguments.at(-1).includes('Named profile'));}});
 check('typed profile selection is forwarded to actual CLI',()=>{const p=prepare({...request,kind:'codex',profile:'work'});assert.deepEqual(p.arguments.slice(0,2),['--profile','work']);});
 check('TOML literal and raw developer override merge',()=>{for(const arguments_ of [['--config=developer_instructions=\'User literal\''],['-cdeveloper_instructions=Raw user words']]){const p=prepare({...request,kind:'codex',arguments:arguments_});assert(p.arguments.at(-1).includes('User literal') || p.arguments.at(-1).includes('Raw user words'));}});
 check('developer override merge',()=>{const p=prepare({...request,kind:'codex',arguments:['-c','developer_instructions="Override user text"']});assert(p.arguments.at(-1).includes('Override user text\\n\\nFor web pages'));});
 check('optional competitors default off',()=>assert(!launch.arguments.includes('--disallowedTools')));
 check('optional Claude competitors per session only',()=>{const p=prepare({...request,preferences:{disableCompetingBrowsers:true,competingBrowserServers:['chrome']}});assert(p.arguments.includes('mcp__chrome__*'));assert(p.arguments.includes('--no-chrome'));});
 check('optional Codex competitors per session only',()=>assert(prepare({...request,kind:'codex',preferences:{disableCompetingBrowsers:true,competingBrowserServers:['chrome']}}).arguments.includes('mcp_servers.chrome.enabled=false')));
 check('output bound validation',()=>assert.throws(()=>prepare({...request,preferences:{outputMaxSize:1}}),/invalid-output-limit/));
 check('origin restriction validation',()=>assert.throws(()=>prepare({...request,preferences:{allowedOrigins:['file:///tmp']}}),/invalid-origin/));
 check('duplicate/unknown launch registration fails',()=>assert.throws(()=>prepare({...request,arguments:['--mcp-config','shepherd-browser']}),/uninspectable-claude-registration/));
 const otherMCP=path.join(directory,'other-mcp.json');const ownMCP=path.join(directory,'own-mcp.json');
 fs.writeFileSync(otherMCP,JSON.stringify({mcpServers:{other:{command:'sh',args:['-c','touch must-not-execute']}}}));fs.writeFileSync(ownMCP,JSON.stringify({mcpServers:{'shepherd-browser':{command:'owned'}}}));
 for(const args of [['--mcp-config',otherMCP,ownMCP],['--mcp-config',otherMCP,'--mcp-config='+ownMCP],['--mcp-config='+JSON.stringify({mcpServers:{'shepherd-browser':{command:'owned'}}})]]) check('all variadic/equal/multiple MCP values reject own duplicate',()=>assert.throws(()=>prepare({...request,arguments:args}),/duplicate-registration/));
 const collection=path.join(directory,'plugin-collection');fs.mkdirSync(collection);const safePlugin=path.join(collection,'safe');const ownPlugin=path.join(collection,'own');
 for(const [dir,name] of [[safePlugin,'other'],[ownPlugin,'shepherd']]){fs.mkdirSync(path.join(dir,'.claude-plugin'),{recursive:true});fs.writeFileSync(path.join(dir,'.claude-plugin','plugin.json'),JSON.stringify({name}));}
 for(const args of [['--plugin-dir',collection],['--plugin-dir='+collection],['--plugin-dir',safePlugin,'--plugin-dir='+ownPlugin],['--plugin-dir='+safePlugin,'--plugin-dir',ownPlugin]]) check('plugin collection and every repeated/equals directory reject duplicate',()=>assert.throws(()=>prepare({...request,arguments:args}),/duplicate-registration/));
 check('MCP equals form leaves following positional input unconsumed as actual CLI does',()=>{assert(prepare({...request,arguments:['--mcp-config='+otherMCP,'ordinary prompt']}).arguments.includes('ordinary prompt'));});
 check('uninspectable Claude config/plugin inputs reject before preparation',()=>{for(const args of [['--mcp-config'],['--mcp-config',path.join(directory,'missing.json')],['--plugin-dir',path.join(directory,'unknown.zip')],['--plugin-dir='],['--']])assert.throws(()=>prepare({...request,arguments:args}),/uninspectable-claude-registration/);});
 check('valid variadic/equal MCP values and safe plugin inspected without executing content',()=>{const p=prepare({...request,arguments:['--mcp-config',otherMCP,otherMCP,'--plugin-dir',safePlugin,'--mcp-config='+otherMCP]});assert(p.arguments.includes(p.pluginDirectory));assert(!fs.existsSync(path.join(process.cwd(),'must-not-execute')));});
 check('resume Claude append',()=>assert.deepEqual(resume('claude',['--plugin-dir','/owned'],'session-1'),['--plugin-dir','/owned','--resume','session-1']));
 check('resume Codex append',()=>assert.deepEqual(resume('codex',['-c','foo=true'],'session-1'),['-c','foo=true','resume','session-1']));
 check('resume conflict rejects',()=>assert.throws(()=>resume('claude',['--resume','old'],'new'),/resume-conflict/));
 check('resume equals/continue conflicts reject',()=>{assert.throws(()=>resume('claude',['--resume=old'],'new'),/resume-conflict/);assert.throws(()=>resume('claude',['-c'],'new'),/resume-conflict/);});
 check('resume shell/path injection rejects',()=>assert.throws(()=>resume('codex',[],'../../bad;echo'),/invalid-session/));
 const modeRequest={root,claudeSettingsFile,claudeSkillDirectory:path.join(claudeDir,'skills'),codexHome,mode:'global'};
 check('all legacy mode changes reject without changing any user config',()=>{const oldClaude=fs.readFileSync(claudeSettingsFile);const oldCodex=fs.readFileSync(path.join(codexHome,'config.toml'));for(const mode of ['global','plugin'])assert.throws(()=>setMode({...modeRequest,mode}),/session-only-policy/);assert.deepEqual(fs.readFileSync(claudeSettingsFile),oldClaude);assert.deepEqual(fs.readFileSync(path.join(codexHome,'config.toml')),oldCodex);});
 check('global preference cannot bypass scoped preparation',()=>assert.throws(()=>prepare({...request,preferences:{mode:'global'}}),/session-only-policy/));
 check('existing own-name MCP registration is preserved and fails closed',()=>{const original=fs.readFileSync(claudeSettingsFile);const global=JSON.stringify({mcpServers:{'shepherd-browser':{command:'other'}}});fs.writeFileSync(claudeSettingsFile,global);assert.throws(()=>prepare(request),/duplicate-registration/);assert.equal(fs.readFileSync(claudeSettingsFile,'utf8'),global);fs.writeFileSync(claudeSettingsFile,original);});
 check('Codex receives bundled skill guidance only in its invocation',()=>{const p=prepare({...request,kind:'codex'});assert(p.arguments.at(-1).includes('Opaque credential CLI'));assert.equal(p.codexPluginKey,null);assert(!injected('codex',['-c','null=true'],p));assert.equal(detect('codex',executable).sessionPlugin,false);assert.equal(fs.readFileSync(path.join(codexHome,'config.toml'),'utf8'),config);assert(!fs.existsSync(path.join(codexHome,'skills','shepherd-browser')));});
 check('complete user CLI home inventory unchanged by scoped preparation',()=>{
  const inventory=()=>fs.readdirSync(home,{recursive:true}).sort().map(name=>{const f=path.join(home,name),s=fs.lstatSync(f);return [name,s.mode&0o777,s.isFile()?crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'):s.isSymbolicLink()?fs.readlinkSync(f):null];});
  const before=inventory();checkScope(request);prepare(request);prepare({...request,kind:'codex'});assert.deepEqual(inventory(),before);
 });
 check('legacy global MCP entry point rejects before starting MCP',()=>{
  const file=fileURLToPath(new URL('../../../Shepherd/Agents/AgentRuntime/mcp-run.mjs',import.meta.url));
  const result=spawnSync(process.execPath,[file,'--global',root],{input:'',encoding:'utf8',timeout:10000});assert.equal(result.status,1);assert.equal(result.stdout,'');assert.match(result.stderr,/unavailable or unsafe/);
 });
 check('owned pane cleanup does not remove sibling',()=>{const other=prepare({...request,pane:{...pane,paneID:'w1:p2',terminalID:'term-sibling'},endpoint:{...endpoint,url:endpoint.url.replace('w1:p1','w1:p2')}});cleanup({root,pane});assert(!fs.existsSync(launch.outputFolder));assert(!fs.existsSync(reservedLaunch.sessionFolder));assert(fs.existsSync(other.outputFolder));});
 console.log(JSON.stringify({checks,passed:true}));
} finally {fs.rmSync(directory,{recursive:true,force:true});}
