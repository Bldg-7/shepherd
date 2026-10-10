import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {install,setupCodex,prepare,registerPane,setMode,reserveLaunch} from '../../../Shepherd/Agents/AgentRuntime/runtime.mjs';
import {detect,readCodex,resume,INSTRUCTIONS} from '../../../Shepherd/Agents/AgentRuntime/runtime-core.mjs';

const base=fs.mkdtempSync(path.join(os.tmpdir(),'shepherd-real-cli-'));
const home=path.join(base,'home');fs.mkdirSync(home,{mode:0o700});
const codexHome=path.join(home,'.codex');const claudeDir=path.join(home,'.claude');
for(const dir of [codexHome,claudeDir]) fs.mkdirSync(dir,{mode:0o700});
const root=path.join(base,'runtime');
const tokenFile=path.join(base,'token');fs.writeFileSync(tokenFile,crypto.randomBytes(32).toString('base64'),{mode:0o600});
const request={root,pane:{machineID:'owned-fixture',herdrMachineID:null,session:'default',paneID:'w1:p1',terminalID:'owned-cli'},endpoint:{origin:'thisMac',url:'ws://127.0.0.1:19439/v1/herdr/default/pane/w1:p1',tokenFile},codexHome,claudeSettingsFile:path.join(claudeDir,'.claude.json')};
const env={PATH:process.env.PATH,HOME:home,CLAUDE_CONFIG_DIR:claudeDir,CODEX_HOME:codexHome,ANTHROPIC_API_KEY:'owned-local-fixture',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1',DISABLE_TELEMETRY:'1',DISABLE_ERROR_REPORTING:'1',CLAUDE_CODE_SKIP_OAUTH:'1',NO_PROXY:'127.0.0.1,localhost',TERM:'dumb'};
const invocations=[];let activeInvocation;let requestCount=0;
function toolNames(tools, prefix='') {
 return (tools ?? []).flatMap(t=>{const name=t.name ?? t.function?.name;const full=prefix+(name ?? '');return Array.isArray(t.tools) ? toolNames(t.tools,full+'.') : name ? [full] : [];});
}
let claudeHookMode=false;let hookResult='';let competingMode=false;let competingResult='';
const server=http.createServer(async(req,res)=>{
 const invocation=activeInvocation;
 let body='';for await(const chunk of req) body+=chunk;
 const value=JSON.parse(body || '{}');
 if(req.url.includes('count_tokens')) {res.writeHead(200,{'content-type':'application/json'});res.end('{"input_tokens":100}');return;}
 const tools=toolNames(value.tools);
 requestCount++;
 if(invocation) invocation.requests.push({url:req.url,tools,system:JSON.stringify([value.system,value.instructions,...(Array.isArray(value.input)?value.input:[]).filter(i=>i.role==='developer')])});
 if(req.url.includes('messages')) {
  const message={id:'msg_owned',type:'message',role:'assistant',model:value.model,content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:10,output_tokens:1}};
  const toolResult=(value.messages ?? []).flatMap(m=>Array.isArray(m.content)?m.content:[]).find(c=>c.type==='tool_result');
  if(claudeHookMode && toolResult) hookResult=JSON.stringify(toolResult);
  if(competingMode && toolResult) competingResult=JSON.stringify(toolResult);
  const useCompeting=competingMode && !toolResult && JSON.stringify(value.messages).includes('Exercise owned competing tool.');
  const useHook=claudeHookMode && !toolResult && JSON.stringify(value.messages).includes('Exercise owned child hook.');
  if(value.stream) {
   res.writeHead(200,{'content-type':'text/event-stream'});
   const send=(event,data)=>res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
   send('message_start',{type:'message_start',message});
   if(useHook) {
    send('content_block_start',{type:'content_block_start',index:0,content_block:{type:'tool_use',id:'tool_owned',name:'Bash',input:{}}});
    send('content_block_delta',{type:'content_block_delta',index:0,delta:{type:'input_json_delta',partial_json:JSON.stringify({command:'herdr agent start owned-child --kind claude --pane w1:p2',description:'Run owned child hook fixture'})}});
   } else if(useCompeting) {
    send('content_block_start',{type:'content_block_start',index:0,content_block:{type:'tool_use',id:'tool_owned_other',name:'mcp__owned-other__browser_navigate',input:{}}});
    send('content_block_delta',{type:'content_block_delta',index:0,delta:{type:'input_json_delta',partial_json:JSON.stringify({url:'http://127.0.0.1/owned-fixture'})}});
   } else {
    send('content_block_start',{type:'content_block_start',index:0,content_block:{type:'text',text:''}});
    send('content_block_delta',{type:'content_block_delta',index:0,delta:{type:'text_delta',text:'OWNED_PROVIDER_OK'}});
   }
   send('content_block_stop',{type:'content_block_stop',index:0});send('message_delta',{type:'message_delta',delta:{stop_reason:(useHook || useCompeting)?'tool_use':'end_turn',stop_sequence:null},usage:{output_tokens:3}});send('message_stop',{type:'message_stop'});res.end();
  } else {res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({...message,content:[{type:'text',text:'OWNED_PROVIDER_OK'}],stop_reason:'end_turn'}));}
 } else if(req.url.includes('responses')) {
  res.writeHead(200,{'content-type':'text/event-stream'});
  const message={type:'message',id:'msg_owned',status:'completed',role:'assistant',content:[{type:'output_text',text:'OWNED_PROVIDER_OK',annotations:[]}]};
  const response={id:'resp_owned',object:'response',created_at:0,status:'completed',output:[message],usage:{input_tokens:10,output_tokens:3,total_tokens:13}};
  for(const event of [{type:'response.created',response:{...response,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item:{...message,status:'in_progress',content:[]}},{type:'response.content_part.added',item_id:'msg_owned',output_index:0,content_index:0,part:{type:'output_text',text:'',annotations:[]}},{type:'response.output_text.delta',item_id:'msg_owned',output_index:0,content_index:0,delta:'OWNED_PROVIDER_OK'},{type:'response.output_item.done',output_index:0,item:message},{type:'response.completed',response}]) res.write(`data: ${JSON.stringify(event)}\n\n`);
  res.end();
 } else {res.writeHead(404);res.end('{}');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const url='http://127.0.0.1:'+server.address().port;
env.ANTHROPIC_BASE_URL=url;
async function run(executable,args,extra={}) {
 assert(!activeInvocation,'overlapping CLI capture');
 const capture={id:invocations.length+1,cli:executable,requests:[]};invocations.push(capture);activeInvocation=capture;
 const child=spawn(executable,args,{env:{...env,...extra},cwd:home,stdio:['ignore','pipe','pipe'],timeout:60000,killSignal:'SIGKILL'});
 let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
 const [code,signal]=await once(child,'exit',{signal:AbortSignal.timeout(65000)});
 activeInvocation=undefined;
 console.log(JSON.stringify({invocation:capture.id,cli:executable,exitCode:code,signal,providerRequests:capture.requests.length}));
 if(code !== 0) console.log(stderr.replaceAll('owned-local-fixture','[fixture]'));
 assert.equal(signal,null);assert.equal(code,0);
 return {stdout,stderr,capture};
}
function assertCodexRegistration(result, instruction, label) {
 assert.equal(result.capture.cli,'codex');
 const own=result.capture.requests.filter(r=>r.url.includes('responses'));
 const toolsPresent=own.some(r=>r.tools.some(t=>/shepherd[-_]browser/.test(t) && t.endsWith('browser_navigate')));
 const instructionsPresent=own.some(r=>r.system.includes(instruction) && r.system.includes(INSTRUCTIONS));
 console.log(JSON.stringify({label,invocation:result.capture.id,codexProviderRequests:own.length,ownShepherdTools:toolsPresent,mergedSelectedInstructions:instructionsPresent}));
 assert(own.length > 0,'this Codex invocation produced no provider requests');
 assert(toolsPresent,label+': own Shepherd tools absent');assert(instructionsPresent,label+': merged selected instructions absent');
 assert(result.stdout.includes('OWNED_PROVIDER_OK'));
}
try {
 for(const key of Object.keys(process.env)) delete process.env[key];
 Object.assign(process.env,env);
 install({root});
 const claude=detect('claude','claude');const codex=detect('codex','codex');
 assert(claude.sessionPlugin);assert(!codex.sessionPlugin);assert(codex.sessionConfiguration);assert(!codex.hookRewrite);
 console.log(JSON.stringify({claudeVersion:claude.version,codexVersion:codex.version,codexHookRewrite:'not-assumed-supported; instruction/config fallback'}));
 assert.throws(()=>setupCodex({root,executable:'codex',codexHome}),/session-only-policy/);
 fs.writeFileSync(path.join(codexHome,'config.toml'),'# owned fixture config\n',{mode:0o600});
 fs.writeFileSync(request.claudeSettingsFile,'{}',{mode:0o600});
 fs.writeFileSync(path.join(codexHome,'work.config.toml'),'developer_instructions="Keep profile words"\n',{mode:0o600});
 const preimage=fs.readFileSync(path.join(codexHome,'config.toml'));
 const help=await run('claude',['--help']);assert(help.stdout.includes('--mcp-config <configs...>'));assert(help.stdout.includes('--plugin-dir <path>'));console.log('PASS actual Claude help confirms variadic MCP and singular repeatable/collection plugin grammar');
 const claudeReservation=reserveLaunch({root});
 const claudePlan=prepare({...request,kind:'claude',executable:'claude',reservationID:claudeReservation.reservationID});
 assert.deepEqual(claudePlan.environment,claudeReservation.environment);
 const c=await run('claude',[...claudePlan.arguments,'-p','Return owned provider marker.','--output-format','stream-json','--verbose','--no-session-persistence','--model','owned-fixture-model'],claudePlan.environment);
 const events=c.stdout.trim().split('\n').map(line=>{try{return JSON.parse(line);}catch{return null;}}).filter(Boolean);
 const init=events.find(e=>e.type==='system' && e.subtype==='init');
 assert(init,'Claude init event missing');
 assert(init.plugins?.some(p=>p.name==='shepherd'),'Claude plugin not loaded');
 assert(init.mcp_servers?.some(p=>p.name.includes('shepherd-browser') && p.status==='connected'),'Claude MCP not connected');
 assert(init.skills?.some(p=>p.includes('shepherd-browser')),'Claude skill v2 not loaded');
 assert(c.stdout.includes('OWNED_PROVIDER_OK'));
 console.log('PASS real Claude session plugin, skill and pinned MCP startup under local provider');
 const fixtureBin=path.join(base,'fixture-bin');fs.mkdirSync(fixtureBin,{mode:0o700});
 fs.writeFileSync(path.join(fixtureBin,'herdr'),'#!/bin/sh\nprintf \'%s\\n\' "$@"\n',{mode:0o700});
 registerPane({...request,pane:{...request.pane,paneID:'w1:p2',terminalID:'owned-child'},endpoint:{...request.endpoint,url:request.endpoint.url.replace('w1:p1','w1:p2')},executables:{claude:'claude'}});
 claudeHookMode=true;
 await run('claude',[...claudePlan.arguments,'-p','Exercise owned child hook.','--output-format','stream-json','--verbose','--no-session-persistence','--allowedTools','Bash(herdr *)','--model','owned-fixture-model'],{...claudePlan.environment,PATH:fixtureBin+path.delimiter+env.PATH});
 claudeHookMode=false;
 assert(hookResult.includes('--plugin-dir'),'Claude hook updatedInput not executed');
 assert(JSON.parse(fs.readFileSync(path.join(root,'hook-events.json'),'utf8')).some(e=>e.reason==='injected'));
 console.log('PASS real Claude PreToolUse updatedInput executes child-specific plugin argv (owned fake herdr; not child-agent integration)');
 const competingServer=path.join(base,'owned-competing-mcp.mjs');const called=path.join(base,'competing-called');
 fs.writeFileSync(competingServer,`import fs from 'node:fs';import readline from 'node:readline';const lines=readline.createInterface({input:process.stdin});lines.on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;let result={};if(m.method==='initialize')result={protocolVersion:m.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:'owned-other',version:'1.0.0'}};if(m.method==='tools/list')result={tools:[{name:'browser_navigate',description:'Owned local competitor fixture',inputSchema:{type:'object',properties:{url:{type:'string'}},required:['url']}}]};if(m.method==='tools/call'){fs.writeFileSync(process.argv[2],'called');result={content:[{type:'text',text:'MOCK_COMPETITOR_CALLED'}]};}process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');});`);
 const userClaude=JSON.parse(fs.readFileSync(request.claudeSettingsFile,'utf8'));userClaude.mcpServers ??= {};userClaude.mcpServers['owned-other']={command:process.execPath,args:[competingServer,called]};fs.writeFileSync(request.claudeSettingsFile,JSON.stringify(userClaude));
 competingMode=true;
 const competingArgs=['-p','Exercise owned competing tool.','--output-format','stream-json','--verbose','--no-session-persistence','--allowedTools','mcp__owned-other__browser_navigate','--model','owned-fixture-model'];
 await run('claude',[...claudePlan.arguments,...competingArgs],claudePlan.environment);
 assert(fs.existsSync(called),'default-off competitor tool did not execute');assert(competingResult.includes('MOCK_COMPETITOR_CALLED'));fs.unlinkSync(called);
 const disabledPlan=prepare({...request,kind:'claude',executable:'claude',preferences:{disableCompetingBrowsers:true,competingBrowserServers:['owned-other']}});
 competingResult='';await run('claude',[...disabledPlan.arguments,...competingArgs],disabledPlan.environment);
 assert(!fs.existsSync(called),'disallowed competitor tool executed');assert(!competingResult.includes('MOCK_COMPETITOR_CALLED'));
 competingMode=false;
 console.log('PASS real Claude optional competing-browser disable prevents execution; default-off permits owned mock tool');
 const files=['a','b'].map(name=>{const file=path.join(base,'config-'+name+'.json');fs.writeFileSync(file,JSON.stringify({mcpServers:{['owned-config-'+name]:{command:process.execPath,args:[competingServer,called]}}}));return file;});
 const collection=path.join(base,'plugins');fs.mkdirSync(collection,{mode:0o700});
 const pluginPaths=['a','b','c'].map(name=>{const dir=path.join(name==='c'?base:collection,'plugin-'+name);fs.mkdirSync(path.join(dir,'.claude-plugin'),{recursive:true,mode:0o700});fs.writeFileSync(path.join(dir,'.claude-plugin','plugin.json'),JSON.stringify({name:'owned-plugin-'+name,version:'1.0.0'}));return dir;});
 const grammarPlan=prepare({...request,kind:'claude',executable:'claude',arguments:['--mcp-config',files[0],files[1],'--plugin-dir',collection,'--plugin-dir='+pluginPaths[2]]});
 const grammar=await run('claude',[...grammarPlan.arguments,'-p','Return owned provider marker.','--output-format','stream-json','--verbose','--no-session-persistence','--model','owned-fixture-model'],grammarPlan.environment);
 const grammarInit=grammar.stdout.split('\n').map(l=>{try{return JSON.parse(l);}catch{return null;}}).find(e=>e?.type==='system' && e.subtype==='init');
 console.log(JSON.stringify({claudeGrammarServers:grammarInit.mcp_servers.map(s=>({name:s.name,status:s.status})),claudeGrammarPlugins:grammarInit.plugins.map(p=>p.name)}));
 for(const name of ['owned-config-a','owned-config-b'])assert(grammarInit.mcp_servers.some(s=>s.name===name && s.status==='connected'));
 for(const name of ['owned-plugin-a','owned-plugin-b','owned-plugin-c','shepherd'])assert(grammarInit.plugins.some(p=>p.name===name));
 console.log('PASS actual Claude consumes both separate variadic MCP files and collection/repeated/equals plugin directories');
 const equalPlan=prepare({...request,kind:'claude',executable:'claude',arguments:['--mcp-config='+files[0],'--mcp-config='+files[1]]});
 const equalRun=await run('claude',[...equalPlan.arguments,'-p','Return owned provider marker.','--output-format','stream-json','--verbose','--no-session-persistence','--model','owned-fixture-model'],equalPlan.environment);
 const equalInit=equalRun.stdout.split('\n').map(l=>{try{return JSON.parse(l);}catch{return null;}}).find(e=>e?.type==='system' && e.subtype==='init');
 for(const name of ['owned-config-a','owned-config-b'])assert(equalInit.mcp_servers.some(s=>s.name===name && s.status==='connected'));
 console.log('PASS actual Claude repeated equals MCP options each register their own inspected file');
 const codexReservation=reserveLaunch({root});
 const codexPlan=prepare({...request,kind:'codex',executable:'codex',profile:'work',reservationID:codexReservation.reservationID});
 assert.deepEqual(codexPlan.environment,codexReservation.environment);
 const providerArgs=['-c','model_provider="owned"','-c','model="owned-fixture-model"','-c','model_providers.owned.name="Owned fixture"','-c',`model_providers.owned.base_url="${url}"`,'-c','model_providers.owned.wire_api="responses"','-c','model_providers.owned.requires_openai_auth=false','-c','model_providers.owned.supports_websockets=false'];
 const x=await run('codex',[...codexPlan.arguments,...providerArgs,'exec','--skip-git-repo-check','--json','Return owned provider marker.'],codexPlan.environment);
 assert.equal(codexPlan.injection,'codexConfigurationFallback');assertCodexRegistration(x,'Keep profile words','reserved session configuration');
 assert.deepEqual(fs.readFileSync(path.join(codexHome,'config.toml')),preimage,'session launch mutated config');
 console.log('PASS real Codex per-session MCP/instructions and unchanged config; no native skill registration claimed');
 // Actual CLI profile and optional server disable capabilities, not stubs.
 fs.writeFileSync(path.join(codexHome,'work.config.toml'),'developer_instructions="Keep profile words"\n[mcp_servers.owned-other]\ncommand="/owned-disabled-must-not-run"\n',{mode:0o600});
 const fallbackRoot=path.join(base,'fallback-runtime');install({root:fallbackRoot});
 const fallback=prepare({...request,root:fallbackRoot,kind:'codex',executable:'codex',profile:'work',arguments:['-p','work'],preferences:{disableCompetingBrowsers:true,competingBrowserServers:['owned-other']}});
 const f=await run('codex',[...fallback.arguments,...providerArgs,'exec','--skip-git-repo-check','--json','Return owned provider marker.'],fallback.environment);
 assertCodexRegistration(f,'Keep profile words','configuration fallback');
 console.log('PASS real Codex configuration fallback, v2 profile merge and optional scoped MCP disable');
 const existing=prepare({...request,kind:'codex',executable:'codex',profile:'work',preferences:{disableCompetingBrowsers:true,competingBrowserServers:['owned-other']},arguments:['-c','developer_instructions="Existing pane override"']});
 assert.equal(existing.injection,'codexConfigurationFallback');assert.deepEqual(existing.environment,{});
 const stale={SHEPHERD_AGENT_SESSION:'/owned/stale-parent-must-not-load.json'};
 const e=await run('codex',[...existing.arguments,...providerArgs,'exec','--skip-git-repo-check','--json','Return owned provider marker.'],stale);
 assertCodexRegistration(e,'Existing pane override','argv-only existing pane with stale environment');
 const thread=e.stdout.split('\n').map(l=>{try{return JSON.parse(l);}catch{return null;}}).find(v=>v?.type==='thread.started')?.thread_id;
 assert(thread,'actual Codex thread/session ID absent');
 const resumed=resume('codex',existing.arguments,thread);assert.deepEqual(resumed.slice(-2),['resume',thread]);
 // exec resume is the real noninteractive equivalent of the returned TUI resume
 // argv: same options, same actual session ID, no new environment capability.
 const resumeHelp=await run('codex',['exec','resume','--help']);assert(resumeHelp.stdout.includes('--skip-git-repo-check'));
 const r=await run('codex',[...resumed.slice(0,-2),...providerArgs,'exec','resume','--skip-git-repo-check','--json',thread,'Return owned provider marker.'],stale);
 assertCodexRegistration(r,'Existing pane override','argv-only real existing session resume');
 console.log('PASS actual argv-only existing pane and resumed session register own MCP with current override despite stale descriptor env');
 assert.throws(()=>setMode({root,mode:'global',claudeSettingsFile:request.claudeSettingsFile,claudeSkillDirectory:path.join(claudeDir,'skills'),codexHome}),/session-only-policy/);
 assert(!readCodex(codexHome).mcp_servers?.['shepherd-browser']);
 const outsideClaude=await run('claude',['-p','Return owned provider marker.','--output-format','stream-json','--verbose','--no-session-persistence','--model','owned-fixture-model']);
 const outsideInit=outsideClaude.stdout.split('\n').map(l=>{try{return JSON.parse(l);}catch{return null;}}).find(e=>e?.type==='system' && e.subtype==='init');
 assert(outsideInit);assert(!outsideInit.plugins?.some(p=>p.name==='shepherd'));assert(!outsideInit.skills?.some(p=>p.includes('shepherd-browser')));assert(!outsideInit.mcp_servers?.some(p=>p.name.includes('shepherd-browser')));
 const outsideCodex=await run('codex',['--profile','work',...providerArgs,'-c','mcp_servers.owned-other.enabled=false','exec','--skip-git-repo-check','--json','Return owned provider marker.']);
 const outsideRequests=outsideCodex.capture.requests.filter(v=>v.url.includes('responses'));
 assert(outsideRequests.length>0);assert(outsideRequests.every(v=>!v.tools.some(t=>/shepherd[-_]browser/.test(t))&&!v.system.includes(INSTRUCTIONS)));
 console.log('PASS ordinary CLI invocations outside Shepherd plans do not inherit Shepherd skill/MCP/instructions');
 console.log(JSON.stringify({localProviderRequests:requestCount,invocations:invocations.map(v=>({id:v.id,cli:v.cli,requests:v.requests.length})),providerPaths:[...new Set(invocations.flatMap(v=>v.requests.map(r=>r.url)))],passed:true}));
} finally {
 server.close();
 fs.rmSync(base,{recursive:true,force:true});
}
