import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createPiHost } from './pi-host.mjs';
import { registerPiLifecycle } from './pi-lifecycle.mjs';
import { createPiMcpRegistration } from './pi-mcp-registration.mjs';
import { registerPiSessionNaming } from './pi-session-name.mjs';
import { createPiCaptureAuthority, registerPiApiProxy } from './pi-api-proxy.mjs';

/** Loaded only by an explicitly prepared invocation; never installed globally. */
export default function shepherdPi(pi: ExtensionAPI) {
  const bootstrap = process.env.SHEPHERD_PI_BRIDGE;
  if (!bootstrap) throw new Error('pi-host-bridge-unavailable');
  let controller: ReturnType<typeof registerPiLifecycle> | undefined;
  let ui: { setStatus(key: string, text: string | undefined): void } | undefined;
  let controlHealthy = true;
  const capture = createPiCaptureAuthority();
  pi.on('session_start', (_event, ctx: any) => { if (ctx?.mode === 'tui') capture.clear(); });
  pi.on('session_shutdown', (_event, ctx: any) => { if (ctx?.mode === 'tui') capture.clear(); });
  const onFailure = () => { controlHealthy = false; void controller?.shutdown(); };
  // The agent proxy, when the app gave this launch one (SHPHRD-105).
  registerPiApiProxy(pi, bootstrap, { captureAllowed: capture.allows });
  // The pane's name from the app's Rename Pane, set on the session while Pi is idle.
  const naming = registerPiSessionNaming(pi);
  const registration = createPiMcpRegistration(pi);
  const nativeHost = createPiHost(bootstrap, {
    report: (state: string) => {
      pi.events.emit('shepherd:pi-status:v1', { state });
      ui?.setStatus('3rdr-browser', state === 'off' ? undefined : `3rdr: ${state}`);
    },
    onFailure,
    sessionName: naming.offer,
  });
  const host = {
    report: nativeHost.report,
    open: async (identity: any, signal: AbortSignal) => {
      if (!controlHealthy) throw new Error('pi-control-channel-failed');
      const lease = await nativeHost.open(identity, signal);
      // Native host admission proves this root session; browser/MCP readiness
      // and later lease retirement do not replace that session identity.
      capture.qualify(identity.sessionID);
      return {
        ...lease,
        verifyMcp: async () => {
          await registration.ensureConnected();
          return lease.verifyMcp();
        },
      };
    },
  };
  const interactive = {
    registerMcpServer: registration.registerMcpServer,
    unregisterMcpServer: registration.unregisterMcpServer,
    on: (event: string, handler: (event: unknown, ctx: any) => unknown) => {
      // Headless/subagent qualification is deliberately separate. Inherited
      // bootstrap environment never gives a child the parent's browser lease.
      return (pi.on as any)(event, (value: unknown, ctx: any) => {
        if (ctx.mode !== 'tui') {
          if (event === 'session_start') throw new Error('pi-interactive-session-required');
          return;
        }
        ui = ctx.ui;
        return handler(value, ctx);
      });
    },
  };
  controller = registerPiLifecycle(interactive, host, { nonblockingStartup: true });
}
