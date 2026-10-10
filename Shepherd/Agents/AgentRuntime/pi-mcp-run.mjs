import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {privateJSON, control} from './pi-control.mjs';

// A process-bound outer wrapper. The existing browser wrapper remains the only
// process that reads CDP bearer bytes; Pi never receives them in a tool result.
let child;
async function* lines(stream, limit) {
  let pending=Buffer.alloc(0);
  for await(const chunk of stream) {
    pending=Buffer.concat([pending,chunk]);
    if(pending.length>limit)throw new Error('limit');
    let newline;
    while((newline=pending.indexOf(10))>=0) {
      yield pending.subarray(0,newline).toString('utf8'); pending=pending.subarray(newline+1);
    }
  }
  if(pending.length)throw new Error('incomplete');
}
async function send(stream, line) { if(!stream.write(line+'\n'))await once(stream,'drain'); }
try {
  const file=process.argv[2];
  if(!file || !path.isAbsolute(file))throw new Error('descriptor');
  const descriptor=privateJSON(file), bridge=descriptor.piBridge;
  if(!bridge || typeof bridge.bootstrap!=='string' || typeof bridge.attemptID!=='string' ||
     typeof descriptor.browserDescriptor!=='string' || !path.isAbsolute(descriptor.browserDescriptor))throw new Error('descriptor');
  // Reject copied/inherited descriptors before spawning browser resources.
  const admitted=await control(bridge.bootstrap,'mcpAttach',bridge.attemptID);
  if(admitted.ok!==true)throw new Error('admission');
  const runner=fileURLToPath(new URL('./mcp-run.mjs',import.meta.url));
  child=spawn(process.execPath,[runner,descriptor.browserDescriptor],{
    stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH ?? '/usr/bin:/bin',HOME:process.env.HOME ?? '/'}
  });
  child.stderr.resume();
  const exited=new Promise(resolve=>{
    child.once('error',()=>{process.stdin.destroy();resolve(1);});
    child.once('exit',(code,signal)=>{process.stdin.destroy();resolve(signal ? 1 : (code ?? 1));});
  });
  for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>{child.stdin.end();child.kill(signal);process.stdin.destroy();});
  let initialized=false, ready=false;
  const requests=new Map();
  const input=(async()=>{
    try {
      for await(const line of lines(process.stdin,1024*1024)) {
        const message=JSON.parse(line);
        if(message.method==='initialize' || message.method==='tools/list') {
          if(requests.size>=16)throw new Error('request-limit');
          requests.set(message.id,message.method);
        }
        await send(child.stdin,line);
      }
    } finally { child.stdin.end(); }
  })();
  const output=(async()=>{
    for await(const line of lines(child.stdout,8*1024*1024)) {
      const message=JSON.parse(line), method=requests.get(message.id);
      if(method)requests.delete(message.id);
      if(method==='initialize' && message.result?.protocolVersion && !message.error)initialized=true;
      if(!ready && initialized && method==='tools/list' && Array.isArray(message.result?.tools) &&
          ['browser_snapshot','browser_navigate'].every(name=>message.result.tools.some(tool=>tool.name===name))) {
        const proof=await control(bridge.bootstrap,'mcpReady',bridge.attemptID);
        if(proof.ok!==true)throw new Error('ownership');
        ready=true;
      }
      await send(process.stdout,line);
    }
  })();
  try { await Promise.all([input,output]); }
  catch { child.stdin.end();child.kill('SIGTERM');process.stdin.destroy();throw new Error('protocol'); }
  process.exitCode=await exited;
} catch {
  if(child){child.stdin.end();child.kill('SIGTERM');}
  process.stderr.write('Shepherd Pi MCP connection is unavailable.\n');
  process.exitCode=1;
}
