import {randomUUID} from 'node:crypto';
import {control,readBootstrap} from './pi-control.mjs';

// Uses Herdr's v9 integration report protocol THROUGH the authenticated app
// bridge. Never trust inherited HERDR_SOCKET_PATH/PANE_ID to choose a target.
// No global integration install, shell command, prompt or raw error reporting.
export function registerPiHerdr(pi,bootstrap,onFailure) {
  if(readBootstrap(bootstrap).herdrReporting!==true)return;
  let queue=Promise.resolve(), active=false, generation=0, blocked=0, latestContext;
  function report(ctx,state) {
    if(ctx.mode!=='tui')return;
    latestContext=ctx;
    const epoch=generation;
    if(blocked>0)state='blocked';
    const identity={pid:process.pid,cwd:ctx.cwd,sessionID:ctx.sessionManager.getSessionId(),sessionFile:ctx.sessionManager.getSessionFile(),leafID:ctx.sessionManager.getLeafId()};
    queue=queue.then(async()=>{
      if(!active || epoch!==generation)return;
      const reply=await control(bootstrap,'herdrState',randomUUID(),identity,{state});
      if(reply.ok!==true)throw new Error('pi-herdr-state-unavailable');
    }).catch(()=>{active=false;onFailure();});
    return queue;
  }
  pi.on('session_start',(_event,ctx)=>{generation++;blocked=0;active=true;return report(ctx,ctx.isIdle()===true && ctx.hasPendingMessages()===false?'idle':'working');});
  pi.on('agent_start',(_event,ctx)=>report(ctx,'working'));
  pi.on('agent_settled',(_event,ctx)=>report(ctx,ctx.isIdle()===true && ctx.hasPendingMessages()===false?'idle':'working'));
  pi.events.on('herdr:blocked',value=>{
    if(!active || !latestContext)return;
    blocked=value?.active ? Math.min(1024,blocked+1) : Math.max(0,blocked-1);
    void report(latestContext,latestContext.isIdle()===true && latestContext.hasPendingMessages()===false?'idle':'working');
  });
  pi.on('session_shutdown',async()=>{generation++;active=false;await queue;});
}
