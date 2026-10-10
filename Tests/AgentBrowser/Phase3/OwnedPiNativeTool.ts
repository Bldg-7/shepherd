import fs from 'node:fs';
import path from 'node:path';
import {Type} from '@sinclair/typebox';
import type {ExtensionAPI} from '@earendil-works/pi-coding-agent';

// Test-only explicit extension, copied into an owned private HOME. All model
// responses come from the caller's loopback fixture, never a vendor account.
export default function(pi: ExtensionAPI) {
  const root=process.env.HOME!;
  const config=JSON.parse(fs.readFileSync(path.join(root,'native-fixture.json'),'utf8'));
  const url=new URL(config.baseURL);
  if(url.hostname!=='127.0.0.1' || url.protocol!=='http:')throw new Error('owned endpoint required');
  pi.registerProvider('owned',{baseUrl:config.baseURL+'/v1',apiKey:'owned-placeholder',api:'openai-completions',
    models:[{id:'owned',name:'Owned fixture',reasoning:false,input:['text'],cost:{input:0,output:0,cacheRead:0,cacheWrite:0},contextWindow:32000,maxTokens:1024}]});
  const write=(file:string,value:unknown)=>fs.writeFileSync(path.join(root,file),JSON.stringify(value),{mode:0o600});
  pi.registerTool({name:'owned_browser_check',label:'Owned browser check',description:'Only the private local fixture page.',parameters:Type.Object({}),
    async execute(_id,_args,_signal,_update,ctx) {
      const call=(tool:string,args:Record<string,unknown>)=>config.backend==='adapter' ?
        ctx.executeTool('mcp',{server:'shepherd-browser',tool,args}) : ctx.executeTool('mcp__shepherd_browser__'+tool,args);
      const navigate=await call('browser_navigate',{url:config.baseURL+'/owned-page'});
      const snapshot=await call('browser_snapshot',{});
      const matched=JSON.stringify(snapshot.result).includes('OWNED_PI_NATIVE');
      const ok=!navigate.isError && !snapshot.isError && matched;
      write('native-tool.json',{ok,navigateError:navigate.isError,snapshotError:snapshot.isError,matched});
      if(!ok)throw new Error('owned native browser check failed');
      return {content:[{type:'text',text:'OWNED_NATIVE_BROWSER_OK'}],details:{ok}};
    }});
  pi.on('agent_settled',async()=>{write('settled.json',{settled:true});});
  pi.events.on('shepherd:pi-status:v1',(value:any)=>write('bridge-status.json',{state:value?.state}));
}
