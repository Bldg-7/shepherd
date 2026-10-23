// Deterministic public agent-loop execution with a fake stream delegate.
// No CLI/agent process, model API, tools, auth lookup, transcript or settings I/O.
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {registerPiApiProxy} from '../../../Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs';

const {runAgentLoop}=await import(pathToFileURL(process.argv[2]).href);
const base='http://127.0.0.1:24680/p/'+'ab'.repeat(16);
let assertions=0;
for(const provider of ['anthropic','openai-codex']) {
  const handlers=new Map(), providers=[]; let observed;
  const signal=new AbortController().signal;
  const model={id:'synthetic',provider,api:provider==='anthropic'?'anthropic-messages':'openai-codex-responses',
    baseUrl:provider==='anthropic'?base:base+'/backend-api',reasoning:false,input:['text'],maxTokens:100,contextWindow:1000};
  const message={role:'assistant',content:[{type:'text',text:'synthetic response'}],api:model.api,provider,model:model.id,
    stopReason:'stop',timestamp:0,usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}}};
  const delegate=(m,c,o)=>{
    observed=o;
    return {async *[Symbol.asyncIterator](){yield {type:'done',reason:'stop',message};},result:async()=>message};
  };
  const pi={on:(name,fn)=>handlers.set(name,fn),registerProvider:(name,config)=>providers.push([name,config])};
  assert(registerPiApiProxy(pi,'/owned/bootstrap.json',{env:{},captureAllowed:()=>true,read:()=>JSON.stringify({apiProxy:{baseURL:base}})}));
  const ctx={mode:'tui',signal,sessionManager:{getSessionId:()=> 'native_session'},modelRegistry:{getProvider:()=>({streamSimple:delegate})}};
  handlers.get('session_start')({},ctx);
  const wrapper=providers.findLast(([name])=>name===provider)[1].streamSimple;
  const config={model,sessionId:'native_session',apiKey:'synthetic-only',convertToLlm:messages=>messages,
    transformContext:async messages=>{handlers.get('context')({messages},ctx);return messages;}};
  const result=await runAgentLoop([{role:'user',content:[{type:'text',text:'synthetic prompt'}],timestamp:0}],
    {messages:[]},config,()=>{},signal,wrapper);
  assert.equal(result.at(-1).content[0].text,'synthetic response');
  assert.equal(observed.headers['x-3rdr-pi-class'],'main');
  assert.equal(observed.headers['x-3rdr-pi-session'],'native_session');
  assert.equal(observed.signal,signal);assert.equal(observed.convertToLlm,config.convertToLlm);
  const saved=observed;
  wrapper(model,{messages:[]},{...saved,signal:new AbortController().signal,maxTokens:1,maxRetries:0});
  assert.equal(observed.headers['x-3rdr-pi-class'],'auxiliary');
  assert.equal(observed.maxTokens,1);assert.equal(observed.maxRetries,0);
  const compact=new AbortController().signal;
  handlers.get('session_before_compact')({signal:compact},ctx);
  wrapper(model,{messages:[]},{signal:compact,sessionId:'separate-routing-id',cacheRetention:'none'});
  assert.equal(observed.headers['x-3rdr-pi-class'],'compaction');
  assert.equal(observed.headers['x-3rdr-pi-session'],'native_session');
  assert.equal(observed.cacheRetention,'none');
  assertions+=11;
}
console.log(`PASS ${assertions} synthetic SDK-loop proxy assertions; no provider requests`);
