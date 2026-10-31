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
const INITIALIZE='3rdr-initialize', UNAVAILABLE='3rdr browser is unavailable.', LIMIT=8*1024*1024, KEEP=4096;
const STOPPED='The 3rdr browser server stopped before this call finished. The next browser call starts it again; retry the call if it is still needed.';
const TOO_LARGE=(size,shared)=>`${shared ? 'A browser result, from this call or another one running at the same time,' : 'This browser tool\'s result'} was about ${Math.max(1,Math.round(size/1048576))} MB, too large to return. The browser keeps its current page and state. Retry with \`filename\` to save the result to the pane output folder, or narrow it (screenshots: \`target\`, \`fullPage: false\`, \`scale\`; snapshots: \`depth\` or \`target\`).`;
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
// Lines up to `limit` bytes; a longer one is discarded as it streams, keeping
// only its first and last KEEP bytes and its size ({head, tail, size}).
async function* frames(stream, limit) {
  let parts=[], length=0, over;
  for await(let chunk of stream) {
    while(chunk.length) {
      const newline=chunk.indexOf(10), part=newline < 0 ? chunk : chunk.subarray(0,newline);
      chunk=newline < 0 ? chunk.subarray(chunk.length) : chunk.subarray(newline+1);
      if(over) {over.size+=part.length;over.tail=Buffer.concat([over.tail,part]).subarray(-KEEP);}
      else if(length+part.length > limit) {
        const all=[...parts,part];
        over={head:Buffer.concat(all,Math.min(KEEP,length+part.length)),tail:Buffer.concat(all.slice(-2)).subarray(-KEEP),size:length+part.length};parts=[];length=0;
      } else {parts.push(part);length+=part.length;}
      if(newline < 0) continue;
      if(over) {yield over;over=undefined;}
      else {yield Buffer.concat(parts).toString('utf8');parts=[];length=0;}
    }
  }
  if(length || over)throw new Error('incomplete');
}
async function send(stream, line) {
  if(stream.write(line+'\n') || stream.destroyed)return;
  const abort=new AbortController();
  try { await Promise.race([once(stream,'drain',{signal:abort.signal}),once(stream,'close',{signal:abort.signal})]); } finally { abort.abort(); }
}
const respond=(id,body)=>send(process.stdout,JSON.stringify({jsonrpc:'2.0',id,...body}));
const unavailable=id=>respond(id,{error:{code:-32603,message:UNAVAILABLE}});
const toolError=(id,text)=>respond(id,{result:{content:[{type:'text',text}],isError:true}});
// The pinned MCP SDK writes a result as {"result":…,"jsonrpc":"2.0","id":…}
// and an error as {"jsonrpc":"2.0","id":…,…}: the id ends or starts the line.
const ID='("(?:[^"\\\\]|\\\\.)*"|-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)';
const TAIL=new RegExp(',"jsonrpc":"2\\.0","id":'+ID+'\\}\\s*$'), HEAD=new RegExp('^\\{"jsonrpc":"2\\.0","id":'+ID+'[,}]');
function recoveredID({head,tail}) {
  const match=TAIL.exec(tail.toString('latin1')) ?? HEAD.exec(head.toString('latin1'));
  try { return match ? JSON.stringify(JSON.parse(match[1])) : undefined; } catch { return undefined; }
}
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
  // call waiting for it gets a tool error saying so, and the next tools/call starts one
  // new attempt, so starts follow the client's calls and never loop.
  function start() {
    const proc=child=spawn(process.execPath,[cli,'--config',configFile],{cwd:session.outputFolder,stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH,HOME:process.env.HOME}});
    const inflight=new Map();
    let lost=false, handshake;
    const initialized=new Promise((resolve,reject)=>{handshake={resolve,reject};});
    const timer=setTimeout(()=>handshake.reject(),30000);
    proc.forward=message=>{
      if(message.method !== undefined && message.id !== undefined && message.id !== INITIALIZE) inflight.set(JSON.stringify(message.id),message.id);
      return send(proc.stdin,JSON.stringify(message)).catch(()=>{});
    };
    const lose=()=>{
      if(lost)return; lost=true; clearTimeout(timer); handshake.reject();
      if(child === proc) {
        child=undefined;ready=false;
          for(const message of queue.splice(0)) if(message.id !== undefined) void toolError(message.id,STOPPED);
      }
      proc.kill('SIGKILL');
      for(const id of inflight.values()) void toolError(id,STOPPED);
      inflight.clear();
    };
    proc.stdin.on('error',()=>{}); proc.stderr.resume();
    proc.once('error',lose);
    proc.once('close',(code,signal)=>{lose();if(closing)finish(code === 0 && !signal ? 0 : 1);});
    (async()=>{
      // Do not forward raw diagnostic stderr (which may contain headers). MCP is
      // newline-delimited JSON; redact the secret from complete protocol lines too.
      // A line over LIMIT (a memory guard) is answered as a tool error for
      // its call, found by its id, else the only call waiting; when that is
      // ambiguous every waiting call gets it. The server keeps running, and
      // later replies to calls already answered here are dropped.
      for await(const frame of frames(proc.stdout,LIMIT)) {
        if(typeof frame !== 'string') {
          if(/^\s*\{"method":/.test(frame.head.toString('latin1'))) continue;
          const key=recoveredID(frame);
          const ids=inflight.has(key) ? [key] : [...inflight.keys()];
          for(const id of ids) {void toolError(inflight.get(id),TOO_LARGE(frame.size,ids.length > 1));inflight.delete(id);}
          continue;
        }
        const message=JSON.parse(frame);
        if(message.method === undefined) {
          if(message.id === INITIALIZE) {message.result?.protocolVersion ? handshake.resolve() : handshake.reject();continue;}
          if(!inflight.delete(JSON.stringify(message.id))) continue;
        }
        await send(process.stdout,frame.replaceAll(secret,'[redacted]'));
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
