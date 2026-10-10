import test from 'node:test';
import assert from 'node:assert/strict';
import {createPiMcpRegistration} from '../../../Shepherd/Agents/AgentRuntime/pi-mcp-registration.mjs';
const config={command:'/node',args:['/wrapper','/descriptor'],exposure:'codemode'};
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function fixture(emit=()=>{}) {
 const calls=[];
 const registration=createPiMcpRegistration({events:{emit},registerMcpServer:(...args)=>calls.push(['register',...args]),unregisterMcpServer:name=>calls.push(['unregister',name])});
 return {calls,registration};
}
test('absent adapter uses only the native Pi API',async()=>{
 const f=fixture();f.registration.registerMcpServer('shepherd-browser',config);await f.registration.ensureConnected();await f.registration.unregisterMcpServer('shepherd-browser');
 assert.deepEqual(f.calls.map(c=>c[0]),['register','unregister']);
});
test('adapter conflict never falls back to built-in MCP',()=>{
 const f=fixture((event,r)=>{if(event.includes('runtime-register'))r.result={ok:false,error:Error('private error')};});
 assert.throws(()=>f.registration.registerMcpServer('shepherd-browser',config),/pi-mcp-registration-unavailable/);assert.equal(f.calls.length,0);
});
test('adapter session lifetime, metadata connection and acknowledged disposal',async()=>{
 const order=[],closed=deferred();let definition;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register')){definition=r.definition;r.result={ok:true,registration:{dispose:()=>{order.push('dispose');return closed.promise;}}};}
  else if(event.includes('protocol:'))r.result={connect:async name=>{assert.equal(name,'shepherd-browser');order.push('connect');return {close:()=>order.push('close')};},dispose:()=>order.push('protocol-dispose')};
 });
 f.registration.registerMcpServer('shepherd-browser',config);await f.registration.ensureConnected();
 assert.equal(definition.lifecycle,'eager');assert.equal(definition.idleTimeout,0);assert.equal(definition.inheritEnv,false);
 assert.deepEqual(Object.keys(definition.env).sort(),['HOME','PATH']);assert.deepEqual(order.slice(0,3),['connect','close','protocol-dispose']);
 let done=false;const pending=f.registration.unregisterMcpServer('shepherd-browser').then(()=>{done=true;});
 await Promise.resolve();assert.equal(done,false);closed.resolve();await pending;assert.equal(done,true);assert.equal(f.calls.length,0);
});
test('late adapter connection cannot resurrect a retired registration',async()=>{
 const open=deferred();let closed=0;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};
  else if(event.includes('protocol:'))r.result={connect:()=>open.promise,dispose:()=>{}};
 });
 f.registration.registerMcpServer('shepherd-browser',config);const binding=f.registration.ensureConnected();
 await f.registration.unregisterMcpServer('shepherd-browser');open.resolve({close:()=>{closed++;}});
 await assert.rejects(binding,/pi-mcp-registration-unavailable/);assert.equal(closed,1);
});
test('missing adapter mediated protocol fails rather than claiming readiness',async()=>{
 const f=fixture((event,r)=>{if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};});
 f.registration.registerMcpServer('shepherd-browser',config);await assert.rejects(f.registration.ensureConnected());await f.registration.unregisterMcpServer('shepherd-browser');
});
