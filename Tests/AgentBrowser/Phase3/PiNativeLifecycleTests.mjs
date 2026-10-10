import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn,once} from '../../../Spikes/agent-browser-phase2/fixture-process.mjs';

const [app,output,piCLI,adapterEntry]=process.argv.slice(2);assert(app&&output&&piCLI);
fs.mkdirSync(output,{recursive:true,mode:0o700});
const root=fs.realpathSync(fs.mkdtempSync('/tmp/shp-pi-native-'));fs.chmodSync(root,0o700);
const home=path.join(root,'home'),bin=path.join(root,'bin'),profile=path.join(root,'profile');
for(const p of [home,bin,profile,path.join(home,'.pi-agent')])fs.mkdirSync(p,{mode:0o700});
fs.symlinkSync(fs.realpathSync(piCLI),path.join(bin,'pi'));
fs.copyFileSync('Tests/AgentBrowser/Phase3/OwnedPiNativeTool.ts',path.join(root,'OwnedPiNativeTool.ts'));
if(adapterEntry){
 assert.equal(JSON.parse(fs.readFileSync(path.join(path.dirname(adapterEntry),'package.json'),'utf8')).version,'5.1.0');
 fs.writeFileSync(path.join(root,'OwnedAdapter.ts'),`import {createMcpAdapter} from ${JSON.stringify(adapterEntry)};\nexport default createMcpAdapter({config:{mcpServers:{}}});\n`,{mode:0o600});
}
const extensions=[path.join(root,'OwnedPiNativeTool.ts'),...(adapterEntry?[path.join(root,'OwnedAdapter.ts')]:[])];
fs.writeFileSync(path.join(home,'.pi-agent/settings.json'),JSON.stringify({defaultProvider:'owned',defaultModel:'owned',tuiMode:'fullscreen',extensions}),{mode:0o600});
fs.writeFileSync(path.join(home,'AGENTS.md'),'Preserve SHEPHERD_OWNED_USER_INSTRUCTION.\n',{mode:0o600});
let calls=0;
const provider=http.createServer(async(req,res)=>{
 if(req.url==='/owned-page'){res.writeHead(200,{'content-type':'text/html'});res.end('<title>OWNED_PI_NATIVE</title><h1>OWNED_PI_NATIVE</h1>');return;}
 if(req.url==='/favicon.ico'){res.writeHead(204);res.end();return;}
 if(req.url!=='/v1/chat/completions'){res.writeHead(404);res.end();return;}
 let body='';for await(const c of req){body+=c;if(body.length>2000000){res.destroy();return;}}
 const request=JSON.parse(body);assert.equal(request.model,'owned');assert(++calls<=4);
 assert(JSON.stringify(request.messages).includes('SHEPHERD_OWNED_USER_INSTRUCTION'),'existing user instructions must survive managed injection');
 fs.writeFileSync(path.join(output,'model-count.json'),JSON.stringify({localRequests:calls,tools:(request.tools??[]).map(t=>t.function?.name)}),{mode:0o600});
 const done=request.messages.some(m=>m.role==='tool');
 res.writeHead(200,{'content-type':'text/event-stream'});
 const frame=(delta,finish_reason=null)=>res.write('data: '+JSON.stringify({id:'owned',object:'chat.completion.chunk',created:0,model:'owned',choices:[{index:0,delta,finish_reason}]})+'\n\n');
 frame({role:'assistant'});
 if(done)frame({content:'OWNED_DONE'});
 else frame({tool_calls:[{index:0,id:'owned-call',type:'function',function:{name:'owned_browser_check',arguments:'{}'}}]});
 frame({},done?'stop':'tool_calls');res.end('data: [DONE]\n\n');
});
await new Promise(resolve=>provider.listen(0,'127.0.0.1',resolve));
const baseURL='http://127.0.0.1:'+provider.address().port;
fs.writeFileSync(path.join(home,'native-fixture.json'),JSON.stringify({baseURL,backend:adapterEntry?'adapter':'builtin'}),{mode:0o600});
const session='pi-native',socket=path.join(home,'.config/herdr/sessions',session,'herdr.sock');
const env={PATH:bin+':'+path.dirname(process.execPath)+':'+process.env.PATH,HOME:home,CFFIXED_USER_HOME:home,PI_CODING_AGENT_DIR:path.join(home,'.pi-agent'),
 PI_OFFLINE:'1',PI_SKIP_VERSION_CHECK:'1',PI_MCP_ADAPTER_TEST_AUTH_STORE:'memory',HERDR_CONFIG_PATH:path.join(root,'herdr.toml'),TERM:'xterm-256color',LANG:'en_US.UTF-8'};
fs.writeFileSync(env.HERDR_CONFIG_PATH,'[update]\nversion_check=false\nmanifest_check=false\n',{mode:0o600});
fs.writeFileSync(path.join(output,'owned.json'),JSON.stringify({root,home,socket,session,baseURL}),{mode:0o600});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,ms=30000){const end=performance.now()+ms;while(performance.now()<end){if(await test())return;await delay(100);}throw Error('owned condition timed out');}
async function cli(args,asJSON=true){const p=spawn('herdr',['--session',session,...args],{env,cwd:home,stdio:['ignore','pipe','pipe'],timeout:40000});let text='',error='';p.stdout.on('data',c=>text+=c);p.stderr.on('data',c=>error+=c);const [code,signal]=await once(p,'exit',{signal:AbortSignal.timeout(45000)});if(code!==0||signal)throw Error('owned herdr failed: '+error);return asJSON?JSON.parse(text):text;}
const read=file=>JSON.parse(fs.readFileSync(file,'utf8'));
async function denied(endpoint,pathname){
 assert(endpoint.tokenFile.startsWith(profile+path.sep));
 const token=fs.readFileSync(endpoint.tokenFile,'utf8').trim();
 await new Promise((resolve,reject)=>{
  const u=new URL(endpoint.url);const request=http.request({host:'127.0.0.1',port:u.port,path:pathname,headers:{Connection:'Upgrade',Upgrade:'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':'AAAAAAAAAAAAAAAAAAAAAA==',Authorization:'Bearer '+token}},response=>{response.resume();response.statusCode===401?resolve():reject(Error('lease denial status'));});
  request.once('upgrade',(_r,s)=>{s.destroy();reject(Error('revoked or unleased route admitted'));});request.once('error',reject);request.setTimeout(3000,()=>request.destroy(Error('denial timeout')));request.end();
 });
}
let server,application,attach;const fds=[];let healthy=false;
try{
 const fd=fs.openSync(path.join(output,'herdr.log'),'w',0o600);fds.push(fd);
 server=spawn('herdr',['--session',session,'server'],{env,cwd:home,stdio:['ignore',fd,fd],timeout:180000});
 await until(()=>fs.existsSync(socket));
 await cli(['workspace','create','--label','Owned initial','--no-focus']);
 fs.writeFileSync(path.join(output,'input.json'),JSON.stringify({root,socket,session,node:process.execPath,piNative:true}),{mode:0o600});
 const appFD=fs.openSync(path.join(output,'app.log'),'w',0o600);fds.push(appFD);
 application=spawn(app,[],{env:{...env,SHEPHERD_AGENT_LAUNCH_FIXTURE:output,SHEPHERD_BROWSER_TEST_ROOT:profile},cwd:home,stdio:['ignore',appFD,appFD],timeout:150000});
 await until(()=>fs.existsSync(path.join(output,'selection.json'))||fs.existsSync(path.join(output,'failed.json')));
 assert(!fs.existsSync(path.join(output,'failed.json')),'app preparation failed: '+(fs.existsSync(path.join(output,'failed.json'))?JSON.stringify(read(path.join(output,'failed.json'))):''));
 const selected=read(path.join(output,'selection.json'));
 attach=spawn('/usr/bin/python3',['Tests/AgentBrowser/Phase3/OwnedHerdrPTY.py','--session',session,'--terminal',selected.terminal,'--output',path.join(output,'terminal.log'),'--closed-marker',path.join(output,'terminal-closed.json')],{env,cwd:process.cwd(),stdio:['ignore','pipe','pipe'],timeout:125000});attach.stdout.resume();attach.stderr.resume();
 await until(()=>fs.existsSync(path.join(output,'terminal.log'))&&fs.statSync(path.join(output,'terminal.log')).size>0,10000);
 fs.writeFileSync(path.join(output,'shell-snapshot.json'),JSON.stringify(await cli(['api','snapshot'])),{mode:0o600});
 fs.writeFileSync(path.join(output,'attached'),'attached',{mode:0o600});
 await until(()=>fs.existsSync(path.join(output,'ready.json'))||fs.existsSync(path.join(output,'failed.json')),50000);
 if(fs.existsSync(path.join(output,'failed.json')))throw Error('app: '+JSON.stringify(read(path.join(output,'failed.json'))));
 const ready=read(path.join(output,'ready.json'));assert(ready.metadataOnly && ready.publicLaunchService);
 const attempt=fs.readdirSync(ready.stage).find(name=>/^[a-f0-9-]{36}$/.test(name));assert(attempt);
 const endpoint=read(path.join(ready.stage,attempt,'browser.json')).endpoint;
 const leasedPath=new URL(endpoint.url).pathname;
 await denied(endpoint,leasedPath.replace(/\/lease\/[^/]+$/,''));
 console.log('PASS no legacy unleased-route fallback while Pi owns the pane');
 await until(async()=>{
  const rows=await cli(['agent','list']);
  fs.writeFileSync(path.join(output,'readiness-poll.json'),JSON.stringify(rows),{mode:0o600});
  const agent=rows.result.agents.find(a=>a.pane_id===selected.pane&&a.terminal_id===selected.terminal);
  return agent?.agent==='pi' && agent.interactive_ready===true && agent.launch_pending!==true;
 },20000);
 console.log('PASS owned Herdr interactive readiness + pre-import binding + real Pi MCP ownership');
 fs.writeFileSync(path.join(output,'pre-prompt-agents.json'),JSON.stringify(await cli(['agent','list'])),{mode:0o600});
 fs.writeFileSync(path.join(output,'pre-prompt-process.json'),JSON.stringify(await cli(['pane','process-info','--pane',selected.pane])),{mode:0o600});
 fs.writeFileSync(path.join(output,'pre-prompt-snapshot.json'),JSON.stringify(await cli(['api','snapshot'])),{mode:0o600});
 await cli(['agent','prompt',selected.pane,'OWNED_NATIVE_BROWSER_CHECK','--wait','--timeout','35000']);
 await until(()=>fs.existsSync(path.join(home,'native-tool.json'))&&fs.existsSync(path.join(home,'settled.json')),20000);
 const result=read(path.join(home,'native-tool.json'));assert.equal(result.ok,true,JSON.stringify(result));
 await until(()=>fs.existsSync(path.join(output,'browser.json'))&&read(path.join(output,'browser.json')).title==='OWNED_PI_NATIVE');
 assert(read(path.join(output,'browser.json')).connected);
 console.log('PASS actual Pi tool execution -> owned MCP -> leased route -> real native CEF page');
 await cli(['agent','send-keys',selected.pane,'ctrl+d']);
 await until(async()=>{const p=(await cli(['pane','process-info','--pane',selected.pane])).result.process_info;return Array.isArray(p.foreground_processes)&&p.foreground_processes.length>0&&p.foreground_processes.every(x=>x.pid===p.shell_pid);},15000);
 await denied(endpoint,leasedPath);
 console.log('PASS revoked lease replay denied by real HTTP upgrade boundary');
 fs.writeFileSync(path.join(output,'stop'),'stop',{mode:0o600});
 await until(()=>fs.existsSync(path.join(output,'finished.json'))||fs.existsSync(path.join(output,'failed.json')),25000);
 assert(fs.existsSync(path.join(output,'finished.json')));
 const [code,signal]=await once(application,'exit',{signal:AbortSignal.timeout(20000)});assert.equal(code,0);assert.equal(signal,null);
 await cli(['pane','close',selected.pane]);
 fs.writeFileSync(path.join(output,'terminal-closed.json'),JSON.stringify({terminal:selected.terminal,pane:selected.pane,session}),{mode:0o600});
 const [ptyCode,ptySignal]=await once(attach,'exit');assert.equal(ptyCode,0);assert.equal(ptySignal,null);
 await cli(['session','stop',session,'--json']);
 const [serverCode,serverSignal]=await once(server,'exit');assert.equal(serverCode,0);assert.equal(serverSignal,null);
 const settings=read(path.join(home,'.pi-agent/settings.json'));
 assert.equal(settings.defaultProvider,'owned');assert.equal(settings.defaultModel,'owned');assert.deepEqual(settings.extensions,extensions);
 healthy=true;
 fs.writeFileSync(path.join(output,'result.json'),JSON.stringify({passed:true,publicLaunchService:true,userInstructionsPreserved:true,userExtensionsPreserved:true,actualCEF:true,actualPi:true,actualHerdr:true,backend:adapterEntry?'adapter':'builtin',credentialStore:'private in-memory test store',localModelRequests:calls,vendorRequests:0,nativeRetirementConfirmed:true}),{mode:0o600});
 console.log('PASS natural Pi, MCP, CEF/app, owned Herdr and PTY shutdown');
} finally {
 // Failure remains red. Only child handles created above are eligible for cleanup.
 if(!healthy){
  try{fs.writeFileSync(path.join(output,'stop'),'stop',{mode:0o600});}catch{}
  try{fs.writeFileSync(path.join(output,'terminal-closed.json'),'{}',{mode:0o600});}catch{}
  const signals=[];
  for(const [role,p] of [['attach',attach],['application',application],['server',server]])if(p&&p.exitCode===null&&p.signalCode===null){signals.push({role,pid:p.pid,signal:'SIGTERM'});p.kill('SIGTERM');}
  fs.writeFileSync(path.join(output,'failure-cleanup.json'),JSON.stringify({healthy:false,signals}),{mode:0o600});
 }
 await new Promise(resolve=>provider.close(resolve));
 for(const fd of fds)fs.closeSync(fd);
}
