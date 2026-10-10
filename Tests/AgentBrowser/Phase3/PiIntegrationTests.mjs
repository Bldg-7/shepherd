import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {detectPi, piNodeSupported, piInvocation, PI_MANAGED_LAUNCH_QUALIFIED} from '../../../Shepherd/Agents/AgentRuntime/pi-runtime.mjs';
import {registerPiLifecycle} from '../../../Shepherd/Agents/AgentRuntime/pi-lifecycle.mjs';
import {detect, injected, resume, childCommand} from '../../../Shepherd/Agents/AgentRuntime/runtime-core.mjs';
import {prepare} from '../../../Shepherd/Agents/AgentRuntime/runtime.mjs';

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'shepherd-pi-fixture-'));
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }));
const invocation = { extension: '/owned/extension.ts', skill: '/owned/SKILL.md', guidance: '/owned/guidance.md', sessionID: 'a1111111-1111-1111-1111-111111111111' };
const ctx = () => {
  const value = { cwd: '/owned/project', id: 'fixture-session', file: '/owned/session.jsonl', leaf: 'leaf-a', idle: true, pending: false };
  return { value, get cwd() { return value.cwd; }, sessionManager: {
    getSessionId: () => value.id, getSessionFile: () => value.file, getLeafId: () => value.leaf },
    isIdle: () => value.idle, hasPendingMessages: () => value.pending };
};
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {promise,resolve,reject}; };
const turn = () => new Promise(resolve => setImmediate(resolve));
function fixture({ open, verify = async () => true, revoke = () => true, close = async () => {}, duplicate = false, report, nonblockingStartup = false } = {}) {
  const handlers = new Map(), events = [], leases = [];
  const pi = {
    on(name, handler) { assert(!handlers.has(name)); handlers.set(name, handler); },
    registerMcpServer(name, config) { if (duplicate) throw new Error('unrelated configured server'); events.push(['register', name, config]); },
    unregisterMcpServer(name) { events.push(['unregister', name]); },
  };
  function lease(identity) {
    const value = { identity, mcp: { command: '/owned/node', args: ['/owned/mcp-run.mjs', '/owned/session.json'] },
      revoke() { events.push(['revoke']); return revoke(); }, close() { events.push(['close']); return close(); },
      verifyMcp() { events.push(['verify']); return verify(); }, isQuiescent: () => true };
    leases.push(value); return value;
  }
  const host = { open: open ? (identity, signal) => open(identity, signal, lease) : async identity => lease(identity),
    report: report ?? (state => events.push(['status', state])) };
  const controller = registerPiLifecycle(pi, host, { timeoutMs: 40, nonblockingStartup });
  const emit = (name, context = ctx()) => handlers.get(name)?.({ type: name, reason: 'startup' }, context);
  return { pi, host, controller, emit, events, leases, handlers };
}

test('Pi Node floor is separate from the existing Node 20 browser floor', () => {
  for (const version of ['20.19.0','22.18.9','22','v22.19.0','22.19.0-beta','garbage']) assert(!piNodeSupported(version));
  for (const version of ['22.19.0','22.20.1','23.0.0','26.1.0']) assert(piNodeSupported(version));
  assert.equal(detectPi('/missing', {nodeVersion:'20.0.0'}).readiness, 'missing');
});
test('Probe reads package metadata but never executes pi or loads its settings/extensions', () => {
  const root = path.join(directory, 'package'), dist = path.join(root, 'dist'); fs.mkdirSync(dist, { recursive: true });
  const cli = path.join(dist, 'cli.js'), marker = path.join(directory, 'MUST-NOT-EXECUTE');
  fs.writeFileSync(cli, '#!/bin/sh\ntouch '+marker+'\n', { mode: 0o700 });
  const manifest = path.join(root, 'package.json');
  const write = changes => fs.writeFileSync(manifest, JSON.stringify({ name:'@earendil-works/pi-coding-agent', version:'1.1.0', bin:{pi:'dist/cli.js'}, ...changes }), { mode:0o600 });
  write({});
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin); fs.symlinkSync(cli, path.join(bin,'pi'));
  const options = { environment: { PATH: bin }, nodeVersion: '22.19.0' };
  assert.equal(detectPi('pi', {...options,nodeVersion:'20.0.0'}).readiness,'unsupportedPrerequisite');
  const result = detectPi('pi', options);
  assert.equal(result.kind, 'pi'); assert.equal(result.version, '1.1.0'); assert.equal(result.readiness, 'availableAuthenticationUnknown');
  assert.equal(result.sessionPlugin, true); assert.equal(result.sessionConfiguration, false); assert.equal(result.hookRewrite, false);
  assert(!fs.existsSync(marker));
  write({ version:'2.0.0' }); assert.equal(detectPi('pi',options).readiness,'unsupported');
  write({ name:'not-pi' }); assert.equal(detectPi('pi',options).readiness,'unsupported');
  write({ bin:{pi:'other.js'} }); assert.equal(detectPi('pi',options).readiness,'unsupported');
  fs.writeFileSync(manifest,'{bad'); assert.equal(detectPi('pi',options).readiness,'unsupported');
  assert.equal(detectPi('pi',{...options,environment:{PATH:'.'}}).readiness,'missing');
  assert(!fs.existsSync(marker));
});
test('Qualified Pi still cannot use legacy injection, resume, child rewrite or prepare', () => {
  assert.equal(PI_MANAGED_LAUNCH_QUALIFIED, true);
  assert.equal(injected('pi',['-c','mcp_servers.shepherd-browser.args=[]'],{mcpArguments:[]}), false);
  assert.throws(() => resume('pi', [], 'session-id'), {code:'pi-resume-unqualified'});
  assert.equal(childCommand('herdr agent start child --kind pi --pane w1:p1'), null);
  assert.throws(() => prepare({root:path.join(directory,'runtime'),kind:'pi'}), {code:'pi-launch-unqualified'});
  assert.throws(() => detect('unknown','anything'), {code:'invalid-agent'});
});
test('Pure invocation appends local resources and preserves accepted user instructions', () => {
  const args = ['--model','openai/example','--system-prompt','User instructions','--append-system-prompt=More user instructions','--tui-mode','regular'];
  assert.deepEqual(piInvocation({...invocation,arguments:args}),[...args,'--extension',invocation.extension,'--skill',invocation.skill,'--append-system-prompt',invocation.guidance,'--session-id',invocation.sessionID]);
  assert.throws(() => piInvocation({...invocation,disableCompetingBrowsers:true}),{code:'pi-tool-policy-unqualified'});
});
test('Session, global configuration, trust, headless and unknown flags are not smuggled into the first-launch plan', () => {
  for (const argument of ['--continue','-c','--resume','-r','--session','--session-id','--fork','--no-session','--no-mcp','--no-extensions','--no-skills','--approve','--no-approve','--api-key','--print','-p','--mode','--extension','--tools','--exclude-tools','--','prompt text','--session=somewhere']) {
    assert.throws(() => piInvocation({...invocation,arguments:[argument,'value']}), {code:'pi-argument-unqualified'});
  }
  assert.throws(() => piInvocation({...invocation,arguments:['--model']}), {code:'pi-option-value-missing'});
  assert.throws(() => piInvocation({...invocation,extension:'relative'}), {code:'pi-resource-path-invalid'});
  assert.throws(() => piInvocation({...invocation,sessionID:'../path'}), {code:'pi-session-invalid'});
});
test('No bridge means no usable extension/MCP registration', () => {
  assert.throws(() => registerPiLifecycle({},null),{code:'pi-host-bridge-unavailable'});
});
test('Lifecycle uses native ephemeral registration and settled, not agent_end', async () => {
  const f=fixture(), c=ctx(); await f.emit('session_start',c);
  assert.equal(f.controller.state(),'ready');
  assert.equal(f.events.filter(e=>e[0]==='register').length,1);
  assert.deepEqual(f.events.find(e=>e[0]==='register')[2],{ command:'/owned/node',args:['/owned/mcp-run.mjs','/owned/session.json'],exposure:'codemode' });
  await f.emit('agent_start',c); assert.equal(f.controller.state(),'busy');
  assert(!f.handlers.has('agent_end'));
  c.value.leaf='ordinary-new-message'; c.value.pending=true;
  await f.emit('agent_settled',c); assert.equal(f.controller.state(),'busy');
  c.value.pending=false; await f.emit('agent_settled',c); assert.equal(f.controller.state(),'idle');
  await f.emit('session_shutdown',c); assert.equal(f.controller.state(),'off');
  assert(f.events.findIndex(e=>e[0]==='revoke')<f.events.findIndex(e=>e[0]==='unregister'));
  await f.controller.shutdown(); assert.equal(f.events.filter(e=>e[0]==='revoke').length,1);
});
test('CLI startup does not block later MCP initialization handlers', async () => {
  const entered=deferred(), release=deferred();
  const f=fixture({nonblockingStartup:true,open:async(identity,_signal,make)=>{entered.resolve();await release.promise;return make(identity);}});
  assert.equal(f.emit('session_start'),undefined);
  await entered.promise;release.resolve();await f.controller.whenStarted();
  assert.equal(f.controller.state(),'ready');await f.controller.shutdown();
});
test('Late quiescence refresh cannot publish idle after shutdown', async () => {
  const f=fixture(), c=ctx();await f.emit('session_start',c);
  const entered=deferred(), release=deferred();
  f.leases[0].refresh=async()=>{entered.resolve();await release.promise;};
  const settled=f.emit('agent_settled',c);await entered.promise;await f.controller.shutdown();release.resolve();await settled;
  assert.equal(f.controller.state(),'off');
});
test('Asynchronous MCP unregister acknowledgement is required before retirement', async () => {
  const f=fixture();await f.emit('session_start');const acknowledgement=deferred();
  f.pi.unregisterMcpServer=()=>acknowledgement.promise;
  let completed=false;const close=f.controller.shutdown().then(()=>{completed=true;});
  await turn();assert.equal(completed,false);assert(f.events.some(e=>e[0]==='revoke'));
  acknowledgement.resolve();await close;assert.equal(f.controller.state(),'off');
});
test('Rejected MCP unregister acknowledgement quarantines future bindings', async () => {
  const f=fixture();await f.emit('session_start');
  f.pi.unregisterMcpServer=async()=>{throw new Error('private adapter diagnostic');};
  await f.controller.shutdown();assert.equal(f.controller.state(),'retirementUnconfirmed');
  await f.emit('session_start');assert.equal(f.leases.length,1);
  assert(!JSON.stringify(f.events).includes('private adapter diagnostic'));
});
test('Fresh branch binding follows synchronous revocation and acknowledged cleanup', async () => {
  const f=fixture(), c=ctx(); await f.emit('session_start',c);
  assert.equal(await f.emit('session_before_tree',c),undefined);
  c.value.leaf='other-branch'; await f.emit('session_tree',c);
  assert.equal(f.controller.state(),'ready'); assert.equal(f.leases.length,2);
  assert.equal(f.events.filter(e=>e[0]==='revoke').length,1);
  await f.controller.shutdown();
});
test('Unexpected session change loses access, including inherited parent context', async () => {
  for (const key of ['id','file','cwd']) {
    const f=fixture(), c=ctx(); await f.emit('session_start',c);
    c.value[key] += '-different'; await f.emit('agent_start',c);
    assert.equal(f.controller.state(),'off'); assert(f.events.some(e=>e[0]==='revoke'));
  }
});
test('No usable persisted session fails without allocating a lease', async () => {
  const f=fixture(), c=ctx(); c.value.file=undefined;
  await f.emit('session_start',c); assert.equal(f.controller.state(),'failed'); assert.equal(f.leases.length,0);
});
test('Configured-server conflict does not unregister someone else’s server', async () => {
  const f=fixture({duplicate:true}); await f.emit('session_start');
  assert.equal(f.controller.state(),'failed'); assert(f.events.some(e=>e[0]==='revoke'));
  assert(!f.events.some(e=>e[0]==='unregister'));
});
test('API registration alone is not effective MCP ownership proof', async () => {
  const f=fixture({verify:async()=>false}); await f.emit('session_start');
  assert.equal(f.controller.state(),'failed'); assert.equal(f.events.filter(e=>e[0]==='unregister').length,1);
});
test('Truthiness is not proof of MCP ownership or quiescence', async () => {
  const unproven=fixture({verify:async()=>({ok:true})}); await unproven.emit('session_start');
  assert.equal(unproven.controller.state(),'failed');
  const f=fixture(), c=ctx(); await f.emit('session_start',c);
  f.leases[0].isQuiescent=()=>Promise.resolve(true);
  await f.emit('agent_settled',c); assert.equal(f.controller.state(),'busy');
  await f.controller.shutdown();
});
test('Bad identity or credential-bearing MCP configuration never registers', async () => {
  for (const bad of ['identity','config']) {
    const f=fixture({open:async(identity,_signal,make)=>{
      const l=make(identity);
      if(bad==='identity') l.identity={...identity,pid:identity.pid+1}; else l.mcp.env={TOKEN:'synthetic-secret'};
      return l;
    }});
    await f.emit('session_start'); assert.equal(f.controller.state(),'failed');
    assert(!f.events.some(e=>e[0]==='register')); assert(f.events.some(e=>e[0]==='revoke'));
  }
});
test('Late acquisition after shutdown is compensated and cannot publish Ready', async () => {
  const entered=deferred(), release=deferred();
  const f=fixture({open:async(identity,_signal,make)=>{ entered.resolve(); await release.promise; return make(identity); }});
  const starting=f.emit('session_start'); await entered.promise;
  assert.equal(await f.controller.shutdown(),false); release.resolve(); await starting; await turn();
  assert(!f.events.some(e=>e[0]==='register')); assert.equal(f.events.filter(e=>e[0]==='revoke').length,1);
  assert.equal(await f.controller.shutdown(),true);
});
test('Open timeout quarantines until late authority is actually retired', async () => {
  const release=deferred(); const f=fixture({open:async(identity,_signal,make)=>{await release.promise;return make(identity);}});
  await f.emit('session_start'); assert.equal(f.controller.state(),'retirementUnconfirmed');
  await f.emit('session_start'); assert.equal(f.leases.length,0);
  release.resolve(); await turn(); await turn();
  assert.equal(f.events.filter(e=>e[0]==='revoke').length,1); assert(!f.events.some(e=>e[0]==='register'));
  assert.equal(await f.controller.shutdown(),true);
});
test('Unconfirmed revocation/cleanup blocks switching and future binding', async () => {
  for (const options of [{revoke:()=>false},{close:async()=>{throw new Error('secret error');}}]) {
    const f=fixture(options); await f.emit('session_start');
    assert.deepEqual(await f.emit('session_before_switch'),{cancel:true});
    assert.equal(f.controller.state(),'retirementUnconfirmed');
    await f.emit('session_start'); assert.equal(f.leases.length,1);
    assert(!JSON.stringify(f.events).includes('secret error'));
  }
});
test('Overlapping starts cannot allocate two active registrations', async () => {
  const f=fixture(), c=ctx(); await Promise.all([f.emit('session_start',c),f.emit('session_start',c)]);
  assert.equal(f.events.filter(e=>e[0]==='register').length,1);
  await f.controller.shutdown();
});
test('Shutdown during ownership proof cannot let late proof reactivate MCP', async () => {
  const entered=deferred(), proof=deferred();
  const f=fixture({verify:async()=>{entered.resolve();return proof.promise;}});
  const starting=f.emit('session_start'); await entered.promise;
  await f.controller.shutdown(); proof.resolve(true); await starting;
  assert.equal(f.controller.state(),'off'); assert.equal(f.events.filter(e=>e[0]==='unregister').length,1);
});
test('Status-channel failure leaves no registered live authority', async () => {
  const f=fixture({report:state=>{if(state==='ready')throw new Error('secret report');}});
  await f.emit('session_start'); await turn();
  assert.equal(f.controller.state(),'failed'); assert(f.events.some(e=>e[0]==='revoke'));
  assert(f.events.some(e=>e[0]==='unregister')); await f.controller.shutdown();
});
