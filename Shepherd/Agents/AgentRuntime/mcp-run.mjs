import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {protectedRead, privateDirectory, atomicWrite, validateEndpoint, requireValue, requireNode} from './runtime-core.mjs';

// Secrets exist only in this process and the protected MCP config, never argv
// or environment. Pinned MCP's supported --config reads browser.cdpHeaders.
// initialize, tools/list and ping are answered here from the pinned server's
// recorded replies (playwright-mcp-snapshot.json, compared with the live server
// by McpRunTests.mjs). With webmcp off its tool list never changes. Playwright
// MCP starts only when a tools/call arrives, the one request it has that this
// process does not answer; any other request gets its Method not found.
// A Pi descriptor ({piBridge, browserDescriptor}) is admitted by the app's
// bridge (mcpAttach) before anything else, and reported ready (mcpReady) once
// initialize and tools/list are answered.
let child, configFile, secret, control, finished=false, closing=false;
const INITIALIZE='3rdr-initialize', UNAVAILABLE='3rdr browser is unavailable.';
async function* lines(stream, limit) {
  let pending=Buffer.alloc(0);
  for await(const chunk of stream) {
    pending=Buffer.concat([pending,chunk]);
    let newline;
    while((newline=pending.indexOf(10))>=0) {
      if(newline>limit)throw new Error('limit');
      yield pending.subarray(0,newline).toString('utf8'); pending=pending.subarray(newline+1);
    }
    if(pending.length>limit)throw new Error('limit');
  }
  if(pending.length)throw new Error('incomplete');
}
// A destroyed stream (a server that died) never drains: stop waiting on close.
async function send(stream, line) {
  if(stream.write(line+'\n') || stream.destroyed)return;
  const abort=new AbortController();
  try { await Promise.race([once(stream,'drain',{signal:abort.signal}),once(stream,'close',{signal:abort.signal})]); } finally { abort.abort(); }
}
const respond=(id,body)=>send(process.stdout,JSON.stringify({jsonrpc:'2.0',id,...body}));
const unavailable=id=>respond(id,{error:{code:-32603,message:UNAVAILABLE}});
function finish(code) {
  if(finished)return; finished=true;
  try{fs.unlinkSync(configFile);}catch{}
  process.exitCode=code; process.stdin.destroy();
}
try {
  requireNode();
  let file=process.argv[2];
  const fromEnvironment=file === '--environment';
  if(fromEnvironment) file=process.env.SHEPHERD_AGENT_SESSION;
  requireValue(file !== '--global', 'session-only-policy');
  requireValue(file && path.isAbsolute(file), 'missing-session');
  let descriptor=file, session=JSON.parse(protectedRead(file));
  const bridge=session.piBridge;
  if(bridge !== undefined) {
    requireValue(!fromEnvironment && typeof bridge?.bootstrap === 'string' && typeof bridge.attemptID === 'string' &&
      typeof session.browserDescriptor === 'string' && path.isAbsolute(session.browserDescriptor),'descriptor');
    // Reject copied/inherited descriptors before reading browser resources.
    ({control}=await import('./pi-control.mjs'));
    requireValue((await control(bridge.bootstrap,'mcpAttach',bridge.attemptID)).ok === true,'admission');
    descriptor=session.browserDescriptor; session=JSON.parse(protectedRead(descriptor));
  }
  validateEndpoint(session.endpoint, session.pane);
  secret = protectedRead(session.endpoint.tokenFile).trim();
  requireValue(/^[A-Za-z0-9+/]{43}=$/.test(secret), 'invalid-token');
  privateDirectory(session.outputFolder);
  // Written now, not when Playwright starts: pane cleanup refuses while this PID's file exists.
  configFile=path.join(path.dirname(descriptor),'.mcp-'+process.pid+'.json');
  atomicWrite(configFile,JSON.stringify({browser:{cdpEndpoint:session.endpoint.url,cdpHeaders:{Authorization:'Bearer '+secret},cdpTimeout:30000}, outputDir:session.outputFolder,outputMaxSize:session.outputMaxSize,network:{allowedOrigins:session.allowedOrigins,blockedOrigins:session.blockedOrigins},timeouts:{idle:600000},webmcp:false}));
  const require=createRequire(import.meta.url);
  const packageFile=require.resolve('@playwright/mcp/package.json');
  requireValue(JSON.parse(fs.readFileSync(packageFile,'utf8')).version === '0.0.83','mcp-version-mismatch');
  const snapshot=JSON.parse(fs.readFileSync(new URL('./playwright-mcp-snapshot.json',import.meta.url),'utf8'));
  requireValue(snapshot.version === '0.0.83','mcp-version-mismatch');
  const cli=path.join(path.dirname(packageFile),'cli.js');
  // Requests that wait for a starting server, in arrival order; `ready` once
  // Playwright has answered initialize and the queue is flushed.
  const queue=[]; let ready=false, initialize, readySent=bridge === undefined;
  // Retry policy: a failed or dead server is not restarted on its own. Every
  // request waiting for it gets an error, and the next tools/call starts one
  // new attempt, so starts follow the client's calls and never loop.
  function start() {
    const proc=child=spawn(process.execPath,[cli,'--config',configFile],{cwd:session.outputFolder,stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH,HOME:process.env.HOME}});
    const inflight=new Map();
    let lost=false, handshake;
    const initialized=new Promise((resolve,reject)=>{handshake={resolve,reject};});
    const timer=setTimeout(()=>handshake.reject(),30000);
    proc.forward=message=>{
      if(message.method !== undefined && message.id !== undefined) inflight.set(JSON.stringify(message.id),message.id);
      return send(proc.stdin,JSON.stringify(message)).catch(()=>{});
    };
    const lose=()=>{
      if(lost)return; lost=true; clearTimeout(timer); handshake.reject();
      if(child === proc) {
        child=undefined;ready=false;
        for(const message of queue.splice(0)) if(message.id !== undefined) void unavailable(message.id);
      }
      proc.kill('SIGKILL');
      for(const id of inflight.values()) void unavailable(id);
      inflight.clear();
    };
    proc.stdin.on('error',()=>{}); proc.stderr.resume();
    proc.once('error',lose);
    proc.once('close',(code,signal)=>{lose();if(closing)finish(code === 0 && !signal ? 0 : 1);});
    (async()=>{
      // Do not forward raw diagnostic stderr (which may contain headers). MCP is
      // newline-delimited JSON; redact the secret from complete protocol lines too.
      for await(const line of lines(proc.stdout,8*1024*1024)) {
        const message=JSON.parse(line);
        if(message.method === undefined) {
          if(message.id === INITIALIZE) {message.result?.protocolVersion ? handshake.resolve() : handshake.reject();continue;}
          inflight.delete(JSON.stringify(message.id));
        }
        await send(process.stdout,line.replaceAll(secret,'[redacted]'));
      }
    })().catch(lose);
    void proc.forward({jsonrpc:'2.0',id:INITIALIZE,method:'initialize',params:initialize});
    initialized.then(async()=>{
      clearTimeout(timer);
      await proc.forward({jsonrpc:'2.0',method:'notifications/initialized'});
      while(queue.length && child === proc) await proc.forward(queue.shift());
      if(child === proc) ready=true;
    },lose);
  }
  const filename=message=>{
    const name=message.params.arguments.filename;
    const output=path.resolve(session.outputFolder,name);
    let safe=output.startsWith(session.outputFolder+path.sep) && !fs.lstatSync(output,{throwIfNoEntry:false})?.isSymbolicLink();
    let ancestor=path.dirname(output);
    while(ancestor.startsWith(session.outputFolder+path.sep)) {
      if(fs.lstatSync(ancestor,{throwIfNoEntry:false})?.isSymbolicLink()) safe=false;
      ancestor=path.dirname(ancestor);
    }
    if(safe) message.params.arguments.filename=output;
    return safe;
  };
  const parent=process.ppid;
  const monitor=setInterval(()=>{if(process.ppid !== parent) {closing=true;child ? child.kill('SIGTERM') : finish(0);}},1000);
  monitor.unref();
  for(const sig of ['SIGTERM','SIGINT']) process.on(sig,()=>{closing=true;child ? child.kill(sig) : finish(0);});
  try {
    for await(const line of lines(process.stdin,1024*1024)) {
      let message;
      try {message=JSON.parse(line);requireValue(message && typeof message === 'object' && !Array.isArray(message),'invalid');}
      catch {process.stderr.write('3rdr MCP rejected an invalid protocol input.\n');continue;}
      const {id,method}=message, request=method !== undefined && id !== undefined;
      if(method === undefined) {child?.forward(message);continue;}
      if(method === 'initialize') {
        initialize=message.params;
        const version=snapshot.protocolVersions.includes(message.params?.protocolVersion) ? message.params.protocolVersion : snapshot.protocolVersions[0];
        await respond(id,{result:{protocolVersion:version,...snapshot.initialize}});
      } else if(method === 'tools/list') {
        if(!readySent && initialize) {
          requireValue((await control(bridge.bootstrap,'mcpReady',bridge.attemptID)).ok === true,'ownership');
          readySent=true;
        }
        await respond(id,{result:{tools:snapshot.tools}});
      } else if(method === 'ping') await respond(id,{result:{}});
      else if(method === 'notifications/initialized') continue;
      else if(request && method !== 'tools/call') await respond(id,{error:{code:-32601,message:'Method not found'}});
      else if(method === 'tools/call' && typeof message.params?.arguments?.filename === 'string' && !filename(message))
        await respond(id,{result:{isError:true,content:[{type:'text',text:'Output filename must stay inside this pane output folder.'}]}});
      else if(request && !initialize) await unavailable(id);
      else if(ready) await child.forward(message);
      else if(request || child) {queue.push(message);if(!child) start();}
    }
    closing=true;
    if(child) child.stdin.end(); else finish(0);
  } catch {
    if(!finished) {
      closing=true; child?.kill('SIGTERM');
      process.stderr.write('3rdr MCP connection is unavailable.\n'); finish(1);
    }
  }
} catch {
  if(configFile) try{fs.unlinkSync(configFile);}catch{}
  process.stderr.write('3rdr MCP configuration is unavailable or unsafe.\n');
  process.exitCode=1;
}
