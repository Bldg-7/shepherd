import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';

// Test-only agent-folder extension (SHPHRD-146). Pi runs session_start handlers
// one at a time in load order: the managed CLI extension, then the agent
// folder's extensions, then installed packages such as pi-mcp-adapter. Herdr's
// own Pi extension sits in the agent folder and can wait on a socket reply in its
// session_start; this stands in for it, so the adapter's session starts late.
export default function slowSessionStart(pi: ExtensionAPI) {
  pi.on('session_start', async () => { await new Promise(resolve => setTimeout(resolve, 2000)); });
}
