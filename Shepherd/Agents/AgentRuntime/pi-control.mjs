import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {PiIntegrationError} from './pi-runtime.mjs';

const reject = () => { throw new PiIntegrationError('pi-control-unavailable'); };
export function privateJSON(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.size > 32768) reject();
    const buffer = Buffer.alloc(32769), count = fs.readSync(fd, buffer, 0, buffer.length, 0);
    if (count > 32768) reject();
    return JSON.parse(buffer.subarray(0, count).toString('utf8'));
  } finally { fs.closeSync(fd); }
}
export function readBootstrap(file) {
  try {
    if (!path.isAbsolute(file)) reject();
    const data = privateJSON(file);
    if (data.version !== 1 || typeof data.launchID !== 'string' || typeof data.capability !== 'string' ||
        !/^[A-Za-z0-9+/]{43}=$/.test(data.capability) || !path.isAbsolute(data.socketPath) ||
        fs.realpathSync(data.node) !== fs.realpathSync(process.execPath) ||
        fs.realpathSync(data.helper) !== fs.realpathSync(fileURLToPath(import.meta.url))) reject();
    const socket = fs.lstatSync(data.socketPath), parent = fs.lstatSync(path.dirname(data.socketPath));
    if (!socket.isSocket() || socket.uid !== process.getuid() || (socket.mode & 0o077) ||
        !parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid() || (parent.mode & 0o077)) reject();
    return data;
  } catch { reject(); }
}
export function control(bootstrapFile, command, attemptID, identity, { signal, timeoutMs = 3000, state } = {}) {
  const bootstrap = readBootstrap(bootstrapFile);
  const request = JSON.stringify({ version:1, launchID:bootstrap.launchID, capability:bootstrap.capability, command, attemptID, ...(identity ? {identity} : {}), ...(state ? {state} : {}) }) + '\n';
  if (Buffer.byteLength(request) > 32769) reject();
  return new Promise((resolve, rejectPromise) => {
    const socket = net.createConnection({path:bootstrap.socketPath});
    let chunks=[], size=0, settled=false;
    const finish = (error, result) => {
      if (settled) return; settled=true;
      clearTimeout(timer); signal?.removeEventListener('abort', abort); socket.destroy();
      if (error) rejectPromise(new PiIntegrationError('pi-control-unavailable')); else resolve(result);
    };
    const abort = () => finish(true);
    const timer = setTimeout(abort, timeoutMs);
    socket.once('connect', () => socket.write(request));
    socket.on('data', chunk => {
      size += chunk.length;
      if (size > 32769) return finish(true);
      chunks.push(chunk);
      const bytes = Buffer.concat(chunks), newline = bytes.indexOf(10);
      if (newline < 0) return;
      if (newline !== bytes.length-1) return finish(true);
      try {
        const value=JSON.parse(bytes.subarray(0,newline).toString('utf8'));
        if (typeof value.ok !== 'boolean') return finish(true);
        finish(false,value);
      } catch { finish(true); }
    });
    socket.once('error',abort); socket.once('end',()=>{if(!settled)finish(true);});
    signal?.addEventListener('abort',abort,{once:true}); if(signal?.aborted)abort();
  });
}

// Only the native-authenticated direct child helper may synchronously revoke.
// Capability bytes arrive from the protected bootstrap, never argv/environment.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    let input=''; for await (const chunk of process.stdin) { input+=chunk; if(Buffer.byteLength(input)>4096)reject(); }
    const request=JSON.parse(input);
    if(request.command !== 'revoke' || typeof request.attemptID !== 'string')reject();
    const result=await control(process.argv[2], 'revoke', request.attemptID);
    process.stdout.write(JSON.stringify({ok:result.ok===true})+'\n');
    if(result.ok!==true)process.exitCode=1;
  } catch { process.stdout.write('{"ok":false}\n'); process.exitCode=1; }
}
