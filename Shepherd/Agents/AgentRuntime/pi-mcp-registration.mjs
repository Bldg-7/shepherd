import {PiIntegrationError} from './pi-runtime.mjs';
const unavailable=()=>new PiIntegrationError('pi-mcp-registration-unavailable');

// Both backends retain their normal approval/config policy. An adapter response
// (including a rejection) is authoritative: never silently fall back to built-in.
export function createPiMcpRegistration(pi) {
  let current;
  return {
    registerMcpServer(name,config) {
      if(current)throw unavailable();
      const request={version:1,name,definition:{command:config.command,args:[...config.args],lifecycle:'eager',idleTimeout:0,inheritEnv:false,env:{PATH:process.env.PATH ?? '/usr/bin:/bin',HOME:process.env.HOME ?? '/'}}};
      pi.events.emit('pi-mcp-adapter:runtime-register:v1',request);
      if(request.result===undefined) {
        pi.registerMcpServer(name,config);
        current={name,backend:'builtin',retired:false};return;
      }
      if(request.result?.ok!==true || typeof request.result.registration?.dispose!=='function')throw unavailable();
      current={name,backend:'adapter',registration:request.result.registration,retired:false};
    },
    async ensureConnected() {
      const record=current;
      if(!record || record.retired)throw unavailable();
      if(record.backend==='builtin')return;
      // This mediated connection performs initialize/tool discovery only. It
      // exposes no SDK client/transport and never invokes a browser tool.
      const request={version:1,definition:{namespace:'shepherd',requests:[],streams:[],notifications:[]}};
      pi.events.emit('pi-mcp-adapter:protocol:v1',request);
      const protocol=request.result;
      if(request.error || typeof protocol?.connect!=='function' || typeof protocol?.dispose!=='function')throw unavailable();
      record.protocol=protocol;
      try {
        const session=await protocol.connect(record.name);
        session.close();
        if(record.retired || current!==record)throw unavailable();
      } finally { protocol.dispose(); }
    },
    async unregisterMcpServer(name) {
      const record=current;
      if(!record || record.name!==name)throw unavailable();
      current=undefined;record.retired=true;
      // Synchronously remove dispatch before awaiting physical disconnect.
      record.protocol?.dispose();
      if(record.backend==='builtin')pi.unregisterMcpServer(name);
      else await record.registration.dispose();
    },
  };
}
