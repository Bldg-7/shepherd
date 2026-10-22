import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {detectPi, resolvePiExecutable, piNodeSupported, piInvocation, PI_MANAGED_LAUNCH_QUALIFIED} from '../../../Shepherd/Agents/AgentRuntime/pi-runtime.mjs';
import {registerPiLifecycle, SERVER as PI_SERVER} from '../../../Shepherd/Agents/AgentRuntime/pi-lifecycle.mjs';
import {detect, injected, resume, childCommand, SERVER} from '../../../Shepherd/Agents/AgentRuntime/runtime-core.mjs';
import {prepare, stagePi} from '../../../Shepherd/Agents/AgentRuntime/runtime.mjs';
import {registerPiSessionNaming} from '../../../Shepherd/Agents/AgentRuntime/pi-session-name.mjs';
import {createPiHost} from '../../../Shepherd/Agents/AgentRuntime/pi-host.mjs';
import {registerPiApiProxy, apiProxyBase, PROXIED_PROVIDERS} from '../../../Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs';
import net from 'node:net';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

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
const qualifiedVersions = ['1.0.0','1.1.0','1.2.0','1.10.3'];
const unqualifiedVersions = ['0.9.9','2.0.0','1.3.0-beta.1','1.2','v1.2.0'];
function versionedPackage(name) {
  const dist = path.join(directory, name, 'dist'); fs.mkdirSync(dist, { recursive: true });
  const cli = path.join(dist, 'cli.js'); fs.writeFileSync(cli, '#!/bin/sh\nexit 1\n', { mode: 0o700 });
  const write = version => fs.writeFileSync(path.join(directory, name, 'package.json'), JSON.stringify({ name:'@earendil-works/pi-coding-agent', version, bin:{pi:'dist/cli.js'} }), { mode:0o600 });
  return { cli, write };
}
test('Probe qualifies any Pi 1.x release and nothing outside ^1.0.0', () => {
  const { cli, write } = versionedPackage('probe-range'), options = { environment: {}, nodeVersion: '22.19.0' };
  for (const version of qualifiedVersions) {
    write(version); const result = detectPi(cli, options);
    assert.equal(result.version, version); assert.equal(result.readiness, 'availableAuthenticationUnknown'); assert.equal(result.sessionPlugin, true);
  }
  for (const version of unqualifiedVersions) {
    write(version); const result = detectPi(cli, options);
    assert.equal(result.version, version); assert.equal(result.readiness, 'unsupported'); assert.equal(result.sessionPlugin, false);
  }
});
test('Launch resolves any Pi 1.x release and rejects the rest as an unsupported package', { skip: !piNodeSupported() && 'Pi launch requires Node >=22.19.0' }, () => {
  const { cli, write } = versionedPackage('launch-range');
  for (const version of qualifiedVersions) { write(version); assert.equal(resolvePiExecutable(cli, {}), fs.realpathSync(cli)); }
  for (const version of unqualifiedVersions) { write(version); assert.throws(() => resolvePiExecutable(cli, {}), {code:'pi-package-unsupported'}); }
});
test('Qualified Pi still cannot use legacy injection, resume, child rewrite or prepare', () => {
  assert.equal(PI_MANAGED_LAUNCH_QUALIFIED, true);
  for (const name of ['3rdr-browser','shepherd-browser']) assert.equal(injected('pi',['-c',`mcp_servers.${name}.args=[]`],{mcpArguments:[]}), false);
  assert.throws(() => resume('pi', [], 'session-id'), {code:'pi-resume-unqualified'});
  assert.equal(childCommand('herdr agent start child --kind pi --pane w1:p1'), null);
  assert.throws(() => prepare({root:path.join(directory,'runtime'),kind:'pi'}), {code:'pi-launch-unqualified'});
  assert.throws(() => detect('unknown','anything'), {code:'invalid-agent'});
});
test('Pure invocation appends local resources and preserves accepted user instructions', () => {
  const args = ['--model','openai/example','--system-prompt','User instructions','--append-system-prompt=More user instructions','--tui-mode','regular'];
  assert.deepEqual(piInvocation({...invocation,arguments:args}),[...args,'--extension',invocation.extension,'--skill',invocation.skill,'--append-system-prompt',invocation.guidance,'--session-id',invocation.sessionID]);
  const blocking = {disableCompetingBrowsers:true,competingBrowserServers:['playwright','chrome-devtools']};
  assert.deepEqual(piInvocation({...invocation,...blocking,arguments:args}),piInvocation({...invocation,arguments:args}));
});
test('Blocking other browser tools neither refuses nor changes the staged Pi launch', { skip: !piNodeSupported() && 'Pi launch requires Node >=22.19.0' }, () => {
  const { cli, write } = versionedPackage('stage-blocking'); write('1.2.0');
  const root = path.join(directory, 'stage-runtime'); fs.mkdirSync(root, { mode: 0o700 });
  fs.writeFileSync(path.join(root, 'installation.json'), JSON.stringify({ mode:'plugin', resourceDirectory:'/owned/resources' }), { mode:0o600 });
  const plan = preferences => {
    const stage = stagePi({ root, executable: cli, arguments: ['--model','openai/example'], preferences });
    return stage.arguments.map(arg => arg.replaceAll(stage.sessionID, '<session>').replaceAll(stage.folder, '<folder>'));
  };
  const unblocked = plan({ disableCompetingBrowsers:false, competingBrowserServers:[] });
  assert.equal(stagePi({ root, executable: cli }).cliVersion, '1.2.0', 'the staged Pi\'s version, read from its package, for the agent proxy\'s floor');
  assert.deepEqual(plan({ disableCompetingBrowsers:true, competingBrowserServers:['playwright','chrome-devtools'] }), unblocked);
  assert(!unblocked.some(arg => /playwright|chrome-devtools|^--no-mcp|^--(exclude-)?tools/.test(arg)));
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
  assert.equal(PI_SERVER,SERVER);assert.equal(f.events.find(e=>e[0]==='register')[1],'3rdr-browser');
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

// The pane's name from the app's Rename Pane, for Pi's session (SHPHRD-95).
function namingFixture() {
  const handlers = new Map(), names = [];
  const pi = { on(name, handler) { assert(!handlers.has(name)); handlers.set(name, handler); }, setSessionName(name) { names.push(name); } };
  const naming = registerPiSessionNaming(pi);
  const value = { idle: true, pending: false, mode: 'tui' };
  const context = { get mode() { return value.mode; }, isIdle: () => value.idle, hasPendingMessages: () => value.pending };
  const emit = name => handlers.get(name)?.({ type: name }, context);
  return { pi, naming, names, value, emit };
}
test('Session name: each number set once, while Pi is idle', () => {
  const f = namingFixture(); f.emit('session_start');
  f.naming.offer({ sequence: 1, name: 'Release notes' }); f.naming.offer({ sequence: 1, name: 'Release notes' });
  assert.deepEqual(f.names, ['Release notes']);
  f.naming.offer({ sequence: 2, name: 'Renamed' }); f.naming.offer({ sequence: 1, name: 'Release notes' });
  assert.deepEqual(f.names, ['Release notes', 'Renamed']);
});
test('Session name: a working Pi gets it after agent_settled, the latest only', () => {
  const f = namingFixture(); f.emit('session_start'); f.emit('agent_start');
  f.naming.offer({ sequence: 1, name: 'First' }); f.naming.offer({ sequence: 2, name: 'Second' });
  assert.deepEqual(f.names, []);
  f.value.pending = true; f.emit('agent_settled'); assert.deepEqual(f.names, []);
  f.value.pending = false; f.value.idle = false; f.emit('agent_settled'); assert.deepEqual(f.names, []);
  f.value.idle = true; f.emit('agent_settled'); assert.deepEqual(f.names, ['Second']);
  f.emit('agent_settled'); f.naming.offer({ sequence: 2, name: 'Second' }); assert.deepEqual(f.names, ['Second']);
});
test('Session name: before session_start, outside the TUI and for a new session, nothing', () => {
  const f = namingFixture();
  f.naming.offer({ sequence: 1, name: 'Early' }); assert.deepEqual(f.names, []);
  f.value.mode = 'rpc'; f.emit('session_start'); f.emit('agent_settled'); assert.deepEqual(f.names, []);
  f.value.mode = 'tui'; f.emit('session_start'); assert.deepEqual(f.names, [], 'a name offered before is for the session before');
  f.emit('agent_start'); f.naming.offer({ sequence: 2, name: 'Old session' });
  f.emit('session_start'); f.emit('agent_settled'); assert.deepEqual(f.names, []);
  f.naming.offer({ sequence: 3, name: 'New session' }); assert.deepEqual(f.names, ['New session']);
  f.emit('session_shutdown'); f.naming.offer({ sequence: 4, name: 'After shutdown' }); assert.deepEqual(f.names, ['New session']);
});
test('Session name: only a numbered one-line name of at most 200 characters', () => {
  const f = namingFixture(); f.emit('session_start');
  for (const value of [undefined, null, {}, { sequence: 0, name: 'zero' }, { sequence: 1.5, name: 'fraction' }, { sequence: '1', name: 'text' },
    { sequence: 1, name: '' }, { sequence: 1, name: ' padded' }, { sequence: 1, name: 'two\nlines' }, { sequence: 1, name: 'line\u2028separator' },
    { sequence: 1, name: 'escape\u001b[31m' }, { sequence: 1, name: 'x'.repeat(201) }, { sequence: 1, name: 7 }]) f.naming.offer(value);
  assert.deepEqual(f.names, []);
  f.naming.offer({ sequence: 1, name: '🇰🇷'.repeat(200) }); f.naming.offer({ sequence: 2, name: '가'.repeat(200) });
  assert.deepEqual(f.names, ['🇰🇷'.repeat(200), '가'.repeat(200)]);
});
test('Session name: a failing setSessionName is not tried again', () => {
  const f = namingFixture(); let calls = 0;
  f.pi.setSessionName = () => { calls++; throw new Error('stale extension context'); };
  f.emit('session_start'); f.naming.offer({ sequence: 1, name: 'Once' }); f.naming.offer({ sequence: 1, name: 'Once' }); f.emit('agent_settled');
  assert.equal(calls, 1);
});
test('Session name arrives in the bridge\'s status replies, through createPiHost', async () => {
  const root = fs.mkdtempSync('/private/tmp/shp-pn-'), socketPath = path.join(root, 'c.sock'), bootstrap = path.join(root, 'bootstrap.json');
  const requests = []; let sessionName;
  const server = net.createServer(connection => {
    let input = '';
    connection.on('data', chunk => {
      input += chunk; const newline = input.indexOf('\n'); if (newline < 0) return;
      const request = JSON.parse(input.slice(0, newline)); requests.push(request.command);
      const reply = request.command === 'open' ? { ok: true, mcp: { command: '/owned/node', args: ['/owned/mcp-run.mjs', '/owned/descriptor.json'] } }
        : request.command === 'status' ? { ok: true, ready: true, quiescent: true, ...(sessionName ? { sessionName } : {}) } : { ok: true };
      connection.end(JSON.stringify(reply) + '\n');
    });
  });
  try {
    await new Promise(resolve => server.listen(socketPath, resolve)); fs.chmodSync(socketPath, 0o600);
    fs.writeFileSync(bootstrap, JSON.stringify({ version: 1, launchID: crypto.randomUUID(), capability: crypto.randomBytes(32).toString('base64'), socketPath,
      node: process.execPath, helper: fileURLToPath(new URL('../../../Shepherd/Agents/AgentRuntime/pi-control.mjs', import.meta.url)), herdrReporting: false }), { mode: 0o600 });
    const f = namingFixture(); f.emit('session_start');
    const host = createPiHost(bootstrap, { report: () => {}, onFailure: () => assert.fail('bridge failure'), sessionName: f.naming.offer });
    const lease = await host.open({ pid: process.pid }, undefined);
    try {
      await lease.refresh(); assert.deepEqual(f.names, [], 'no name, nothing set');
      sessionName = { sequence: 1, name: 'From the pane' };
      await lease.refresh(); await lease.refresh(); assert.deepEqual(f.names, ['From the pane'], 'the same number set once');
      f.emit('agent_start'); sessionName = { sequence: 2, name: 'While working' };
      await lease.refresh(); assert.deepEqual(f.names, ['From the pane'], 'not while Pi works');
      f.emit('agent_settled'); assert.deepEqual(f.names, ['From the pane', 'While working'], 'set once Pi has settled');
      sessionName = { sequence: 3, name: 'Third' }; await lease.refresh();
      assert.deepEqual(f.names, ['From the pane', 'While working', 'Third'], 'a new number, a new name');
      assert(requests.filter(command => command === 'status').length >= 5);
    } finally { await lease.close(); }
  } finally {
    await new Promise(resolve => server.close(resolve)); fs.rmSync(root, { recursive: true, force: true });
  }
});

// The agent proxy (SHPHRD-105): pi-api-proxy.mjs with a stand-in Pi, reading
// the launch.json the app writes beside the bridge's bootstrap file.
function proxyFixture(manifest, { mode = 0o600 } = {}) {
  const folder = fs.mkdtempSync(path.join(directory, 'proxy-')), bootstrap = path.join(folder, 'bootstrap.json');
  if (manifest !== undefined) fs.writeFileSync(path.join(folder, 'launch.json'), typeof manifest === 'string' ? manifest : JSON.stringify(manifest), { mode });
  const providers = [], handlers = new Map();
  const pi = { registerProvider(name, config) { providers.push([name, config]); }, on(name, handler) { assert(!handlers.has(name)); handlers.set(name, handler); } };
  return { bootstrap, providers, handlers, pi };
}
const proxyBase = 'http://127.0.0.1:24680/p/' + 'ab'.repeat(16);
const providerContext = (provider, session = 'a1111111-1111-1111-1111-111111111111') => ({ model: provider ? { provider, id: 'model' } : undefined,
  sessionManager: { getSessionId: () => session } });
test('Agent proxy: Pi\'s anthropic and openai-codex providers are pointed at the base URL from launch.json, nothing else', () => {
  const f = proxyFixture({ version: 1, cli: '/owned/cli.js', bootstrap: '/owned/bootstrap.json', cwd: '/owned', arguments: [], apiProxy: { baseURL: proxyBase } });
  assert.equal(registerPiApiProxy(f.pi, f.bootstrap), true);
  assert.deepEqual(f.providers, [['anthropic', { baseUrl: proxyBase }], ['openai-codex', { baseUrl: proxyBase + '/backend-api' }]]);
  assert.deepEqual([...f.handlers.keys()], ['before_provider_headers']);
  assert.deepEqual(PROXIED_PROVIDERS, ['anthropic', 'openai-codex']);
});
test('Agent proxy: requests to those providers say which Pi session they are of; others are left alone', () => {
  const f = proxyFixture({ version: 1, apiProxy: { baseURL: proxyBase } }); registerPiApiProxy(f.pi, f.bootstrap);
  const headers = provider => { const event = { type: 'before_provider_headers', headers: { authorization: 'Bearer fixture' } }; f.handlers.get('before_provider_headers')(event, providerContext(provider)); return event.headers; };
  for (const provider of ['anthropic', 'openai-codex'])
    assert.deepEqual(headers(provider), { authorization: 'Bearer fixture', 'x-3rdr-pi-session': 'a1111111-1111-1111-1111-111111111111', 'x-3rdr-pi-class': 'main' }, provider);
  for (const provider of ['openai', 'google', 'openrouter', undefined]) assert.deepEqual(headers(provider), { authorization: 'Bearer fixture' }, String(provider));
  const event = { headers: {} }; f.handlers.get('before_provider_headers')(event, providerContext('anthropic', 'bad id\nwith a line'));
  assert.deepEqual(event.headers, { 'x-3rdr-pi-class': 'main' }, 'a session ID that isn\'t one is not sent');
  assert.doesNotThrow(() => f.handlers.get('before_provider_headers')({}, providerContext('anthropic')));
});
test('Agent proxy: without a valid base URL in a private launch.json, Pi is left as it is', () => {
  const cases = [
    proxyFixture({ version: 1, cli: '/owned/cli.js', arguments: [] }),
    proxyFixture({ version: 1, apiProxy: {} }),
    proxyFixture({ version: 1, apiProxy: { baseURL: 'https://127.0.0.1:24680/p/' + 'ab'.repeat(16) } }),
    proxyFixture({ version: 1, apiProxy: { baseURL: 'http://example.invalid:24680/p/' + 'ab'.repeat(16) } }),
    proxyFixture({ version: 1, apiProxy: { baseURL: proxyBase + '/extra' } }),
    proxyFixture({ version: 1, apiProxy: { baseURL: 'http://127.0.0.1:99999/p/' + 'ab'.repeat(16) } }),
    proxyFixture({ version: 1, apiProxy: { baseURL: proxyBase } }, { mode: 0o644 }),
    proxyFixture('{not json'),
    proxyFixture(undefined),
  ];
  for (const f of cases) { assert.equal(registerPiApiProxy(f.pi, f.bootstrap), false); assert.deepEqual(f.providers, []); assert.equal(f.handlers.size, 0); }
  assert.equal(apiProxyBase('relative/bootstrap.json'), null);
  assert.equal(apiProxyBase(undefined), null);
});
test('Agent proxy: the extension is registered from pi-entry.ts with the bridge\'s bootstrap file, and is part of the runtime\'s version', () => {
  const entry = fs.readFileSync(new URL('../../../Shepherd/Agents/AgentRuntime/pi-entry.ts', import.meta.url), 'utf8');
  assert(entry.includes("import { registerPiApiProxy } from './pi-api-proxy.mjs';") && entry.includes('registerPiApiProxy(pi, bootstrap);'));
  assert(entry.indexOf("if (!bootstrap) throw new Error('pi-host-bridge-unavailable');") < entry.indexOf('registerPiApiProxy(pi, bootstrap);'));
  const runtime = fs.readFileSync(new URL('../../../Shepherd/Agents/AgentRuntime/runtime.mjs', import.meta.url), 'utf8');
  assert(runtime.includes("'pi-launch.mjs','pi-api-proxy.mjs','pi-guidance.md'"));
});
