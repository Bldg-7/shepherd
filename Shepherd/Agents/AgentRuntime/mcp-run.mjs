import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
import {createRequire} from 'node:module';
import {protectedRead, privateDirectory, atomicWrite, validateEndpoint, requireValue, requireNode} from './runtime-core.mjs';

// Secrets exist only in this process and the protected MCP config, never argv
// or environment. Pinned MCP's supported --config reads browser.cdpHeaders.
let child, configFile, secret;
try {
  requireNode();
  let descriptor = process.argv[2];
  if(descriptor === '--environment') descriptor = process.env.SHEPHERD_AGENT_SESSION;
  requireValue(descriptor !== '--global', 'session-only-policy');
  requireValue(descriptor && path.isAbsolute(descriptor), 'missing-session');
  const session = JSON.parse(protectedRead(descriptor));
  validateEndpoint(session.endpoint, session.pane);
  secret = protectedRead(session.endpoint.tokenFile).trim();
  requireValue(/^[A-Za-z0-9+/]{43}=$/.test(secret), 'invalid-token');
  privateDirectory(session.outputFolder);
  configFile=path.join(path.dirname(descriptor),'.mcp-'+process.pid+'.json');
  atomicWrite(configFile,JSON.stringify({browser:{cdpEndpoint:session.endpoint.url,cdpHeaders:{Authorization:'Bearer '+secret},cdpTimeout:30000}, outputDir:session.outputFolder,outputMaxSize:session.outputMaxSize,network:{allowedOrigins:session.allowedOrigins,blockedOrigins:session.blockedOrigins},timeouts:{idle:600000},webmcp:false}));
  const require=createRequire(import.meta.url);
  const packageFile=require.resolve('@playwright/mcp/package.json');
  requireValue(JSON.parse(fs.readFileSync(packageFile,'utf8')).version === '0.0.83','mcp-version-mismatch');
  child=spawn(process.execPath,[path.join(path.dirname(packageFile),'cli.js'),'--config',configFile],{cwd:session.outputFolder,stdio:['pipe','pipe','pipe'],env:{PATH:process.env.PATH,HOME:process.env.HOME}});
  const input=readline.createInterface({input:process.stdin});
  input.on('line',line=>{
    try {
      const message=JSON.parse(line);
      if(message.method === 'tools/call' && typeof message.params?.arguments?.filename === 'string') {
        const name=message.params.arguments.filename;
        const output=path.resolve(session.outputFolder,name);
        let safe=output.startsWith(session.outputFolder+path.sep) && !fs.lstatSync(output,{throwIfNoEntry:false})?.isSymbolicLink();
        let ancestor=path.dirname(output);
        while(ancestor.startsWith(session.outputFolder+path.sep)) {
          if(fs.lstatSync(ancestor,{throwIfNoEntry:false})?.isSymbolicLink()) safe=false;
          ancestor=path.dirname(ancestor);
        }
        if(!safe) {
          process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:message.id,result:{isError:true,content:[{type:'text',text:'Output filename must stay inside this pane output folder.'}]}})+'\n');return;
        }
        message.params.arguments.filename=output;
      }
      child.stdin.write(JSON.stringify(message)+'\n');
    } catch {
      process.stderr.write('Shepherd MCP rejected an invalid protocol input.\n');
    }
  });
  input.on('close',()=>child.stdin.end());
  // Do not forward raw diagnostic stderr (which may contain headers). MCP is
  // newline-delimited JSON; redact the secret from complete protocol lines too.
  const lines=readline.createInterface({input:child.stdout});
  lines.on('line',line=>process.stdout.write(line.replaceAll(secret,'[redacted]')+'\n'));
  child.stderr.resume();
  const parent=process.ppid;
  const monitor=setInterval(()=>{if(process.ppid !== parent) child.kill('SIGTERM');},1000);
  const cleanup=()=>{clearInterval(monitor);try{fs.unlinkSync(configFile);}catch{}};
  child.on('error',()=>{cleanup();process.stderr.write('Shepherd MCP could not start.\n');process.exitCode=1;process.stdin.destroy();});
  child.on('exit',(code,signal)=>{cleanup();process.exitCode=signal ? 1 : code;process.stdin.destroy();});
  for(const sig of ['SIGTERM','SIGINT']) process.on(sig,()=>child.kill(sig));
} catch {
  if(configFile) try{fs.unlinkSync(configFile);}catch{}
  process.stderr.write('Shepherd MCP configuration is unavailable or unsafe.\n');
  process.exitCode=1;
}
