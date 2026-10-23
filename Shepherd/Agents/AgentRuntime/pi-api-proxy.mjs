import path from 'node:path';
import {protectedRead} from './protected-read.mjs';

// App-bundled, explicitly prepared Pi only. Endpoint overrides preserve model
// catalogs, OAuth and user options. No requests are made by this extension.
const BASE=/^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/p\/[0-9a-f]{32}$/;
const SESSION=/^[A-Za-z0-9_-]{1,128}$/;
export const PROXIED_PROVIDERS=['anthropic','openai-codex'];
const APIS={anthropic:'anthropic-messages','openai-codex':'openai-codex-responses'};
const OWNED_HEADERS=new Set(['x-3rdr-pi-session','x-3rdr-pi-class','x-3rdr-pi-contract']);

export function apiProxyBase(bootstrap, read = protectedRead) {
  try {
    if(typeof bootstrap !== 'string' || !path.isAbsolute(bootstrap)) return null;
    const manifest=JSON.parse(read(path.join(path.dirname(bootstrap),'launch.json')));
    const base=manifest?.apiProxy?.baseURL;
    const match=typeof base === 'string' && BASE.exec(base);
    return match && +match[1] <= 65535 ? base : null;
  } catch { return null; }
}

export function registerPiApiProxy(pi, bootstrap, {read = protectedRead, env = process.env, captureAllowed = (_session) => false} = {}) {
  // An inherited bootstrap is not a child's own launch/owner reservation. The
  // interactive bridge does not qualify headless children; do not reuse a
  // parent's route to redirect or label their requests.
  if(env.PI_SUBAGENT_CHILD || env.PI_SUBAGENT_PARENT_SESSION) return false;
  const base=apiProxyBase(bootstrap,read);
  if(!base) return false;
  for(const provider of PROXIED_PROVIDERS) pi.registerProvider(provider,{baseUrl:provider==='anthropic'?base:base+'/backend-api'});

  // Request-local, weakly held operation signals, NOT an agent_start/main flag.
  // Verified in Pi1.3.0/1.4.0: agent-loop spreads its config (including these
  // callbacks) into options and uses ctx.signal. Compaction supplies its own
  // event.signal; branch summaries have a separate signal. Warming replays the
  // saved options but replaces signal and maxTokens=1, for either provider.
  let signals=new WeakMap(), active=false;
  const installed=new Set();
  const remember=(signal,ctx,kind)=>{
    if(!active || ctx?.mode!=='tui' || !signal || typeof signal!=='object' || signal.aborted) return;
    const session=ctx.sessionManager?.getSessionId?.();
    if(typeof session==='string' && SESSION.test(session) && captureAllowed(session)) signals.set(signal,{session,kind});
    else signals.delete(signal);
  };
  pi.on('context',(_event,ctx)=>{if(active) remember(ctx?.signal,ctx,'main');});
  pi.on('session_before_compact',(event,ctx)=>remember(event?.signal,ctx,'compaction'));
  pi.on('session_before_tree',(event,ctx)=>remember(event?.signal,ctx,'auxiliary'));
  pi.on('session_shutdown',()=>{active=false;signals=new WeakMap();});
  pi.on('session_start',(_event,ctx)=>{
    signals=new WeakMap();active=ctx?.mode==='tui';
    if(!active) return;
    for(const provider of PROXIED_PROVIDERS) {
      if(installed.has(provider)) continue;
      // Public, synchronous provider lookup; never ask for auth or read a
      // credential. Snapshot the previous delegate before registering ours so
      // it cannot recursively call the newly composed provider.
      const previous=ctx.modelRegistry?.getProvider?.(provider);
      if(typeof previous?.streamSimple!=='function') continue;
      const delegate=previous.streamSimple.bind(previous);
      const endpoint=provider==='anthropic'?base:base+'/backend-api';
      pi.registerProvider(provider,{baseUrl:endpoint,api:APIS[provider],streamSimple:(model,context,options={})=>{
        // A user's model-level endpoint/API override must never receive our
        // capture metadata. Its existing behavior is delegated unchanged.
        if(model?.provider!==provider || model?.api!==APIS[provider] || model?.baseUrl!==endpoint) {
          if(!Object.keys(options.headers??{}).some(name=>OWNED_HEADERS.has(name.toLowerCase()))) return delegate(model,context,options);
          const headers=Object.fromEntries(Object.entries(options.headers??{}).filter(([name])=>!OWNED_HEADERS.has(name.toLowerCase())));
          return delegate(model,context,{...options,headers});
        }
        const candidate=active && options.signal && signals.get(options.signal);
        const operation=candidate && captureAllowed(candidate.session) ? candidate : undefined;
        let kind='auxiliary';
        if(operation && !options.signal.aborted && options.maxTokens!==1) {
          if(operation.kind==='compaction') kind='compaction';
          else if(operation.kind==='main' && options.sessionId===operation.session &&
                  typeof options.transformContext==='function' && typeof options.convertToLlm==='function') kind='main';
        }
        const headers={};
        for(const [name,value] of Object.entries(options.headers??{})) if(!OWNED_HEADERS.has(name.toLowerCase())) headers[name]=value;
        headers['x-3rdr-pi-contract']='2';
        headers['x-3rdr-pi-class']=kind;
        if(kind!=='auxiliary') headers['x-3rdr-pi-session']=operation.session;
        // Preserve all opaque auth, environment, retry, cache, transport,
        // thinking and instrumentation options. Only selected local headers
        // change; the forwarder strips them before any upstream request.
        return delegate(model,context,{...options,headers});
      }});
      installed.add(provider);
    }
  });
  return true;
}
