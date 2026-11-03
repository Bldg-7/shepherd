// Inert canaries and an owned loopback listener only; never actual secrets.
const fs = require('node:fs');
const net = require('node:net');
const [inside, outside, port] = process.argv.slice(2);
function denied(operation) {
  try { operation(); return false; }
  catch (error) { return ['EPERM', 'EACCES'].includes(error.code); }
}
const result = {
  privateRead: fs.readFileSync(inside, 'utf8') === 'nonsecret-canary',
  outsideReadDenied: denied(() => fs.readFileSync(outside)),
  outsideWriteDenied: denied(() => fs.writeFileSync(outside, 'changed')),
  cleanEnvironment: !Object.keys(process.env).some(key => /TOKEN|SECRET|PASSWORD|API_KEY|SHEPHERD|HERDR|PI_SESSION|^PI_PROVIDER$|^PI_MODEL$/.test(key)),
};
let done = false;
function finish() {
  if (done) return;
  done = true;
  console.log(JSON.stringify(result));
  process.exit(Object.values(result).every(Boolean) ? 0 : 1);
}
const socket = net.connect({host: '127.0.0.1', port: Number(port)});
socket.on('connect', () => { result.networkDenied = false; socket.destroy(); finish(); });
socket.on('error', error => { result.networkDenied = ['EPERM', 'EACCES'].includes(error.code); finish(); });
socket.setTimeout(2000, () => { socket.destroy(); result.networkDenied = false; finish(); });
