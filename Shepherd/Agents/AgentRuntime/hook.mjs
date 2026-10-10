import fs from 'node:fs';
import path from 'node:path';
import {rewrite} from './runtime.mjs';
import {atomicWrite,readJSON} from './runtime-core.mjs';

// Claude PreToolUse only. Never execute or eval a proposed shell command.
let input='';
try {
  for await(const chunk of process.stdin) {input+=chunk;if(input.length > 1024*1024) throw new Error('size');}
  const event=JSON.parse(input);const root=process.argv[2];
  if(event.tool_name !== 'Bash' || typeof event.tool_input?.command !== 'string') process.exit(0);
  const result=rewrite(event.tool_input.command,root);
  // Record bounded reason codes, not shell strings, argv, credentials or tokens.
  try {
    const log=path.join(root,'hook-events.json');const records=readJSON(log,[]);
    records.push({time:new Date().toISOString(),reason:result.reason});atomicWrite(log,JSON.stringify(records.slice(-128)));
  } catch {}
  if(result.rewritten) process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:'PreToolUse',updatedInput:{...event.tool_input,command:result.command}}})+'\n');
} catch {process.stderr.write('Shepherd child command left unchanged.\n');}
