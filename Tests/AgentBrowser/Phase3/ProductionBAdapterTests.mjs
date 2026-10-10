import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {install,prepare,cleanup} from '../../../Shepherd/Agents/AgentRuntime/runtime.mjs';
const require=createRequire(new URL('../../../Spikes/agent-browser-phase2/package.json',import.meta.url));
const {Client}=require('@modelcontextprotocol/sdk/client/index.js');
const {StdioClientTransport}=require('@modelcontextprotocol/sdk/client/stdio.js');
const [appPath,logDirectory]=process.argv.slice(2);assert(appPath && logDirectory);
fs.mkdirSync(logDirectory,{recursive:true,mode:0o700});
const base=fs.mkdtempSync(path.join(os.tmpdir(),'shepherd-runtime-b-'));const home=path.join(base,'home');fs.mkdirSync(home,{mode:0o700});
const codexHome=path.join(home,'.codex');fs.mkdirSync(codexHome,{mode:0o700});
const claudeHome=path.join(home,'.claude');fs.mkdirSync(claudeHome,{mode:0o700});
const environment={PATH:process.env.PATH,HOME:home,CODEX_HOME:codexHome,CLAUDE_CONFIG_DIR:claudeHome,TERM:'dumb'};
for(const key of Object.keys(process.env)) delete process.env[key];Object.assign(process.env,environment);
const root=path.join(base,'runtime');const fixture=path.join(base,'fixture');fs.mkdirSync(fixture,{mode:0o700});
const appLog=fs.openSync(path.join(logDirectory,'app.log'),'w',0o600);
let app;const clients=[];const mcpProcesses=[];let plans=[];
const server=http.createServer((req,res)=>{res.writeHead(200,{'content-type':'text/html'});res.end('<title>Owned B adapter</title><button id="owned">Owned button</button>');});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+server.address().port;
async function until(predicate,timeout=45000) {const end=Date.now()+timeout;while(Date.now()<end){if(predicate())return;await new Promise(r=>setTimeout(r,100));}throw new Error('fixture deadline');}
try {
 app=spawn(appPath,[],{env:{PATH:process.env.PATH,HOME:home,SHEPHERD_BROWSER_TEST_ROOT:path.join(base,'profile'),SHEPHERD_BROWSER_PHASE2_FIXTURE:fixture},stdio:['ignore',appLog,appLog],timeout:180000,killSignal:'SIGKILL'});
 await until(()=>fs.existsSync(path.join(fixture,'ready.json')));
 const info=JSON.parse(fs.readFileSync(path.join(fixture,'ready.json'),'utf8'));assert.equal(info.pid,app.pid);
 install({root});
 for(const [index,endpoint] of [info.endpointA,info.endpointB].entries()) {
  const pane={machineID:'C0CD0000-0000-4000-8000-000000000001',herdrMachineID:null,session:'phase2-fixture',paneID:'w1:p'+(index+1),terminalID:'fixture-term-'+(index+1)};
  const plan=prepare({root,kind:index?'codex':'claude',executable:index?'codex':'claude',pane,endpoint:{origin:'thisMac',url:endpoint,tokenFile:info.tokenFile},codexHome,claudeSettingsFile:path.join(home,'.claude.json'),preferences:{allowedOrigins:[url],blockedOrigins:['https://blocked.invalid'],outputMaxSize:1024*1024}});
  plans.push({plan,pane});
  const client=new Client({name:'owned-runtime-b-'+index,version:'1.0.0'});
  const transport=new StdioClientTransport({command:process.execPath,args:plan.mcpArguments,env:{PATH:process.env.PATH,HOME:home},stderr:'pipe'});
  transport.stderr?.resume();await client.connect(transport);clients.push(client);
  // Pinned SDK 1.28.0 close() escalates signals after its EOF grace. Observe
  // actual wrapper exits directly before calling it; no signal-based healthy pass.
  mcpProcesses.push(transport._process);
  const tools=await client.listTools();assert(tools.tools.some(t=>t.name==='browser_navigate'));
  const response=await client.callTool({name:'browser_navigate',arguments:{url}});assert(!response.isError,JSON.stringify(response));
  console.log('PASS installed protected-config MCP -> production B adapter pane '+(index+1));
 }
 const evaluate=async(index,expression)=>{
  const result=await clients[index].callTool({name:'browser_evaluate',arguments:{function:expression}});assert(!result.isError,JSON.stringify(result));return JSON.stringify(result);
 };
 await evaluate(0,'() => { localStorage.setItem("owned", "pane-a"); document.cookie="owned=a"; return localStorage.getItem("owned"); }');
 assert(!(await evaluate(1,'() => [localStorage.getItem("owned"), document.cookie]')).includes('pane-a'));
 const oldOutput=path.join(plans[0].plan.outputFolder,'owned-old-output.bin');fs.writeFileSync(oldOutput,Buffer.alloc(2*1024*1024));fs.utimesSync(oldOutput,new Date(0),new Date(0));
 const screenshot=await clients[0].callTool({name:'browser_take_screenshot',arguments:{}});assert(!screenshot.isError);
 assert(!fs.existsSync(oldOutput),'pinned output eviction threshold not enforced');
 assert(fs.readdirSync(plans[0].plan.outputFolder).some(n=>n.endsWith('.png')));
 const escape=await clients[0].callTool({name:'browser_take_screenshot',arguments:{filename:'../outside.png'}});assert(escape.isError);
 const outside=path.join(base,'outside');fs.mkdirSync(outside,{mode:0o700});fs.symlinkSync(outside,path.join(plans[0].plan.outputFolder,'symlink'));
 const symlink=await clients[0].callTool({name:'browser_take_screenshot',arguments:{filename:'symlink/outside.png'}});assert(symlink.isError);
 assert(!fs.existsSync(path.join(outside,'outside.png')));
 assert.throws(()=>cleanup({root,pane:plans[0].pane}),/mcp-still-running/);
 console.log('PASS explicit output traversal/symlink rejection and live MCP cleanup refusal');
 const blocked=await clients[0].callTool({name:'browser_navigate',arguments:{url:'https://blocked.invalid'}});assert(blocked.isError,'origin guard missing');
 console.log('PASS two pane cookie/storage isolation, bounded pane output and configured origin guard');
 for(const {plan} of plans) {
  const session=JSON.parse(fs.readFileSync(path.join(plan.sessionFolder,'session.json'),'utf8'));
  assert(!JSON.stringify(session).includes('Authorization'));
  const secretConfigs=fs.readdirSync(plan.sessionFolder).filter(n=>n.startsWith('.mcp-'));
  assert(secretConfigs.length===1);
  assert.equal(fs.statSync(path.join(plan.sessionFolder,secretConfigs[0])).mode&0o077,0);
 }
 for(const child of mcpProcesses) {
  const exited=once(child,'exit',{signal:AbortSignal.timeout(15000)});child.stdin.end();
  const [code,signal]=await exited;assert.equal(code,0);assert.equal(signal,null);
 }
 for(const client of clients) await client.close();clients.length=0;
 await until(()=>plans.every(({plan})=>!fs.readdirSync(plan.sessionFolder).some(n=>n.startsWith('.mcp-'))),15000);
 console.log('PASS MCP termination removes protected transient header config without token argv/logging');
 fs.writeFileSync(path.join(fixture,'command'),'quit');
 const [code,signal]=await once(app,'exit',{signal:AbortSignal.timeout(20000)});assert.equal(code,0);assert.equal(signal,null);
 for(const {plan,pane} of plans) {cleanup({root,pane});assert(!fs.existsSync(plan.outputFolder));}
 console.log('PASS acknowledged production B fixture normal shutdown and owned pane output cleanup');
 fs.writeFileSync(path.join(logDirectory,'result.json'),JSON.stringify({passed:true,pinnedMCP:'0.0.83',productionBFixture:true,paneCount:2,normalAppExit:true},null,2));
} finally {
 for(const client of clients) await client.close().catch(()=>{});
 server.close();
 if(app?.exitCode===null && app?.signalCode===null) {
  fs.writeFileSync(path.join(fixture,'command'),'quit');
  await once(app,'exit',{signal:AbortSignal.timeout(20000)});
 }
 fs.closeSync(appLog);fs.rmSync(base,{recursive:true,force:true});
}
