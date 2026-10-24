// Actual Node fetch through the native proxy to its synthetic loopback TLS
// upstream. Run only inside run-forwarder-tests.py's network sandbox.
import assert from 'node:assert/strict';
import {openAIProxyFetch} from '../../Shepherd/Agents/AgentRuntime/pi-api-proxy.mjs';
const base=process.argv[2];
assert(/^http:\/\/127\.0\.0\.1:\d+\/p\/[0-9a-f]{32}$/.test(base));
const transport=openAIProxyFetch(base,globalThis.fetch,{'x-3rdr-pi-contract':'2','x-3rdr-pi-class':'main','x-3rdr-pi-session':'synthetic-native'});
const response=await transport('https://api.openai.com/v1/responses',{method:'POST',headers:{authorization:'Bearer synthetic-direct-subscription','content-type':'application/json'},body:'{"input":"synthetic-native-fetch"}',signal:AbortSignal.timeout(5000)});
assert.equal(response.status,200);
assert.deepEqual(await response.json(),{fixture:true});
console.log('PASS actual Node fetch through native proxy; no provider network request');
