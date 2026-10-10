// Real owned herdr + integrated app service + installed interactive CLIs.
// A local provider, disposable HOME and private runtime/profile are mandatory.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawn, once, execFileSync} from '../../../Spikes/agent-browser-phase2/fixture-process.mjs';

const [appPath, output, ...options] = process.argv.slice(2);
assert(appPath && output);
let verifyIdleStop=false, selectedKind;
for(let i=0;i<options.length;i++){
 if(options[i]==='--verify-idle-stop'){assert(!verifyIdleStop,'duplicate safety option');verifyIdleStop=true;}
 else if(options[i]==='--agent-kind'){assert(selectedKind===undefined,'duplicate agent selection');selectedKind=options[++i];assert(['claude','codex'].includes(selectedKind),'agent kind must be claude or codex');}
 else assert.fail('unknown fixture option');
}
const agentKinds=selectedKind?[selectedKind]:['claude','codex'];
fs.mkdirSync(output, {recursive:true,mode:0o700});
fs.writeFileSync(path.join(output,'agent-selection.json'),JSON.stringify({agentKinds,isolatedAgentCase:selectedKind!==undefined,verifyIdleStop}),{mode:0o600});
const root=fs.mkdtempSync('/tmp/shepherd-launch-');
fs.chmodSync(root,0o700);
const home=path.join(root,'home');
for(const dir of [home,path.join(home,'.claude'),path.join(home,'.codex')]) fs.mkdirSync(dir,{mode:0o700});
const session='phase3-owned';
const socket=path.join(home,'.config/herdr/sessions',session,'herdr.sock');
const environment={PATH:process.env.PATH,HOME:home,CLAUDE_CONFIG_DIR:path.join(home,'.claude'),CODEX_HOME:path.join(home,'.codex'),
 HERDR_CONFIG_PATH:path.join(root,'herdr.toml'),TERM:'xterm-256color',LANG:'en_US.UTF-8',
 ANTHROPIC_API_KEY:'owned-local-fixture',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1',DISABLE_TELEMETRY:'1',DISABLE_ERROR_REPORTING:'1',CLAUDE_CODE_SKIP_OAUTH:'1',NO_PROXY:'127.0.0.1,localhost'};
const captures=[];
const provider=http.createServer(async(req,res)=>{
 let body='';for await(const b of req)body+=b;
 if(req.url==='/owned-page'){res.writeHead(200,{'content-type':'text/html'});res.end('<title>Owned launcher browser</title><p>Local only</p>');return;}
 const value=JSON.parse(body||'{}');
 if(req.url.includes('count_tokens')){res.writeHead(200,{'content-type':'application/json'});res.end('{"input_tokens":100}');return;}
 const tools=(value.tools??[]).flatMap(t=>Array.isArray(t.tools)?t.tools.map(c=>t.name+'.'+c.name):[t.name??t.function?.name]);
 captures.push({url:req.url,tools,model:value.model});
 if(req.url.includes('messages')){
  const message={id:'msg_owned',type:'message',role:'assistant',model:value.model,content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:10,output_tokens:1}};
  if(value.stream){res.writeHead(200,{'content-type':'text/event-stream'});const send=(event,data)=>res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
   send('message_start',{type:'message_start',message});send('content_block_start',{type:'content_block_start',index:0,content_block:{type:'text',text:''}});
   send('content_block_delta',{type:'content_block_delta',index:0,delta:{type:'text_delta',text:'OWNED_PROVIDER_OK'}});
   send('content_block_stop',{type:'content_block_stop',index:0});send('message_delta',{type:'message_delta',delta:{stop_reason:'end_turn',stop_sequence:null},usage:{output_tokens:3}});send('message_stop',{type:'message_stop'});res.end();
  }else{res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({...message,content:[{type:'text',text:'OWNED_PROVIDER_OK'}],stop_reason:'end_turn'}));}
 }else if(req.url.includes('responses')){
  res.writeHead(200,{'content-type':'text/event-stream'});
  const message={type:'message',id:'msg_owned',status:'completed',role:'assistant',content:[{type:'output_text',text:'OWNED_PROVIDER_OK',annotations:[]}]};
  const response={id:'resp_owned',object:'response',created_at:0,status:'completed',output:[message],usage:{input_tokens:10,output_tokens:3,total_tokens:13}};
  for(const event of [{type:'response.created',response:{...response,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item:{...message,status:'in_progress',content:[]}},{type:'response.content_part.added',item_id:'msg_owned',output_index:0,content_index:0,part:{type:'output_text',text:'',annotations:[]}},{type:'response.output_text.delta',item_id:'msg_owned',output_index:0,content_index:0,delta:'OWNED_PROVIDER_OK'},{type:'response.output_item.done',output_index:0,item:message},{type:'response.completed',response}])res.write(`data: ${JSON.stringify(event)}\n\n`);
  res.end();
 }else{res.writeHead(404);res.end('{}');}
});
await new Promise(r=>provider.listen(0,'127.0.0.1',r));
const url='http://127.0.0.1:'+provider.address().port;
environment.ANTHROPIC_BASE_URL=url;
fs.writeFileSync(path.join(home,'.claude/.claude.json'),JSON.stringify({hasCompletedOnboarding:true,theme:'dark',customApiKeyResponses:{approved:['owned-local-fixture'],rejected:[]},projects:{[fs.realpathSync(home)]:{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true}}}),{mode:0o600});
fs.writeFileSync(path.join(home,'.claude/settings.json'),'{}',{mode:0o600});
fs.writeFileSync(path.join(home,'.codex/config.toml'),`check_for_update_on_startup=false\nmodel_provider="owned"\nmodel="owned-fixture-model"\n[model_providers.owned]\nname="Owned local provider"\nbase_url="${url}"\nwire_api="responses"\nrequires_openai_auth=false\nsupports_websockets=false\n[projects."${fs.realpathSync(home)}"]\ntrust_level="trusted"\n`,{mode:0o600});
fs.writeFileSync(environment.HERDR_CONFIG_PATH,'[update]\nversion_check=false\nmanifest_check=false\n',{mode:0o600});
// Mirrors AgentState.isQuiescent's strict herdr lifecycle enumeration.
const isQuiescent=state=>state==='idle' || state==='done';
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,seconds=20){const end=Date.now()+seconds*1000;while(Date.now()<end){if(await test())return;await delay(100);}throw Error('Owned lifecycle condition timed out');}
async function cli(args, parseJSON=true){const child=spawn('herdr',['--session',session,...args],{env:environment,cwd:home,stdio:['ignore','pipe','pipe'],timeout:35000});let out='',err='';child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);const [code,signal]=await once(child,'exit',{signal:AbortSignal.timeout(40000)});assert.equal(signal,null);if(code!==0)throw Error('Owned herdr CLI failed: '+err);return parseJSON?JSON.parse(out):out;}
function read(name){return JSON.parse(fs.readFileSync(path.join(output,name),'utf8'));}
function pass(name){console.log('PASS: '+name);}
// Read actual CLI-written transcripts only; this fixture never manufactures
// conversation files or treats a startup hook ID as persisted conversation.
function savedConversation(kind,id,cwd){
 const directory=path.join(kind==='claude'?environment.CLAUDE_CONFIG_DIR:environment.CODEX_HOME,kind==='claude'?'projects':'sessions');
 if(!fs.existsSync(directory))return false;
 const candidates=[];
 function visit(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isSymbolicLink())continue;if(entry.isDirectory())visit(file);else if(entry.name.endsWith('.jsonl') && entry.name.includes(id))candidates.push(file);}}
 visit(directory);
 const canonical=fs.realpathSync(cwd);
 return candidates.some(file=>{
  const rows=fs.readFileSync(file,'utf8').split('\n').flatMap(line=>{try{return [JSON.parse(line)];}catch{return [];}});
  if(kind==='claude'){
   const matching=rows.filter(r=>r.sessionId===id && r.cwd && fs.realpathSync(r.cwd)===canonical && r.isSidechain!==true);
   return matching.some(r=>r.type==='user') && matching.some(r=>r.type==='assistant');
  }
  if(!rows.some(r=>r.type==='session_meta' && r.payload?.id===id && r.payload?.cwd && fs.realpathSync(r.payload.cwd)===canonical))return false;
  const messages=rows.filter(r=>r.type==='response_item' && r.payload?.type==='message');
  return messages.some(r=>r.payload.role==='user') && messages.some(r=>r.payload.role==='assistant');
 });
}
let server,app;let healthy=false;
const descriptors=[];
const sessionPolls=[];
function saveSessionDiagnostics(){
 try{fs.writeFileSync(path.join(output,'codex-raw-session-polls.json'),JSON.stringify({capacity:256,polls:sessionPolls},null,2),{mode:0o600});}catch{}
 try{const hookLog=path.join(home,'.codex/hook-diagnostics.json');if(fs.existsSync(hookLog))fs.writeFileSync(path.join(output,'codex-hook-diagnostics.json'),fs.readFileSync(hookLog),{mode:0o600});}catch{}
}
async function rawSessionBoundary(phase,pane){
 try{
  const snapshot=(await cli(['api','snapshot'])).result.snapshot;
  const agents=(await cli(['agent','list'])).result.agents;
  const sample=(rows)=>{
   const row=rows.find(r=>r.pane_id===pane.pane_id && r.terminal_id===pane.terminal_id);
   const ref=row?.agent_session;
   const type=value=>value===null?'null':Array.isArray(value)?'array':typeof value;
   const fields=Object.fromEntries(['source','agent','kind','value'].map(key=>{
    const value=ref?.[key];const present=ref && typeof ref==='object' && Object.hasOwn(ref,key);
    const safe=typeof value==='string' && /^[A-Za-z0-9_:./-]{0,256}$/.test(value)?value:typeof value==='boolean'||typeof value==='number'||value===null?value:undefined;
    return [key,{present:!!present,type:type(value),value:safe,redacted:typeof value==='string' && safe===undefined}];
   }));
   const parsed=ref && typeof ref==='object' && ['source','agent','kind','value'].every(k=>typeof ref[k]==='string') && ['id','path'].includes(ref.kind);
   const compatible=!!parsed && ref.kind==='id' && ['codex'].includes(ref.agent) && /^[A-Za-z0-9_-]{1,128}$/.test(ref.value);
   return {rowPresent:!!row,panePresent:rows.some(r=>r.pane_id===pane.pane_id),terminalPresent:rows.some(r=>r.terminal_id===pane.terminal_id),
    identity:row?{pane:row.pane_id,terminal:row.terminal_id}:null,
    status:row?.agent_status,revision:row?.revision,sequence:row?.state_change_seq,agent:row?.agent,
    revisionPresent:!!row && Object.hasOwn(row,'revision'),sequencePresent:!!row && Object.hasOwn(row,'state_change_seq'),
    sessionPresent:!!row && Object.hasOwn(row,'agent_session'),sessionType:type(ref),fields,parsed:!!parsed,compatible,
    readinessPresent:!!row && Object.hasOwn(row,'interactive_ready'),readinessType:type(row?.interactive_ready),readiness:row?.interactive_ready,
    pendingPresent:!!row && Object.hasOwn(row,'launch_pending'),pendingType:type(row?.launch_pending),pending:row?.launch_pending};
  };
  sessionPolls.push({at:new Date().toISOString(),phase,pane:pane.pane_id,terminal:pane.terminal_id,snapshot:sample(snapshot.panes),agentList:sample(agents)});
  if(sessionPolls.length>256)sessionPolls.shift();
 }catch{sessionPolls.push({at:new Date().toISOString(),phase,captureFailed:true});if(sessionPolls.length>256)sessionPolls.shift();}
 saveSessionDiagnostics();
}
try{
 const fd=fs.openSync(path.join(output,'herdr.log'),'w',0o600);descriptors.push(fd);
 server=spawn('herdr',['--session',session,'server'],{env:environment,cwd:home,stdio:['ignore',fd,fd],timeout:220000});
 await until(()=>fs.existsSync(socket));
 const first=await cli(['workspace','create','--label','Owned initial shell','--env','OWNED_ENV=value with spaces=equals','--no-focus']);
 const pane=first.result.root_pane;
 const info=(await cli(['pane','process-info','--pane',pane.pane_id])).result.process_info;
 assert(info.shell_pid && info.foreground_processes.some(p=>p.pid===info.shell_pid));pass('real created shell has actual foreground shell readiness');
 const listed=(await cli(['agent','list'])).result.agents;assert(Array.isArray(listed));pass('actual agent.list schema');
 fs.writeFileSync(path.join(output,'input.json'),JSON.stringify({root,socket,session,node:process.execPath}),{mode:0o600});
 const appFD=fs.openSync(path.join(output,'app.log'),'w',0o600);descriptors.push(appFD);
 app=spawn(appPath,[],{env:{...environment,SHEPHERD_AGENT_LAUNCH_FIXTURE:output,SHEPHERD_BROWSER_TEST_ROOT:path.join(root,'profile')},cwd:home,stdio:['ignore',appFD,appFD],timeout:220000});
 await until(()=>fs.existsSync(path.join(output,'ready.json'))||fs.existsSync(path.join(output,'failed.json')),40);
 assert(!fs.existsSync(path.join(output,'failed.json')),fs.existsSync(path.join(output,'failed.json'))?JSON.stringify(read('failed.json')):'');
 pass('real integrated app installs verified bundle offline with explicit owned host context');
 const outcomes=[];
 // Supported built-in CLI state hooks are installed only into this disposable
 // HOME/CLAUDE_CONFIG_DIR/CODEX_HOME, never a production account/profile.
 for(const kind of ['claude','codex']){
  const setup=await cli(['integration','install',kind],false);
  fs.writeFileSync(path.join(output,kind+'-herdr-integration.txt'),setup,{mode:0o600});
  if(kind==='codex'){
   const resource=path.join(home,'.codex/CodexHookDiagnostics.py');
   fs.copyFileSync('Tests/AgentBrowser/Phase3/CodexHookDiagnostics.py',resource);fs.chmodSync(resource,0o600);
   execFileSync('python3',[resource,'install',path.join(home,'.codex/herdr-agent-state.sh'),output],{timeout:5000});
  }
 }
 for(const kind of agentKinds){
  fs.rmSync(path.join(output,'result.json'),{force:true});fs.rmSync(path.join(output,'selection.json'),{force:true});fs.writeFileSync(path.join(output,'command'),kind);
  await until(()=>fs.existsSync(path.join(output,'selection.json')),15);
  const selection=read('selection.json');
  const attach=spawn('python3',['Tests/AgentBrowser/Phase3/OwnedHerdrPTY.py','--session',session,'--terminal',selection.terminal,'--output',path.join(output,kind+'-terminal.txt'),'--closed-marker',path.join(output,kind+'-closed.json')],{env:environment,stdio:['ignore','pipe','pipe'],timeout:75000});
  let attachError='';attach.stderr.on('data',b=>attachError+=b);attach.stdout.resume();
  await until(()=>fs.existsSync(path.join(output,'result.json')),50);
  if(verifyIdleStop && kind==='codex'){
   await until(async()=>{
    const screen=await cli(['pane','read',selection.pane,'--source','recent-unwrapped','--format','text'],false);
    fs.writeFileSync(path.join(output,'codex-hook-review-visible.txt'),screen,{mode:0o600});
    if(/Trust\s*all\s*and\s*continue/i.test(screen)){
     const acknowledgement=await cli(['agent','send-keys',selection.pane,'1','enter']);
     await delay(200);
     const reviewed=await cli(['pane','read',selection.pane,'--source','visible','--format','text'],false);
     fs.writeFileSync(path.join(output,'codex-review-after-enter.txt'),reviewed,{mode:0o600});
     fs.writeFileSync(path.join(output,'codex-review-key-ack.json'),JSON.stringify(acknowledgement),{mode:0o600});
     await cli(['agent','send-keys',selection.pane,'enter']);await delay(150);
     const hookScreen=await cli(['pane','read',selection.pane,'--source','visible','--format','text'],false);
     fs.writeFileSync(path.join(output,'codex-single-hook-review.txt'),hookScreen,{mode:0o600});
     assert(hookScreen.includes(home+'/.codex/herdr-agent-state.sh') && hookScreen.includes('Press t to trust; esc to go back'));
     const ownedHook=fs.lstatSync(path.join(home,'.codex/herdr-agent-state.sh'));assert(!ownedHook.isSymbolicLink() && ownedHook.uid===process.getuid());
     assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(home,'.codex/herdr-agent-state.sh'))).digest('hex'),read('codex-hook-hashes.json').instrumented,'review EXACT instrumented owned single hook');
     await cli(['agent','send-keys',selection.pane,'t']);await delay(150);
     for(let back=0;back<3;back++){
      const currentScreen=await cli(['pane','read',selection.pane,'--source','visible','--format','text'],false);
      fs.writeFileSync(path.join(output,'codex-reviewed-current-'+back+'.txt'),currentScreen,{mode:0o600});
      if(!/esc to go back|esc to close|enter to review hooks|Press enter to confirm/i.test(currentScreen))break;
      await cli(['agent','send-keys',selection.pane,'esc']);await delay(150);
     }
     pass('explicitly trusted ONLY reviewed owned SessionStart hook and closed review modal');return true;
    }
    return /Ask Codex/.test(screen);
   },5);
  }
  const result=read('result.json');outcomes.push(result);
  const snapshot=(await cli(['api','snapshot'])).result.snapshot;
  const actual=snapshot.panes.find(p=>p.terminal_id===result.selectedTerminal);
  assert(actual,'service kept and selected the launcher-created actual terminal');
  const processInfo=(await cli(['pane','process-info','--pane',actual.pane_id])).result.process_info;
  if(verifyIdleStop && kind==='codex'){
   const polls=[],started=Date.now();
   const field=(row,key)=>row && Object.hasOwn(row,key)?{present:true,value:row[key]}:{present:false};
   const persist=outcome=>fs.writeFileSync(path.join(output,'codex-readiness-polls.json'),JSON.stringify({outcome,budgetMs:10000,capacity:128,polls},null,2),{mode:0o600});
   try{
    await until(async()=>{
     const agents=(await cli(['agent','list'])).result.agents;
     const a=agents.find(a=>a.terminal_id===actual.terminal_id);
     polls.push({at:new Date().toISOString(),elapsedMs:Date.now()-started,terminalPresent:!!a,
      panePresent:agents.some(a=>a.pane_id===actual.pane_id),samePaneAndTerminal:a?.pane_id===actual.pane_id,
      row:Object.fromEntries(['pane_id','terminal_id','agent','agent_name','agent_status','interactive_ready','launch_pending'].map(key=>[key,field(a,key)]))});
     if(polls.length>128)polls.shift();
     return isQuiescent(a?.agent_status) && a?.interactive_ready===true && a?.launch_pending!==true;
    },10);
    persist('success');
   }catch(original){
    try{persist('failure');}catch{}
    // ONE finite real CLI request per capture. Exclude screen previews, argv,
    // session/conversation values and arbitrary error text from explain output.
    const allowed=new Set(['agent','evaluated_rules','evidence','id','matched','priority','region','state','all_count','any_count','not_count','region_bytes','matched_rule','manifest_source','manifest_version','screen_detection_skipped','skip_state_update','visible_blocker','visible_idle','visible_working','local_override_shadowing_remote']);
    const sanitize=value=>Array.isArray(value)?value.map(sanitize):value && typeof value==='object'?Object.fromEntries(Object.entries(value).filter(([key])=>allowed.has(key)).map(([key,v])=>[key,sanitize(v)])):value;
    try{const explanation=await cli(['agent','explain',actual.pane_id,'--json']);fs.writeFileSync(path.join(output,'codex-readiness-timeout-explain.json'),JSON.stringify(sanitize(explanation),null,2),{mode:0o600});}
    catch{try{fs.writeFileSync(path.join(output,'codex-readiness-timeout-explain.json'),'{"captureFailed":true}',{mode:0o600});}catch{}}
    try{
     const screen=await cli(['pane','read',actual.pane_id,'--source','visible','--format','text'],false);
     // Allow only known UI-only lines; never retain arbitrary composer/conversation.
     const safe=screen.split('\n').map(line=>{
      const text=line.trim();
      return /^(?:[›❯]\s*Ask Codex(?: to do anything)?|(?:[│╭╰─ ]*)OpenAI Codex \(v[\d.]+\)(?:[│ ]*)|SessionStart(?: hooks)?|Press t to trust; esc to go back|Trust\s+(?:Trusted|New hook - review required)|\[x\] Hook 1|Event\s+SessionStart|(?:[?]\s+for shortcuts|\d+% context left))$/.test(text)?text:(text?'[redacted non-UI line]':'');
     }).join('\n');
     fs.writeFileSync(path.join(output,'codex-readiness-timeout-visible.txt'),safe,{mode:0o600});
    }catch{try{fs.writeFileSync(path.join(output,'codex-readiness-timeout-visible.txt'),'[capture failed]\n',{mode:0o600});}catch{}}
    throw original;
   }
  }else if(verifyIdleStop)await until(async()=>{const a=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);return isQuiescent(a?.agent_status) && a?.interactive_ready===true && a?.launch_pending!==true;},10);
  if(kind==='codex')await rawSessionBoundary('initial',actual);
  const rows=(await cli(['agent','list'])).result.agents;
  const explanation=await cli(['agent','explain',actual.pane_id,'--json']);
  fs.writeFileSync(path.join(output,kind+'-herdr-explain.json'),JSON.stringify(explanation,null,2),{mode:0o600});
  fs.writeFileSync(path.join(output,kind+'-inspection.json'),JSON.stringify({pane:actual,processInfo,agents:rows},(key,value)=>key==='argv'||key==='cmdline'?undefined:value,2),{mode:0o600});
  if(result.ok){const ready=rows.find(a=>a.terminal_id===actual.terminal_id);assert.equal(ready.interactive_ready,true);assert.notEqual(ready.launch_pending,true);pass('real '+kind+' agent.start interactive readiness');}
  else{assert.equal(result.ok,false);pass('real '+kind+' startup failure retains/selects exactly one created shell or agent');}
  assert.equal(snapshot.panes.length,2,'no hidden duplicate pane/start');
  if(verifyIdleStop && result.ok){
   const before=rows.find(a=>a.terminal_id===actual.terminal_id);
   assert(isQuiescent(before.agent_status));
   fs.writeFileSync(path.join(output,kind+'-empty-composer.ansi'),await cli(['pane','read',actual.pane_id,'--source','visible','--format','ansi'],false),{mode:0o600});
   await cli(['agent','send-keys',actual.pane_id,'ctrl+d']);
   let stopped=false;
   const stopDeadline=Date.now()+5000;
   let second=false;
   while(Date.now()<stopDeadline){
    const state=(await cli(['api','snapshot'])).result.snapshot.panes.find(p=>p.pane_id===actual.pane_id);
    assert.equal(state?.terminal_id,actual.terminal_id,'stop must retain exact terminal');
    const foreground=(await cli(['pane','process-info','--pane',actual.pane_id])).result.process_info;
    if(foreground.foreground_processes.length>0 && foreground.foreground_processes.every(p=>p.pid===foreground.shell_pid)){stopped=true;break;}
    if(kind==='claude' && !second && Date.now()>stopDeadline-4900){
     const current=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);
     assert(isQuiescent(current?.agent_status));assert.equal(current?.interactive_ready,true);
     assert.equal(current?.state_change_seq,before.state_change_seq);assert.deepEqual(current?.agent_session,before.agent_session);
     await cli(['agent','send-keys',actual.pane_id,'ctrl+d']);second=true;
    }
    await delay(100);
   }
   assert(stopped,'actual bounded idle-to-shell Ctrl-D transition');
   pass('actual '+kind+' idle-to-shell stop retains same terminal without PID/name kill or arbitrary shell');
   await cli(['agent','start','owned-direct-'+kind,'--kind',kind,'--pane',actual.pane_id,'--timeout','15000','--']);
   await until(async()=>{const a=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);return isQuiescent(a?.agent_status) && a?.interactive_ready===true && a?.launch_pending!==true;},10);
   if(kind==='claude'){
    await until(async()=>{const a=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);return a?.agent_session?.kind==='id' && a?.agent_session?.agent===kind && read('status.json').panes.some(p=>p.terminal===actual.terminal_id && p.status==='Browser injection missing');},10);
    const beforeUnsaved=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);
    assert(!savedConversation(kind,beforeUnsaved.agent_session.value,fs.realpathSync(home)));
    const beforeProcess=(await cli(['pane','process-info','--pane',actual.pane_id])).result.process_info;
    fs.rmSync(path.join(output,'result.json'),{force:true});fs.writeFileSync(path.join(output,'command'),'resume-unpersisted-'+kind);
    await until(()=>fs.existsSync(path.join(output,'result.json')),15);
    const rejected=read('result.json');assert.equal(rejected.ok,false);assert(rejected.error.includes('no verified saved conversation'));
    const afterUnsaved=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);
    const afterProcess=(await cli(['pane','process-info','--pane',actual.pane_id])).result.process_info;
    assert.deepEqual(afterProcess.foreground_processes,beforeProcess.foreground_processes);assert.deepEqual(afterUnsaved.agent_session,beforeUnsaved.agent_session);
    assert.equal(afterUnsaved.interactive_ready,true);assert(isQuiescent(afterUnsaved.agent_status));
    fs.writeFileSync(path.join(output,'unpersisted-session-retained.json'),JSON.stringify({result:rejected,terminal:actual.terminal_id,session:afterUnsaved.agent_session.value,foregroundUnchanged:true}),{mode:0o600});
    pass('unpersisted startup ID refused BEFORE stop; original live agent/session/foreground retained');
   }
   const captureStart=captures.length;
   await cli(['agent','prompt',actual.pane_id,'Return the owned provider marker.']);
   await until(async()=>{
    const current=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);
    const screen=await cli(['pane','read',actual.pane_id,'--source','visible','--format','text'],false);
    return captures.slice(captureStart).some(c=>/messages|responses/.test(c.url)) && screen.includes('OWNED_PROVIDER_OK') &&
     isQuiescent(current?.agent_status) && current?.interactive_ready===true && current?.agent_session?.kind==='id' &&
     current?.agent_session?.agent===kind && savedConversation(kind,current.agent_session.value,fs.realpathSync(home));
   },20);
   await until(async()=>{const a=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);fs.writeFileSync(path.join(output,kind+'-direct-observation.json'),JSON.stringify(a??{},null,2),{mode:0o600});fs.writeFileSync(path.join(output,kind+'-direct-screen.txt'),await cli(['pane','read',actual.pane_id,'--source','visible','--format','text'],false),{mode:0o600});return isQuiescent(a?.agent_status) && a?.interactive_ready===true && a?.agent_session?.kind==='id' && a?.agent_session?.agent===kind;},15);
   fs.writeFileSync(path.join(output,kind+'-direct-compatible-session.json'),JSON.stringify((await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id),null,2),{mode:0o600});
   assert(savedConversation(kind,JSON.parse(fs.readFileSync(path.join(output,kind+'-direct-compatible-session.json'),'utf8')).agent_session.value,fs.realpathSync(home)));
   pass('actual uninjected '+kind+' completed provider turn and saved compatible session ID in owned config/cwd');
   const originalSession=JSON.parse(fs.readFileSync(path.join(output,kind+'-direct-compatible-session.json'),'utf8')).agent_session.value;
   if(kind==='codex')await rawSessionBoundary('direct',actual);
   await until(()=>read('status.json').panes.some(p=>p.terminal===actual.terminal_id && p.canResume===true),10);
   fs.rmSync(path.join(output,'result.json'),{force:true});fs.writeFileSync(path.join(output,'command'),'resume-'+kind);
   if(kind==='codex'){
    try{await until(async()=>{await rawSessionBoundary('resumed',actual);return fs.existsSync(path.join(output,'result.json'));},40);}finally{saveSessionDiagnostics();}
   }else await until(()=>fs.existsSync(path.join(output,'result.json')),40);
   const resumed=read('result.json');assert.equal(resumed.ok,true,JSON.stringify(resumed));assert.equal(resumed.selectedTerminal,actual.terminal_id);
   const resumedAgent=(await cli(['agent','list'])).result.agents.find(a=>a.terminal_id===actual.terminal_id);
   assert.equal(resumedAgent.agent_session.value,originalSession);
   fs.writeFileSync(path.join(output,kind+'-resume-evidence.json'),JSON.stringify({originalSession,resumedAgent,result:resumed},null,2),{mode:0o600});
   pass('actual user-requested '+kind+' resume keeps same real session ID/terminal with argv-only browser preparation');
  }
  // Test-only pane close removes this fixture's work. Production launch failure
  // never closes a pane. Server terminal teardown is not claimed as idle resume.
  await cli(['pane','close',actual.pane_id]);
  fs.writeFileSync(path.join(output,kind+'-closed.json'),JSON.stringify({terminal:actual.terminal_id,pane:actual.pane_id,session}),{mode:0o600});
  const [attachCode,attachSignal]=await once(attach,'exit');assert.equal(attachSignal,null);assert.equal(attachCode,0,attachError);
  pass('actual owned '+kind+' PTY attach naturally ends on owned pane close');
 }
 await until(()=>read('status.json').panes.length===1,10);
 fs.writeFileSync(path.join(output,'command'),'quit');
 let appOutcome;
 try{appOutcome=await once(app,'exit',{signal:AbortSignal.timeout(45000)});}
 catch(error){if(app.exitCode===null && app.signalCode===null)execFileSync('/usr/bin/sample',[String(app.pid),'1','-file',path.join(output,'owned-app-shutdown.sample.txt')],{timeout:5000});throw error;}
 const [appCode,appSignal]=appOutcome;assert.equal(appCode,0);assert.equal(appSignal,null);
 assert.equal(read('finished.json').natural,true);pass('integrated service app natural shutdown with no agents/MCP connections');
 await cli(['session','stop',session,'--json']);const [serverCode,serverSignal]=await once(server,'exit');assert.equal(serverCode,0);assert.equal(serverSignal,null);
 fs.writeFileSync(path.join(output,'lifecycle-evidence.json'),JSON.stringify({agentKinds,isolatedAgentCase:selectedKind!==undefined,outcomes,providerCaptures:captures,interactiveReadiness:outcomes.every(r=>r.ok),actualBrowserToolUse:false,actualHerdrChild:false,idleResume:false,idleStopSafetyGateRequested:verifyIdleStop,appNaturalExit:true,serverNaturalExit:true},null,2),{mode:0o600});
 healthy=true;console.log('OWNED HERDR LAUNCH LIFECYCLE PASS ['+agentKinds.join(',')+'] (isolated case is not fullPhase3; readiness/tool/child/resume limitations are separate)');
}finally{
 saveSessionDiagnostics();
 await new Promise(r=>provider.close(r));
 for(const fd of descriptors)fs.closeSync(fd);
 if(healthy)fs.rmSync(root,{recursive:true,force:true});
 else{fs.writeFileSync(path.join(output,'retained-owned-root.txt'),root,{mode:0o600});
  // The outer identity-checking finite runner owns failure cleanup. No
  // timeout/forced cleanup can become a healthy gate or fabricated readiness.
  if(server && server.exitCode===null)try{await cli(['session','stop',session,'--json']);}catch{}
 }
}
