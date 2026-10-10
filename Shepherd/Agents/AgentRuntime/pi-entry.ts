import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { createPiHost } from './pi-host.mjs';
import { registerPiLifecycle } from './pi-lifecycle.mjs';
import { createPiMcpRegistration } from './pi-mcp-registration.mjs';
import { registerPiHerdr } from './pi-herdr.mjs';

/** Loaded only by an explicitly prepared invocation; never installed globally. */
export default function shepherdPi(pi: ExtensionAPI) {
  const bootstrap = process.env.SHEPHERD_PI_BRIDGE;
  if (!bootstrap) throw new Error('pi-host-bridge-unavailable');
  let controller: ReturnType<typeof registerPiLifecycle> | undefined;
  let ui: { setStatus(key: string, text: string | undefined): void } | undefined;
  let controlHealthy = true;
  const onFailure = () => { controlHealthy = false; void controller?.shutdown(); };
  registerPiHerdr(pi, bootstrap, onFailure);
  const registration = createPiMcpRegistration(pi);
  const nativeHost = createPiHost(bootstrap, {
    report: (state: string) => {
      pi.events.emit('shepherd:pi-status:v1', { state });
      ui?.setStatus('shepherd-browser', state === 'off' ? undefined : `Shepherd: ${state}`);
    },
    onFailure,
  });
  const host = {
    report: nativeHost.report,
    open: async (identity: any, signal: AbortSignal) => {
      if (!controlHealthy) throw new Error('pi-control-channel-failed');
      const lease = await nativeHost.open(identity, signal);
      return { ...lease, verifyMcp: async () => { await registration.ensureConnected(); return lease.verifyMcp(); } };
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
