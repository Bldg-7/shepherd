import path from 'node:path';
import {protectedRead} from './protected-read.mjs';

// The agent proxy for a Pi the New Tab launcher started (SHPHRD-105). The app
// puts the proxy's base URL in the launch's launch.json (0600, next to the
// bridge's bootstrap file) when this Pi goes through it; Pi's anthropic and
// openai-codex providers are then pointed there, with their own sign-in,
// models and settings left as they are. Each request to either one says
// which Pi session it belongs to; the proxy removes these headers before the
// request leaves this Mac. Nothing is registered without a valid base URL.
const BASE=/^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/p\/[0-9a-f]{32}$/;
export const PROXIED_PROVIDERS=['anthropic','openai-codex'];

export function apiProxyBase(bootstrap, read = protectedRead) {
  try {
    if(typeof bootstrap !== 'string' || !path.isAbsolute(bootstrap)) return null;
    const manifest=JSON.parse(read(path.join(path.dirname(bootstrap),'launch.json')));
    const base=manifest?.apiProxy?.baseURL;
    const match=typeof base === 'string' && BASE.exec(base);
    return match && +match[1] <= 65535 ? base : null;
  } catch { return null; }
}

export function registerPiApiProxy(pi, bootstrap, {read = protectedRead} = {}) {
  const base=apiProxyBase(bootstrap,read);
  if(!base) return false;
  pi.registerProvider('anthropic',{baseUrl:base});
  pi.registerProvider('openai-codex',{baseUrl:base+'/backend-api'});
  pi.on('before_provider_headers',(event,ctx)=>{
    // Only to the providers sent to the proxy: another provider's server
    // never sees them.
    if(!PROXIED_PROVIDERS.includes(ctx?.model?.provider) || !event?.headers) return;
    const session=ctx.sessionManager?.getSessionId?.();
    if(typeof session === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(session)) event.headers['x-3rdr-pi-session']=session;
    event.headers['x-3rdr-pi-class']='main';
  });
  return true;
}
