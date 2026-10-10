// Session-local executable shim entry. Pi's real CLI is not imported until the
// app has pinned the foreground process's full original argv and kernel lifetime.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {performance} from 'node:perf_hooks';
import {protectedRead} from './protected-read.mjs';
import {control} from './pi-control.mjs';
import {resolvePiExecutable} from './pi-runtime.mjs';

let phase='tty';
try {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error();
  phase='manifest';
  const file=process.argv[2];
  if(!path.isAbsolute(file ?? '')) throw new Error();
  const config=JSON.parse(protectedRead(file));
  if(config.version!==1 || !Array.isArray(config.arguments) ||
     config.arguments.some(v=>typeof v!=='string' || v.includes('\0')) ||
     !path.isAbsolute(config.cli ?? '') || !path.isAbsolute(config.bootstrap ?? '')) throw new Error();
  phase='arguments';
  if(JSON.stringify(process.argv.slice(3))!==JSON.stringify(config.arguments))throw new Error();
  phase='cwd';
  if(fs.realpathSync(process.cwd())!==fs.realpathSync(config.cwd))throw new Error();
  phase='binding';
  const deadline=performance.now()+15000;
  let bound=false;
  do {
    const reply=await control(config.bootstrap,'boot','00000000-0000-4000-8000-000000000001');
    if(reply.ok===true){bound=true;break;}
    if(reply.error!=='notBound')throw new Error();
    await new Promise(resolve=>setTimeout(resolve,50));
  } while(performance.now()<deadline);
  if(!bound)throw new Error();
  // Preserve normal Pi settings, instructions, extensions and auth resolution.
  // Only this process and its owned session resource know the bootstrap path.
  process.env.SHEPHERD_PI_BRIDGE=config.bootstrap;
  process.argv=[process.execPath,config.cli,...config.arguments];
  phase='package';
  const cli=resolvePiExecutable(config.cli);
  phase='import';
  await import(pathToFileURL(cli).href);
} catch {
  process.stderr.write(`Shepherd: pi-startup-${phase}-failed\n`);
  process.exitCode=1;
}
