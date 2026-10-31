import test from 'node:test';
import assert from 'node:assert/strict';
import {createPiMcpRegistration} from '../../../Shepherd/Agents/AgentRuntime/pi-mcp-registration.mjs';
const config={command:'/node',args:['/wrapper','/descriptor'],exposure:'codemode'};
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
function fixture(emit=()=>{}) {
 const calls=[], handlers=new Map();
 const registration=createPiMcpRegistration({events:{emit},on:(name,fn)=>handlers.set(name,[...(handlers.get(name)??[]),fn]),
  registerMcpServer:(...args)=>calls.push(['register',...args]),unregisterMcpServer:name=>calls.push(['unregister',name])});
 return {calls,registration,fire:name=>{for(const fn of handlers.get(name)??[])fn({},{});}};
}
test('absent adapter uses only the native Pi API',async()=>{
 const f=fixture();f.registration.registerMcpServer('3rdr-browser',config);await f.registration.ensureConnected();await f.registration.unregisterMcpServer('3rdr-browser');
 assert.deepEqual(f.calls.map(c=>c[0]),['register','unregister']);
});
test('adapter conflict never falls back to built-in MCP',()=>{
 const f=fixture((event,r)=>{if(event.includes('runtime-register'))r.result={ok:false,error:Error('private error')};});
 assert.throws(()=>f.registration.registerMcpServer('3rdr-browser',config),/pi-mcp-registration-unavailable/);assert.equal(f.calls.length,0);
});
test('adapter session lifetime, metadata connection and acknowledged disposal',async()=>{
 const order=[],closed=deferred();let definition;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register')){definition=r.definition;r.result={ok:true,registration:{dispose:()=>{order.push('dispose');return closed.promise;}}};}
  else if(event.includes('protocol:'))r.result={connect:async name=>{assert.equal(name,'3rdr-browser');order.push('connect');return {close:()=>order.push('close')};},dispose:()=>order.push('protocol-dispose')};
 });
 f.registration.registerMcpServer('3rdr-browser',config);await f.registration.ensureConnected();
 assert.equal(definition.lifecycle,'eager');assert.equal(definition.idleTimeout,0);assert.equal(definition.inheritEnv,false);
 assert.deepEqual(Object.keys(definition.env).sort(),['HOME','PATH']);assert.deepEqual(order.slice(0,3),['connect','close','protocol-dispose']);
 let done=false;const pending=f.registration.unregisterMcpServer('3rdr-browser').then(()=>{done=true;});
 await Promise.resolve();assert.equal(done,false);closed.resolve();await pending;assert.equal(done,true);assert.equal(f.calls.length,0);
});
test('late adapter connection cannot resurrect a retired registration',async()=>{
 const open=deferred();let closed=0;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};
  else if(event.includes('protocol:'))r.result={connect:()=>open.promise,dispose:()=>{}};
 });
 f.registration.registerMcpServer('3rdr-browser',config);const binding=f.registration.ensureConnected();
 await f.registration.unregisterMcpServer('3rdr-browser');open.resolve({close:()=>{closed++;}});
 await assert.rejects(binding,/pi-mcp-registration-unavailable/);assert.equal(closed,1);
});
test('missing adapter mediated protocol fails rather than claiming readiness',async()=>{
 const f=fixture((event,r)=>{if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};});
 f.registration.registerMcpServer('3rdr-browser',config);await assert.rejects(f.registration.ensureConnected());await f.registration.unregisterMcpServer('3rdr-browser');
});
test('adapter connect waits until every session_start handler has returned (SHPHRD-146)',async()=>{
 // Pi runs session_start handlers in load order: ours first, the adapter's later.
 // Its connect refuses until its own handler ran; resources_discover follows them all.
 let adapterSession=false, connects=0;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};
  else if(event.includes('protocol:'))r.result={connect:async()=>{connects++;if(!adapterSession)throw Error('MCP connections require an active Pi session');return {close:()=>{}};},dispose:()=>{}};
 });
 f.fire('session_start');
 f.registration.registerMcpServer('3rdr-browser',config);
 let settled=false;const binding=f.registration.ensureConnected().finally(()=>{settled=true;});
 await new Promise(resolve=>setImmediate(resolve));assert.equal(settled,false);assert.equal(connects,0);
 adapterSession=true;f.fire('resources_discover');await binding;assert.equal(connects,1);
 // A later start in the same session (tree navigation) does not wait again.
 await f.registration.ensureConnected();assert.equal(connects,2);
 await f.registration.unregisterMcpServer('3rdr-browser');
});
test('a registration retired while waiting for session_start never connects',async()=>{
 let connects=0;
 const f=fixture((event,r)=>{
  if(event.includes('runtime-register'))r.result={ok:true,registration:{dispose:async()=>{}}};
  else if(event.includes('protocol:'))r.result={connect:async()=>{connects++;return {close:()=>{}};},dispose:()=>{}};
 });
 f.fire('session_start');f.registration.registerMcpServer('3rdr-browser',config);
 const binding=f.registration.ensureConnected();
 await f.registration.unregisterMcpServer('3rdr-browser');f.fire('session_shutdown');
 await assert.rejects(binding,/pi-mcp-registration-unavailable/);assert.equal(connects,0);
});
