import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import {protectedRead} from './protected-read.mjs';

const codes = new Set(['denied','unavailable','expired','invalidElement','invalidRequest','unsupported','capacity','consumed','cancelled']);
const states = new Set(['approved','bound','authorized','consumed','revoked','expired','failed']);
const opaque = s => typeof s === 'string' && /^[a-f0-9]{64}$/.test(s);
const exact = (o, keys) => o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).sort().join(',') === keys.sort().join(',');
function check(ok) { if (!ok) throw new Error('denied'); }
function validate(command, input) {
  if (command === 'list-approved-handles') { check(exact(input, [])); return; }
  if (command === 'status' || command === 'unbind') { check(exact(input,['handle']) && opaque(input.handle)); return; }
  check(command === 'bind' && exact(input,['handle','pageID','frameID','backendNodeID','requestField','destination']));
  check(opaque(input.handle) && Number.isSafeInteger(input.backendNodeID) && input.backendNodeID > 0);
  for (const key of ['pageID','frameID','requestField','destination']) check(typeof input[key] === 'string' && input[key].length > 0 && Buffer.byteLength(input[key]) <= 2048 && !/[\x00-\x1f]/.test(input[key]));
}
function publicResponse(command, value) {
  if (exact(value,['error']) && codes.has(value.error)) return value;
  if (command === 'list-approved-handles') {
    check(exact(value,['handles']) && Array.isArray(value.handles) && value.handles.length <= 128 && value.handles.every(opaque));
  } else check(exact(value,['state']) && states.has(value.state));
  return value;
}
function roundtrip(url, token, lease, message) {
  return new Promise((resolve,reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    let socket, bytes = Buffer.alloc(0), settled = false;
    const finish = (error, value) => { if(settled) return; settled=true; clearTimeout(timer); request.destroy(); socket?.destroy(); error ? reject(error) : resolve(value); };
    const request = http.request({hostname:'127.0.0.1',port:url.port,path:url.pathname,method:'GET',headers:{Connection:'Upgrade',Upgrade:'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':key,Authorization:'Bearer '+token,'X-Shepherd-Credential-Lease':lease}});
    const timer = setTimeout(()=>finish(new Error('unavailable')),10000);
    request.on('error',()=>finish(new Error('unavailable')));
    request.on('response',()=>finish(new Error('denied')));
    request.on('upgrade',(response,s,head)=> {
      socket=s;
      const expected=crypto.createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      if(response.statusCode !== 101 || response.headers['sec-websocket-accept'] !== expected || response.headers.upgrade?.toLowerCase() !== 'websocket') return finish(new Error('denied'));
      function received(chunk) {
        bytes=Buffer.concat([bytes,chunk]);
        if(bytes.length > 32778) return finish(new Error('denied'));
        if(bytes.length < 2) return;
        if(bytes[0] !== 0x81 || (bytes[1]&0x80) !== 0 || (bytes[1]&127) === 127) return finish(new Error('denied'));
        let length=bytes[1]&127, offset=2;
        if(length === 126) { if(bytes.length < 4) return; length=bytes.readUInt16BE(2); offset=4; }
        if(length > 32768) return finish(new Error('denied'));
        if(bytes.length < offset+length) return;
        if(bytes.length !== offset+length) return finish(new Error('denied'));
        try { finish(null,JSON.parse(bytes.subarray(offset).toString('utf8'))); } catch { finish(new Error('denied')); }
      }
      s.on('data',received); s.on('error',()=>finish(new Error('unavailable'))); s.on('end',()=>finish(new Error('unavailable')));
      const body=Buffer.from(JSON.stringify(message)); const mask=crypto.randomBytes(4);
      const header=Buffer.alloc(body.length < 126 ? 2 : 4); header[0]=0x81;
      header[1]=0x80|(body.length < 126 ? body.length : 126); if(header.length === 4) header.writeUInt16BE(body.length,2);
      for(let i=0;i<body.length;i++) body[i]^=mask[i%4];
      s.write(Buffer.concat([header,mask,body])); if(head.length) received(head);
    });
    request.end();
  });
}
try {
  check(Number(process.versions.node.split('.')[0]) >= 20);
  const [command, argument, ...rest]=process.argv.slice(2); check(rest.length === 0);
  const descriptor=argument === '--environment' ? process.env.SHEPHERD_AGENT_SESSION : argument;
  check(typeof descriptor === 'string' && path.isAbsolute(descriptor));
  const session=JSON.parse(protectedRead(descriptor));
  const e=session.endpoint, p=session.pane; check(e?.origin === 'thisMac' && p?.herdrMachineID == null);
  const url=new URL(e.url); const parts=url.pathname.split('/');
  check(url.protocol === 'ws:' && url.hostname === '127.0.0.1' && +url.port > 0 && !url.username && !url.password && !url.search && !url.hash);
  check(parts.length === 6 && parts[1] === 'v1' && parts[2] === 'herdr' && parts[4] === 'pane' && decodeURIComponent(parts[3]) === p.session && decodeURIComponent(parts[5]) === p.paneID);
  check(path.isAbsolute(e.tokenFile) && path.isAbsolute(session.credentialLeaseFile));
  const token=protectedRead(e.tokenFile).trim(), lease=protectedRead(session.credentialLeaseFile).trim();
  check(/^[A-Za-z0-9+/]{43}=$/.test(token) && opaque(lease));
  let input=Buffer.alloc(0);
  for await (const chunk of process.stdin) { input=Buffer.concat([input,chunk]); check(input.length <= 16384); }
  const dto=JSON.parse(input.toString('utf8')); validate(command,dto);
  url.pathname += '/credential';
  const result=publicResponse(command,await roundtrip(url,token,lease,{command,...dto}));
  process.stdout.write(JSON.stringify(result)+'\n'); if(result.error) process.exitCode=1;
} catch {
  process.stdout.write('{"error":"denied"}\n'); process.exitCode=1;
}
