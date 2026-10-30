// mcp-run.mjs against the pinned Playwright MCP in AgentRuntime/node_modules.
// Fake descriptor and token; the only CDP endpoint is a local socket owned here.
// `node McpRunTests.mjs --update` rewrites playwright-mcp-snapshot.json.
import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';

const runtime = fileURLToPath(new URL('../../../Shepherd/Agents/AgentRuntime/', import.meta.url));
const wrapper = path.join(runtime, 'mcp-run.mjs'), snapshotFile = path.join(runtime, 'playwright-mcp-snapshot.json');
const cli = path.join(runtime, 'node_modules/@playwright/mcp/cli.js');
const UNAVAILABLE = {code: -32603, message: '3rdr browser is unavailable.'};
const NOT_FOUND = {code: -32601, message: 'Method not found'};
const clientInit = (protocolVersion = '2025-06-18', capabilities = {}) => ({protocolVersion, capabilities, clientInfo: {name: 'owned-mcp-run-fixture', version: '1'}});
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// mode: 'refuse' closes each CDP connection at once, 'hold' never answers it.
async function fixture({pi, admit = true} = {}) {
  const root = fs.mkdtempSync('/private/tmp/shp-mr-'); fs.chmodSync(root, 0o700);
  const cdp = {mode: 'refuse', connections: 0, sockets: new Set()};
  cdp.server = net.createServer(socket => { cdp.connections++; cdp.sockets.add(socket); socket.on('error', () => {}); if (cdp.mode === 'refuse') socket.destroy(); });
  await new Promise(resolve => cdp.server.listen(0, '127.0.0.1', resolve));
  const secret = crypto.randomBytes(32).toString('base64'), token = path.join(root, 'token');
  fs.writeFileSync(token, secret, {mode: 0o600});
  const output = path.join(root, 'output'); fs.mkdirSync(output, {mode: 0o700});
  const sessionDir = path.join(root, 'session'); fs.mkdirSync(sessionDir, {mode: 0o700});
  const browser = path.join(sessionDir, 'browser.json');
  fs.writeFileSync(browser, JSON.stringify({pane: {machineID: 'm', session: 'default', paneID: 'w1:p1', terminalID: 't'},
    endpoint: {origin: 'thisMac', url: `ws://127.0.0.1:${cdp.server.address().port}/v1/herdr/default/pane/w1:p1`, tokenFile: token},
    outputFolder: output, outputMaxSize: 1048576, allowedOrigins: [], blockedOrigins: []}), {mode: 0o600});
  const f = {root, cdp, secret, output, sessionDir, browser, descriptor: browser, commands: [], configs: () => fs.readdirSync(sessionDir).filter(name => /^\.mcp-\d+\.json$/.test(name))};
  if (pi) {
    const socketPath = path.join(root, 'c.sock'), bootstrap = path.join(root, 'bootstrap.json');
    f.bridge = net.createServer(connection => {
      let input = '';
      connection.on('data', chunk => {
        input += chunk; const newline = input.indexOf('\n'); if (newline < 0) return;
        const request = JSON.parse(input.slice(0, newline));
        f.commands.push({command: request.command, attemptID: request.attemptID, configs: f.configs().length, answered: [...(f.answered ?? [])]});
        connection.end(JSON.stringify({ok: admit}) + '\n');
      });
    });
    await new Promise(resolve => f.bridge.listen(socketPath, resolve)); fs.chmodSync(socketPath, 0o600);
    fs.writeFileSync(bootstrap, JSON.stringify({version: 1, launchID: crypto.randomUUID(), capability: crypto.randomBytes(32).toString('base64'), socketPath,
      node: process.execPath, helper: path.join(runtime, 'pi-control.mjs')}), {mode: 0o600});
    f.attemptID = crypto.randomUUID();
    f.descriptor = path.join(root, 'mcp.json');
    fs.writeFileSync(f.descriptor, JSON.stringify({piBridge: {bootstrap, attemptID: f.attemptID}, browserDescriptor: browser}), {mode: 0o600});
  }
  f.close = async () => {
    for (const socket of cdp.sockets) socket.destroy();
    await new Promise(resolve => cdp.server.close(resolve));
    if (f.bridge) await new Promise(resolve => f.bridge.close(resolve));
    fs.rmSync(root, {recursive: true, force: true});
  };
  return f;
}
// A JSON-RPC peer over a child's stdio; `answered` lists response ids in order.
// With `roots`, it answers the server's roots/list requests with them.
function peer(child, f, roots) {
  const messages = [], waiters = [];
  const write = message => child.stdin.write(JSON.stringify({jsonrpc: '2.0', ...message}) + '\n');
  let pending = '', stderr = '';
  child.stderr.on('data', data => stderr += data);
  child.stdout.on('data', data => {
    pending += data; let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
      if (f) assert(!line.includes(f.secret), 'secret on stdout');
      const message = JSON.parse(line); messages.push(message);
      if (roots && message.method === 'roots/list') write({id: message.id, result: {roots}});
      if (f && message.method === undefined) (f.answered ??= []).push(message.id);
      for (const waiter of [...waiters]) if (waiter.match(message)) { waiters.splice(waiters.indexOf(waiter), 1); waiter.resolve(message); }
    }
  });
  const wait = (match, ms = 20000) => {
    const found = messages.find(match); if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const waiter = {match, resolve: value => { clearTimeout(timer); resolve(value); }};
      const timer = setTimeout(() => { waiters.splice(waiters.indexOf(waiter), 1); reject(new Error('no reply in time: ' + JSON.stringify(messages.map(m => [m.id, m.method, m.error?.code])))); }, ms);
      waiters.push(waiter);
    });
  };
  return {messages, wait, write, stderr: () => stderr,
    request: (id, method, params) => { write({id, method, params}); return wait(m => m.id === id && m.method === undefined); },
    notify: (method, params) => write({method, ...(params ? {params} : {})})};
}
const run = (f, args = [f.descriptor], env = {}) => spawn(process.execPath, [wrapper, ...args], {cwd: f.root, stdio: ['pipe', 'pipe', 'pipe'],
  env: {PATH: process.env.PATH, HOME: process.env.HOME, ...env}});
const children = pid => execFileSync('ps', ['-A', '-o', 'pid=,ppid=']).toString().trim().split('\n').map(line => line.trim().split(/\s+/).map(Number))
  .filter(([, parent]) => parent === pid).map(([child]) => child);
const exited = child => child.exitCode !== null || child.signalCode !== null ? Promise.resolve([child.exitCode, child.signalCode]) : once(child, 'exit');
async function waitFor(condition, ms = 20000) {
  const deadline = Date.now() + ms;
  while (!condition()) { if (Date.now() > deadline) throw new Error('condition deadline'); await delay(25); }
}
// The pinned server itself, with the exact config file the wrapper wrote.
async function pinned(f) {
  const child = run(f), client = peer(child, f);
  await waitFor(() => f.configs().length === 1);
  const config = path.join(f.root, 'pinned-config.json');
  fs.copyFileSync(path.join(f.sessionDir, f.configs()[0]), config); fs.chmodSync(config, 0o600);
  child.stdin.end(); assert.deepEqual(await exited(child), [0, null]); void client;
  return protocolVersion => {
    const server = spawn(process.execPath, [cli, '--config', config], {cwd: f.output, stdio: ['pipe', 'pipe', 'pipe'], env: {PATH: process.env.PATH, HOME: process.env.HOME}});
    return {server, client: peer(server, f)};
  };
}
async function liveReplies(start, protocolVersion) {
  const {server, client} = start();
  try {
    const initialize = await client.request(1, 'initialize', clientInit(protocolVersion));
    client.notify('notifications/initialized');
    const [tools, resources, ping] = await Promise.all([client.request(2, 'tools/list', {}), client.request(3, 'resources/list', {}), client.request(4, 'ping')]);
    return {initialize, tools, resources, ping};
  } finally { server.stdin.end(); await exited(server); }
}

if (process.argv[2] === '--update') {
  // The wrapper reads the snapshot at start: a first one is a stand-in.
  if (!fs.existsSync(snapshotFile)) fs.writeFileSync(snapshotFile, JSON.stringify({version: '0.0.83', protocolVersions: [], initialize: {}, tools: []}));
  const f = await fixture();
  try {
    const bundle = fs.readFileSync(path.join(runtime, 'node_modules/playwright-core/lib/utilsBundle.js'), 'utf8');
    const latest = /LATEST_PROTOCOL_VERSION = "([0-9-]+)"/.exec(bundle)[1];
    const protocolVersions = /SUPPORTED_PROTOCOL_VERSIONS = \[LATEST_PROTOCOL_VERSION((?:, "[0-9-]+")*)\]/.exec(bundle)[1].match(/[0-9]{4}-[0-9]{2}-[0-9]{2}/g);
    protocolVersions.unshift(latest);
    const replies = await liveReplies(await pinned(f), latest);
    const {protocolVersion, ...initialize} = replies.initialize.result;
    assert.equal(protocolVersion, latest);
    const version = JSON.parse(fs.readFileSync(path.join(runtime, 'node_modules/@playwright/mcp/package.json'), 'utf8')).version;
    fs.writeFileSync(snapshotFile, JSON.stringify({version, protocolVersions, initialize, tools: replies.tools.result.tools}, null, 1) + '\n');
    process.stdout.write('wrote ' + snapshotFile + '\n');
  } finally { await f.close(); }
} else {
  const snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));

  test('the snapshot is what the pinned Playwright MCP answers, for every protocol version, without a browser', async () => {
    const f = await fixture();
    try {
      const start = await pinned(f);
      for (const version of [...snapshot.protocolVersions, '1999-01-01']) {
        const replies = await liveReplies(start, version);
        assert.deepEqual(replies.initialize.result, {protocolVersion: version === '1999-01-01' ? snapshot.protocolVersions[0] : version, ...snapshot.initialize}, version);
        assert.deepEqual(replies.tools.result, {tools: snapshot.tools}, version);
        assert.deepEqual(replies.resources.error, NOT_FOUND);
        assert.deepEqual(replies.ping.result, {});
      }
      assert.equal(snapshot.version, '0.0.83');
      assert(['browser_snapshot', 'browser_navigate', 'browser_tabs'].every(name => snapshot.tools.some(tool => tool.name === name)));
      assert.equal(f.cdp.connections, 0, 'initialize/tools/list never connect to the browser');
    } finally { await f.close(); }
  });

  test('the wrapper answers the handshake itself and starts no server', async () => {
    const f = await fixture(), child = run(f), client = peer(child, f);
    try {
      const initialize = await client.request(1, 'initialize', clientInit('2024-11-05'));
      assert.deepEqual(initialize.result, {protocolVersion: '2024-11-05', ...snapshot.initialize});
      client.notify('notifications/initialized');
      assert.deepEqual((await client.request('again', 'initialize', clientInit('1999-01-01'))).result.protocolVersion, snapshot.protocolVersions[0]);
      assert.deepEqual((await client.request(2, 'tools/list', {})).result, {tools: snapshot.tools});
      assert.deepEqual((await client.request(3, 'ping')).result, {});
      assert.deepEqual((await client.request(4, 'resources/list', {})).error, NOT_FOUND);
      assert.deepEqual((await client.request(5, 'prompts/list', {})).error, NOT_FOUND);
      client.notify('notifications/cancelled', {requestId: 9});
      // An output name outside the pane folder is refused here, before any start.
      const escape = await client.request(6, 'tools/call', {name: 'browser_take_screenshot', arguments: {filename: '../outside.png'}});
      assert.equal(escape.result.isError, true); assert.match(escape.result.content[0].text, /inside this pane output folder/);
      await delay(500);
      assert.deepEqual(children(child.pid), [], 'no Playwright process before a tools/call');
      const [config] = f.configs(); assert(config, 'config written at start');
      assert.equal(fs.statSync(path.join(f.sessionDir, config)).mode & 0o777, 0o600);
      assert(!client.messages.some(m => m.id === 9));
      child.stdin.end(); assert.deepEqual(await exited(child), [0, null]);
      assert.deepEqual(f.configs(), [], 'config removed');
      assert.equal(f.cdp.connections, 0);
    } finally { child.kill('SIGKILL'); await f.close(); }
  });

  test('the first tools/call starts Playwright once, with the client\'s initialize, keeping ids and order', async () => {
    const f = await fixture(), child = run(f), client = peer(child, f, [{uri: 'file://' + f.output}]);
    try {
      await client.request(1, 'initialize', clientInit('2025-06-18', {roots: {}}));
      client.notify('notifications/initialized');
      await client.request(2, 'tools/list', {});
      client.write({id: 'first', method: 'tools/call', params: {name: 'browser_tabs', arguments: {action: 'list'}}});
      client.write({id: 3, method: 'ping'});
      client.write({id: 4, method: 'tools/call', params: {name: 'browser_tabs', arguments: {action: 'list'}}});
      // Playwright asks a client with roots for them: relayed out, the answer relayed back.
      await client.wait(m => m.method === 'roots/list');
      const [first, second] = await Promise.all([client.wait(m => m.id === 'first'), client.wait(m => m.id === 4)]);
      for (const reply of [first, second]) { assert.equal(reply.result.isError, true); assert.match(reply.result.content[0].text, /Error/); }
      assert.deepEqual(client.messages.find(m => m.id === 3).result, {});
      assert(client.messages.indexOf(client.messages.find(m => m.id === 3)) < client.messages.indexOf(first), 'local replies do not wait for the server');
      assert(client.messages.indexOf(first) < client.messages.indexOf(second), 'forwarded in arrival order');
      assert(f.cdp.connections >= 1, 'the call reached the owned CDP endpoint');
      const [server] = children(child.pid); assert(server);
      await client.request(5, 'tools/call', {name: 'browser_tabs', arguments: {action: 'list'}});
      assert.deepEqual(children(child.pid), [server], 'one server for later calls');
      assert(!client.messages.some(m => m.id === '3rdr-initialize'));
      child.stdin.end(); assert.deepEqual(await exited(child), [0, null]);
      assert.deepEqual(f.configs(), []);
    } finally { child.kill('SIGKILL'); await f.close(); }
  });

  test('a server that dies fails its pending calls, and the next call starts a new one', async () => {
    const f = await fixture(), child = run(f), client = peer(child, f);
    try {
      await client.request(1, 'initialize', clientInit());
      f.cdp.mode = 'hold';
      client.write({id: 2, method: 'tools/call', params: {name: 'browser_tabs', arguments: {action: 'list'}}});
      await waitFor(() => f.cdp.connections === 1);
      const [server] = children(child.pid);
      client.write({id: 3, method: 'tools/call', params: {name: 'browser_tabs', arguments: {action: 'list'}}});
      await delay(200);
      process.kill(server, 'SIGKILL');
      const [two, three] = await Promise.all([client.wait(m => m.id === 2), client.wait(m => m.id === 3)]);
      assert.deepEqual(two.error, UNAVAILABLE); assert.deepEqual(three.error, UNAVAILABLE);
      await waitFor(() => children(child.pid).length === 0);
      await delay(300); assert.deepEqual(children(child.pid), [], 'not restarted on its own');
      f.cdp.mode = 'refuse';
      const again = await client.request(4, 'tools/call', {name: 'browser_tabs', arguments: {action: 'list'}});
      assert.equal(again.result.isError, true);
      const [next] = children(child.pid); assert(next && next !== server);
      // Killed while it starts: the waiting call fails too.
      process.kill(next, 'SIGKILL'); await waitFor(() => children(child.pid).length === 0);
      client.write({id: 5, method: 'tools/call', params: {name: 'browser_tabs', arguments: {action: 'list'}}});
      await waitFor(() => children(child.pid).length === 1, 5000);
      process.kill(children(child.pid)[0], 'SIGKILL');
      assert.deepEqual((await client.wait(m => m.id === 5)).error, UNAVAILABLE);
      assert(!client.stderr().includes(f.secret) && !client.stderr().includes(f.root));
      child.kill('SIGTERM'); assert.deepEqual(await exited(child), [0, null]);
      assert.deepEqual(f.configs(), []);
    } finally { child.kill('SIGKILL'); await f.close(); }
  });

  test('SIGTERM, an oversized line or an unsafe descriptor end the wrapper', async () => {
    const f = await fixture();
    try {
      let child = run(f), client = peer(child, f);
      await client.request(1, 'initialize', clientInit());
      child.kill('SIGTERM'); assert.deepEqual(await exited(child), [0, null]); assert.deepEqual(f.configs(), []);
      child = run(f); client = peer(child, f);
      assert.deepEqual((await client.request(0, 'tools/call', {name: 'browser_tabs', arguments: {action: 'list'}})).error, UNAVAILABLE, 'no call before initialize');
      assert.deepEqual(children(child.pid), []);
      await client.request(1, 'initialize', clientInit());
      child.stdin.write('{"jsonrpc":"2.0","id":2,"method":"ping","params":{"x":"' + 'x'.repeat(1024 * 1024) + '"}}\n');
      assert.deepEqual(await exited(child), [1, null]); assert.match(client.stderr(), /^3rdr MCP connection is unavailable\.\n$/); assert.deepEqual(f.configs(), []);
      fs.chmodSync(f.browser, 0o644);
      child = run(f); client = peer(child, f); child.stdin.end();
      assert.deepEqual(await exited(child), [1, null]); assert.match(client.stderr(), /unavailable or unsafe/); assert.deepEqual(f.configs(), []);
    } finally { await f.close(); }
  });

  test('Pi descriptor: mcpAttach before any browser resource, mcpReady before the tools/list reply', async () => {
    const f = await fixture({pi: true}), child = run(f), client = peer(child, f);
    try {
      await waitFor(() => f.commands.length === 1);
      assert.deepEqual(f.commands[0], {command: 'mcpAttach', attemptID: f.attemptID, configs: 0, answered: []});
      await client.request(1, 'tools/list', {});
      await client.request(2, 'initialize', clientInit());
      assert.equal(f.commands.length, 1, 'ready only after initialize');
      await client.request(3, 'tools/list', {});
      assert.deepEqual(f.commands.slice(1), [{command: 'mcpReady', attemptID: f.attemptID, configs: 1, answered: [1, 2]}]);
      await client.request(4, 'tools/list', {});
      assert.equal(f.commands.length, 2, 'ready once');
      assert.deepEqual(children(child.pid), []);
      const call = await client.request(5, 'tools/call', {name: 'browser_tabs', arguments: {action: 'list'}});
      assert.equal(call.result.isError, true);
      child.stdin.end(); assert.deepEqual(await exited(child), [0, null]);
    } finally { child.kill('SIGKILL'); await f.close(); }
  });

  test('Pi descriptor: a refused admission or an inherited descriptor never reaches the browser', async () => {
    const f = await fixture({pi: true, admit: false});
    try {
      let child = run(f), client = peer(child, f);
      assert.deepEqual(await exited(child), [1, null]);
      assert.equal(client.stderr(), '3rdr MCP configuration is unavailable or unsafe.\n');
      assert.deepEqual(f.commands.map(c => c.command), ['mcpAttach']); assert.deepEqual(f.configs(), []);
      child = run(f, ['--environment'], {SHEPHERD_AGENT_SESSION: f.descriptor}); client = peer(child, f);
      assert.deepEqual(await exited(child), [1, null]);
      assert.equal(f.commands.length, 1, 'no admission asked from the environment'); assert.deepEqual(f.configs(), []);
    } finally { await f.close(); }
  });
}
