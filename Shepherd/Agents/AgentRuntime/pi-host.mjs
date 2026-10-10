import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {performance} from 'node:perf_hooks';
import {control, readBootstrap} from './pi-control.mjs';
import {PiIntegrationError} from './pi-runtime.mjs';

const failed = () => new PiIntegrationError('pi-host-bridge-unavailable');
export function createPiHost(bootstrapFile, { report = () => {}, onFailure = () => {} } = {}) {
  // File validation only; factory loading never starts sockets/processes/timers.
  const bootstrap = readBootstrap(bootstrapFile);
  function revoke(attemptID) {
    try {
      const result = spawnSync(bootstrap.node, [bootstrap.helper, bootstrapFile], {
        input:JSON.stringify({command:'revoke',attemptID}), encoding:'utf8', timeout:3000,
        maxBuffer:4096, stdio:['pipe','pipe','ignore'],
        env:{ HOME:process.env.HOME ?? '/', PATH:process.env.PATH ?? '/usr/bin:/bin', LANG:'en_US.UTF-8' }
      });
      return !result.error && !result.signal && result.status === 0 && JSON.parse(result.stdout).ok === true;
    } catch { return false; }
  }
  async function close(attemptID) {
    const result = await control(bootstrapFile,'close',attemptID,undefined,{timeoutMs:8000});
    if(result.ok !== true) throw failed();
  }
  return {
    report,
    async open(identity, signal) {
      const attemptID=crypto.randomUUID();
      let result;
      try {
        const deadline=performance.now()+8000;
        do {
          result=await control(bootstrapFile,'open',attemptID,identity,{signal});
          if(result.ok===true || result.error!=='notBound' || signal?.aborted)break;
          // Only this authoritative no-allocation response is retryable.
          await new Promise(resolve=>setTimeout(resolve,500));
        } while(performance.now()<deadline);
        if(result.ok !== true || signal?.aborted) throw failed();
      } catch {
        // An open may have committed even when its reply was lost. Cancel by
        // the caller-generated attempt ID, including a not-yet-processed open.
        const revoked=revoke(attemptID);
        let closed=false; try { await close(attemptID); closed=true; } catch {}
        if(revoked && closed) throw failed();
        // Returning an invalid/quarantined lease makes the lifecycle retain
        // uncertainty instead of assuming that a thrown open allocated nothing.
        return { identity, mcp:null, verifyMcp:async()=>false, isQuiescent:()=>false,
          revoke:()=>false, close:async()=>{throw failed();} };
      }
      let active=true, revocation, timer, polling, status, statusTime=0;
      const stop=()=>{active=false;clearInterval(timer);};
      function poll() {
        if(polling)return polling;
        if(!active)return Promise.resolve();
        polling=(async()=>{
          try {
            const current=await control(bootstrapFile,'status',attemptID);
            if(!active)return;
            if(current.ok!==true)throw failed();
            status=current;statusTime=performance.now();
          } catch { if(active){stop();try{onFailure();}catch{}} }
        })().finally(()=>{polling=undefined;});
        return polling;
      }
      // This is the owned control lease's heartbeat, not a keepalive workaround
      // for unrelated tools or headless extensions. Retirement always clears it.
      timer=setInterval(()=>{void poll();},1000);
      void poll();
      return {
        identity, mcp:result.mcp, refresh:poll,
        revoke() { stop(); if(revocation===undefined)revocation=revoke(attemptID); return revocation; },
        async close() { stop(); await close(attemptID); },
        async verifyMcp() {
          const deadline=performance.now()+8000;
          while(active && performance.now()<deadline) {
            await poll();
            if(status?.ready===true && performance.now()-statusTime<2000)return true;
            await new Promise(resolve=>setTimeout(resolve,500));
          }
          return false;
        },
        isQuiescent() { return active && status?.ready===true && status?.quiescent===true && performance.now()-statusTime<2000; }
      };
    }
  };
}
