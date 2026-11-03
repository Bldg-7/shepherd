import fs from 'node:fs';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';

/** Test-only lifecycle observation. No browser registration, credentials,
 * transcript, prompt or model output is read. Not an authority provider. */
export default function observer(pi: ExtensionAPI) {
  const file = process.env.HC_CLI_TRACE;
  if (!file) throw new Error('owned trace path required');
  const write = (value: unknown) => fs.appendFileSync(file, JSON.stringify(value) + '\n', { mode: 0o600 });
  for (const event of ['session_start', 'session_shutdown', 'session_before_switch'] as const) {
    pi.on(event, (_event, ctx) => {
      write({ event, pid: process.pid, mode: ctx.mode, cwd: ctx.cwd,
        sessionID: ctx.sessionManager.getSessionId(), sessionFile: ctx.sessionManager.getSessionFile(),
        modelObjectPresent: !!ctx.model });
    });
  }
  // Unexpected non-command input must not reach a model. Built-in /new is
  // handled by Pi itself; if it ever becomes ordinary input the test fails.
  pi.on('input', () => {
    write({ event: 'unexpected_input_blocked' });
    return { action: 'handled' };
  });
}
