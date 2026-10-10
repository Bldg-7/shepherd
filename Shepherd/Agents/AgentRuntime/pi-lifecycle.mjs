import path from 'node:path';
import {PiIntegrationError} from './pi-runtime.mjs';

const SERVER = 'shepherd-browser';
const fail = code => { throw new PiIntegrationError(code); };
const absolute = value => typeof value === 'string' && path.isAbsolute(value) && !value.includes('\0');

/**
 * Pi extension lifecycle core; pi-entry.ts supplies the CLI entry and host.
 * The caller must supply a qualified app bridge; agent-provided JSON/environment
 * is not a bridge. No default host, same-UID sandbox claim, or local-only fallback.
 *
 * host.open(identity, signal) -> lease after authenticated PID/start/session/pane
 * proof. lease.revoke() MUST synchronously retire native authority and return true.
 * lease.close() awaits native detach/child cleanup; verifyMcp() proves the actual
 * effective registration (including config-file shadowing), not just API success.
 * Production entry/host implementation stays gated until these contracts qualify.
 */
export function registerPiLifecycle(pi, host, { timeoutMs = 10000, nonblockingStartup = false } = {}) {
  if (!host || typeof host.open !== 'function' || typeof host.report !== 'function' ||
      typeof pi.registerMcpServer !== 'function' || typeof pi.unregisterMcpServer !== 'function') fail('pi-host-bridge-unavailable');
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000) fail('pi-deadline-invalid');
  let generation = 0, current, pending, state = 'off', lastIdentity, startup = Promise.resolve();
  const retiring = new Set(), unsettledOpens = new Set();
  function report(next) {
    state = next;
    // Fixed status codes only. No transcript, tool arguments or raw errors.
    try { host.report(next); } catch {
      // A broken status/control channel is not permission to leave MCP live.
      state = 'failed'; generation++;
      pending?.abort(); pending = undefined;
      const record = current; current = undefined;
      if (record) void dispose(record);
    }
  }
  function identity(ctx) {
    const value = { pid: process.pid, cwd: ctx.cwd, sessionID: ctx.sessionManager.getSessionId(),
      sessionFile: ctx.sessionManager.getSessionFile(), leafID: ctx.sessionManager.getLeafId() };
    if (!absolute(value.cwd) || typeof value.sessionID !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,126}[a-zA-Z0-9]$/.test(value.sessionID) ||
        !absolute(value.sessionFile) || (value.leafID !== null && typeof value.leafID !== 'string')) fail('pi-session-unverifiable');
    return Object.freeze(value);
  }
  function same(a, b, includeLeaf = true) {
    return !!a && !!b && ['pid', 'cwd', 'sessionID', 'sessionFile', ...(includeLeaf ? ['leafID'] : [])].every(key => a[key] === b[key]);
  }
  async function bounded(promise) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new PiIntegrationError('pi-bridge-timeout')), timeoutMs);
      })]);
    } finally { clearTimeout(timer); }
  }
  function dispose(record) {
    if (record.disposal) return record.disposal;
    retiring.add(record);
    let revoked = false;
    try { revoked = record.lease.revoke() === true; } catch {}
    let unregistration = Promise.resolve(true);
    if (record.registered) {
      try { unregistration = Promise.resolve(pi.unregisterMcpServer(SERVER)).then(() => true, () => false); }
      catch { unregistration = Promise.resolve(false); }
      record.registered = false;
    }
    record.disposal = (async () => {
      try {
        const [,unregistered] = await bounded(Promise.all([Promise.resolve().then(() => record.lease.close()), unregistration]));
        if (!revoked || !unregistered) fail('pi-retirement-unconfirmed');
        retiring.delete(record);
        return true;
      } catch { report('retirementUnconfirmed'); return false; }
    })();
    return record.disposal;
  }
  async function retire() {
    const epoch = ++generation;
    pending?.abort(); pending = undefined;
    const previous = current; current = undefined;
    report('revoking');
    if (previous) await dispose(previous);
    if (retiring.size || unsettledOpens.size) { report('retirementUnconfirmed'); return false; }
    if (epoch !== generation) return false;
    report('off'); return true;
  }
  async function start(ctx) {
    const retirement = retire(), epoch = generation;
    if (!await retirement || epoch !== generation) return;
    const controller = new AbortController(); pending = controller;
    report('binding');
    if (epoch !== generation || controller.signal.aborted) return;
    let record;
    try {
      const requested = identity(ctx);
      // Deliberately observe late resolution: a timed-out/cancelled open may
      // still allocate native authority and must compensate, never be forgotten.
      const ticket = {};
      unsettledOpens.add(ticket);
      const opening = Promise.resolve().then(() => host.open(requested, controller.signal)).then(async lease => {
        const entry = { lease, registered: false };
        if (controller.signal.aborted || epoch !== generation) {
          await dispose(entry);
          fail('pi-stale-binding');
        }
        return entry;
      }).finally(() => unsettledOpens.delete(ticket));
      try { record = await bounded(opening); }
      catch (error) { controller.abort(); throw error; }
      if (epoch !== generation || controller.signal.aborted) { await dispose(record); return; }
      const lease = record.lease;
      if (!lease || typeof lease.revoke !== 'function' || typeof lease.close !== 'function' ||
          typeof lease.verifyMcp !== 'function' || typeof lease.isQuiescent !== 'function' ||
          !same(requested, lease.identity) || !same(requested, identity(ctx))) fail('pi-binding-mismatch');
      const config = lease.mcp;
      if (!config || !absolute(config.command) || !Array.isArray(config.args) || config.args.length !== 2 ||
          !config.args.every(absolute) || config.url || config.env || config.headers) fail('pi-mcp-configuration-invalid');
      // No token-bearing config/URL or inherited vendor credentials added here.
      current = record;
      pi.registerMcpServer(SERVER, { command: config.command, args: [...config.args], exposure: 'codemode' });
      record.registered = true;
      if (await bounded(Promise.resolve().then(() => lease.verifyMcp())) !== true) fail('pi-mcp-ownership-unverified');
      if (epoch !== generation || current !== record) { await dispose(record); return; }
      if (!same(requested, identity(ctx))) fail('pi-binding-mismatch');
      lastIdentity = requested;
      report('ready');
    } catch {
      if (record) await dispose(record);
      if (epoch === generation) { current = undefined; report(retiring.size || unsettledOpens.size ? 'retirementUnconfirmed' : 'failed'); }
    } finally { if (epoch === generation) pending = undefined; }
  }
  async function activity(ctx, settled) {
    if (!current || !lastIdentity) return;
    try {
      // Ordinary conversation entries advance the leaf; only explicit tree /
      // fork events invalidate a branch. A different session/file/cwd always does.
      if (!same(lastIdentity, identity(ctx), false)) { await retire(); return; }
      const record = current, epoch = generation;
      if (settled && typeof record.lease.refresh === 'function') await bounded(record.lease.refresh());
      if (epoch !== generation || current !== record) return;
      // agent_end alone is not sufficient; automatic retry/continuation can follow.
      report(settled && ctx.isIdle() === true && ctx.hasPendingMessages() === false && current.lease.isQuiescent() === true ? 'idle' : 'busy');
    } catch { await retire(); }
  }
  pi.on('session_start', (_event, ctx) => {
    startup = start(ctx);
    // MCP implementations may initialize in a later session_start handler.
    // A CLI entry must not deadlock that handler while waiting for MCP proof.
    if (!nonblockingStartup) return startup;
  });
  pi.on('session_shutdown', async () => { await retire(); });
  for (const event of ['session_before_switch', 'session_before_fork', 'session_before_tree']) {
    pi.on(event, async () => !await retire() ? { cancel: true } : undefined);
  }
  pi.on('session_tree', (_event, ctx) => start(ctx));
  pi.on('agent_start', (_event, ctx) => activity(ctx, false));
  pi.on('agent_settled', (_event, ctx) => activity(ctx, true));
  return Object.freeze({ state: () => state, shutdown: retire, whenStarted: () => startup });
}
