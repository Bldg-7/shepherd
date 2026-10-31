import fs from 'node:fs';
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';

// Test-only observer in the owned profile. No prompts, arguments or auth values.
export default function observer(pi: ExtensionAPI) {
  const file = process.env.SHEPHERD_PI_FIXTURE_TRACE;
  if (!file) throw new Error('owned trace path required');
  const write = (value: unknown) => fs.appendFileSync(file, JSON.stringify(value) + '\n', { mode: 0o600 });
  pi.events.on('shepherd:pi-status:v1', (value: any) => {
    const tools = value?.state === 'ready' ? pi.getAllTools().filter(tool => tool.name.startsWith('mcp__3rdr_browser__')).map(tool => tool.name) : undefined;
    // pi-mcp-adapter's runtime snapshot: whether it holds the server now. No definition is written.
    const snapshot: any = { version: 1, name: '3rdr-browser' };
    if (value?.state === 'ready') pi.events.emit('pi-mcp-adapter:runtime-snapshot:v1', snapshot);
    write({event:'status', value, tools, adapterServer: snapshot.result?.ok === true && snapshot.result.snapshot?.name === '3rdr-browser'});
  });
  pi.on('session_start', (_event, ctx) => {
    write({event:'session',pid:process.pid,mode:ctx.mode,cwd:ctx.cwd,id:ctx.sessionManager.getSessionId(),
      file:ctx.sessionManager.getSessionFile(),leaf:ctx.sessionManager.getLeafId()});
  });
}
