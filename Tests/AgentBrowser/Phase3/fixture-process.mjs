// Disposable fixture processes have a finite lifetime even when an awaited
// readiness/exit event never arrives. The stage launcher independently tracks
// and identity-checks all descendants (including MCP and CEF helper groups).
import {spawn as spawnProcess, execFileSync as execute} from 'node:child_process';
import {once as eventOnce} from 'node:events';

export function spawn(command, args, options) {
    return spawnProcess(command, args, {timeout:120000, killSignal:'SIGKILL', ...options});
}
export function execFileSync(command, args, options) {
    return execute(command, args, {timeout:10000, killSignal:'SIGKILL', ...options});
}
export function once(emitter, event, options = {}) {
    if (event === 'exit' && (emitter.exitCode !== null || emitter.signalCode !== null)) {
        return Promise.resolve([emitter.exitCode, emitter.signalCode]);
    }
    if (event === 'close' && emitter.readyState === 3) return Promise.resolve([]);
    return eventOnce(emitter, event, {signal:AbortSignal.timeout(15000), ...options});
}
