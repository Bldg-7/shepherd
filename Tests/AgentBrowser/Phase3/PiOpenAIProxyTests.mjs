// Real public Pi OpenAI provider + provider composer, fake fetch only.
// Run with PI_AI_DIST and PI_CODING_DIST pointing to qualified public SDK code.
// No user settings/auth files, no login, agent launch or provider network request.
import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {registerPiApiProxy,openAIProxyFetch} from '../../../Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs';
const ai=process.env.PI_AI_DIST, coding=process.env.PI_CODING_DIST;
assert(ai && coding,'explicit SDK source paths required');
const {openaiProvider}=await import(pathToFileURL(path.join(ai,'providers/openai.js')));
const {composeModelProvider}=await import(pathToFileURL(path.join(coding,'core/provider-composer.js')));
const provider=openaiProvider(), base='http://127.0.0.1:24680/p/'+'ab'.repeat(16);
const handlers=new Map(), registered=new Map();let oauth=true, allowed=true, seen=[];
const pi={on:(name,fn)=>handlers.set(name,fn),registerProvider:(name,config)=>registered.set(name,config)};
assert(registerPiApiProxy(pi,'/synthetic/bootstrap.json',{env:{},captureAllowed:()=>allowed,read:()=>JSON.stringify({apiProxy:{baseURL:base}})}));
assert(!registered.has('openai'),'no global model endpoint override');
const signal=new AbortController().signal;
const ctx={mode:'tui',signal,sessionManager:{getSessionId:()=> 'native-session'},modelRegistry:{getProvider:name=>name==='openai'?provider:undefined,isUsingOAuth:()=>oauth}};
handlers.get('session_start')({},ctx);handlers.get('context')({},ctx);
const extension=registered.get('openai');assert(extension?.streamSimple && !('baseUrl' in extension));
const composed=composeModelProvider('openai',provider,{getProvider:()=>undefined},extension);
assert.deepEqual(composed.getModels(),provider.getModels(),'catalog, compat, thinking defaults and URLs preserved');
assert(composed.auth.oauth?.isSubscription);
const model=provider.getModels().find(m=>m.id==='gpt-6-astra')??provider.getModels()[0];
assert(model.api==='openai-responses' && model.baseUrl==='https://api.openai.com/v1');
const output={id:'message-1',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'synthetic answer',annotations:[]}]};
const response={id:'response-1',object:'response',created_at:0,status:'completed',model:model.id,output:[output],usage:{input_tokens:2,output_tokens:3,total_tokens:5,input_tokens_details:{cached_tokens:0},output_tokens_details:{reasoning_tokens:0}}};
const events=[{type:'response.created',response:{...response,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item:{...output,content:[]}},{type:'response.content_part.added',output_index:0,content_index:0,item_id:output.id,part:{type:'output_text',text:'',annotations:[]}},{type:'response.output_text.delta',output_index:0,content_index:0,item_id:output.id,delta:'synthetic answer'},{type:'response.output_item.done',output_index:0,item:output},{type:'response.completed',response}];
async function fakeFetch(input,init) {
  const request=new Request(input,init);
  seen.push({url:request.url,headers:request.headers,body:JSON.parse(await request.text())});
  return new Response(events.map(e=>'data: '+JSON.stringify(e)+'\n\n').join(''),{status:200,headers:{'Content-Type':'text/event-stream'}});
}
const context={messages:[{role:'user',content:[{type:'text',text:'synthetic question'}],timestamp:0}]};
const options={apiKey:'synthetic-chatgpt-direct-token',fetch:fakeFetch,signal,sessionId:'native-session',convertToLlm:x=>x,transformContext:x=>x,maxTokens:100,cacheRetention:'short',maxRetries:0,reasoning:'medium',headers:{'x-fixture':'retained'}};
const send=async (m=model,o=options)=>{const result=await composed.streamSimple(m,context,o).result();assert.notEqual(result.stopReason,'error',result.errorMessage);return seen.at(-1);};
let captured=await send();
assert.equal(captured.url,base+'/openai/v1/responses');
assert.equal(captured.headers.get('x-3rdr-pi-class'),'main');
assert.equal(captured.headers.get('x-3rdr-pi-session'),'native-session');
assert.equal(captured.headers.get('x-3rdr-pi-auth'),'chatgpt-direct');
assert.equal(captured.headers.get('x-fixture'),'retained');
// Compare with the original real provider's serialization. Changing baseUrl
// would break its isChatGPTSignIn branch and is detected by this comparison.
await provider.streamSimple(model,context,options).result();
assert.deepEqual(captured.body,seen.at(-1).body,'OAuth-specific body/cache/thinking semantics unchanged');
assert.equal(seen.at(-1).url,'https://api.openai.com/v1/responses');
assert(!('max_output_tokens' in captured.body),'SDK still recognizes ChatGPT sign-in');
assert(!captured.body.input.some(x=>x.type==='configuration_update'));
oauth=false;captured=await send(model,{...options,apiKey:'sk-proj-synthetic'});
assert.equal(captured.url,'https://api.openai.com/v1/responses');assert(!captured.headers.has('x-3rdr-pi-contract'));
oauth=true;captured=await send(model,{...options,apiKey:'sk-proj-override'});
assert.equal(captured.url,'https://api.openai.com/v1/responses');assert(!captured.headers.has('x-3rdr-pi-contract'));
captured=await send({...model,baseUrl:'https://custom.invalid/v1'});
assert.equal(captured.url,'https://custom.invalid/v1/responses');assert(!captured.headers.has('x-3rdr-pi-contract'));
captured=await send(model,{...options,signal:new AbortController().signal,maxTokens:1});
assert.equal(captured.headers.get('x-3rdr-pi-class'),'auxiliary');assert(!captured.headers.has('x-3rdr-pi-session'));
const compact=new AbortController().signal;handlers.get('session_before_compact')({signal:compact},ctx);
captured=await send(model,{...options,signal:compact});assert.equal(captured.headers.get('x-3rdr-pi-class'),'compaction');
allowed=false;captured=await send();assert.equal(captured.headers.get('x-3rdr-pi-class'),'auxiliary');allowed=true;
// Request-shaped fetch inputs, caller overrides and destination/method guards.
const calls=[];const transport=(...args)=>{calls.push(args);return Promise.resolve(new Response('ok'));};
const routed=openAIProxyFetch(base,transport,{'x-3rdr-pi-contract':'2','x-3rdr-pi-class':'main','x-3rdr-pi-session':'native-session'});
await routed(new Request('https://api.openai.com/v1/responses?fixture=yes',{method:'POST',headers:{Authorization:'Bearer synthetic-token'},body:'unchanged'}));
let request=new Request(...calls.at(-1));assert.equal(request.url,base+'/openai/v1/responses?fixture=yes');assert.equal(await request.text(),'unchanged');
assert.equal(request.redirect,'manual','redirects cannot carry local metadata to external origins');
await routed('https://api.openai.com/v1/responses',{method:'POST',headers:{authorization:'Bearer synthetic-token'},redirect:'error'});
assert.equal(calls.at(-1)[1].redirect,'error','stricter caller redirect policy is preserved');
for(const [url,method,authorization] of [['https://api.openai.com/v1/models','GET','Bearer synthetic-token'],['https://other.invalid/v1/responses','POST','Bearer synthetic-token'],['https://api.openai.com/v1/responses','POST','Bearer sk-test'],['https://api.openai.com/v1/responses','POST','Basic synthetic']]) {
 const init={method,headers:{authorization}};await routed(url,init);assert.equal(calls.at(-1)[0],url);assert.equal(calls.at(-1)[1],init);
}
const overridden={method:'POST',headers:{authorization:'Bearer sk-user-override'}};
await routed(new Request('https://api.openai.com/v1/responses',{method:'POST',headers:{authorization:'Bearer synthetic-token'}}),overridden);
assert.equal(calls.at(-1)[1],overridden,'effective header override cannot be routed as OAuth');
console.log('PASS real OpenAI SDK serialization/composition, OAuth-only fetch routing, API-key/custom endpoint preservation, main/compaction/warming and Request-input checks; fake fetch only');
