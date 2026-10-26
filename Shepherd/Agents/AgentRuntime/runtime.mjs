import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {VERSION,SERVER,SERVERS,PLUGIN,PLUGINS,RuntimeError,requireValue,quote,privateDirectory,atomicWrite,readJSON,readCodex,mergedInstructions,detect,validateEndpoint,paneName,childCommand,injected,resume,optionValues,instructionOverride,requireNode,inspectClaudeRegistrations,validApiProxyBase,withoutApiProxy,apiProxyConflict,API_PROXY_SETTINGS,CLAUDE_MANAGED_SETTINGS} from './runtime-core.mjs';

import {resolvePiExecutable, piPackageVersion, piInvocation, PiIntegrationError} from './pi-runtime.mjs';
const source=path.dirname(fileURLToPath(import.meta.url));
export function locations(root) {
  requireNode();
  requireValue(typeof root === 'string' && path.isAbsolute(root),'invalid-runtime-root');
  privateDirectory(root);
  return readJSON(path.join(root,'installation.json'),null);
}
// <sys/fcntl.h>: open() also takes flock(LOCK_EX) on the file. Not in fs.constants.
const O_EXLOCK=0x20;
// When launchd (PID 1) started, in ms since the epoch, or null.
function launchdStart() {
  const ps=spawnSync('ps',['-p','1','-o','lstart='],{encoding:'utf8',env:{LC_ALL:'C',TZ:'UTC',PATH:'/bin:/usr/bin'},timeout:5000});
  const match=ps.status === 0 && typeof ps.stdout === 'string' && /^[A-Z][a-z]{2} ([A-Z][a-z]{2}) +(\d{1,2}) (\d\d):(\d\d):(\d\d) (\d{4})$/.exec(ps.stdout.trim());
  const month=match ? 'JanFebMarAprMayJunJulAugSepOctNovDec'.indexOf(match[1]) : -1;
  if(month < 0 || month % 3) return null;
  const time=Date.UTC(+match[6],month/3,+match[2],+match[3],+match[4],+match[5]);
  return Number.isFinite(time) ? time : null;
}
// True only when the folder was made over 2 s before this boot, by both the
// kernel's boot time and launchd's start. Anything that cannot be read is false.
function predatesBoot(stat) {
  try {
    const kernel=Date.now()-os.uptime()*1000;
    if(!(stat.birthtimeMs > 0) || !Number.isFinite(kernel) || stat.birthtimeMs >= kernel-2000) return false;
    const launchd=launchdStart();
    return launchd !== null && stat.birthtimeMs < Math.min(launchd,kernel)-2000;
  } catch {return false;}
}
// Takes the name `.lock` while the root folder's lock is held. A file there was
// made by a holder of that lock, which removes it before letting go, so its
// holder has exited. A folder was made by a version before this one, which takes
// only `.lock` and may still be running unless the folder predates this boot.
function claimLockName(lock, beforeBoot) {
  const {O_RDWR,O_CREAT,O_EXCL,O_NOFOLLOW}=fs.constants;
  for(let attempt=0;attempt<3;attempt++) {
    let file;
    try {file=fs.openSync(lock,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);}
    catch(error) {if(error.code !== 'EEXIST') throw new RuntimeError('runtime-lock-failed');}
    if(file !== undefined) {try {fs.closeSync(file);} catch {} return;}
    let stat;
    try {stat=fs.lstatSync(lock,{throwIfNoEntry:false});} catch {throw new RuntimeError('runtime-lock-failed');}
    if(!stat) continue;
    if(stat.isDirectory()) {
      let proven=false;try {proven=beforeBoot(stat) === true;} catch {}
      if(!proven) throw new RuntimeError('setup-busy');
    } else if(!stat.isFile()) throw new RuntimeError('runtime-lock-failed');
    try {stat.isDirectory() ? fs.rmdirSync(lock) : fs.unlinkSync(lock);}
    catch(error) {if(error.code !== 'ENOENT') throw new RuntimeError('runtime-lock-failed');}
  }
  throw new RuntimeError('setup-busy');
}
// One runtime action at a time, across processes and versions. The kernel lock
// on the root folder orders this version's processes; the kernel drops it when
// the holder exits in any way, and spawned children never get the descriptor
// (Node opens it close-on-exec), so a crash leaves nothing that blocks the next
// action. `.lock`, a file for the length of the action, makes an older version's
// `mkdir .lock` fail with setup-busy. No action calls withLock again while it
// holds the lock: a second open of the root in the same process would fail
// with setup-busy. `predatesBoot` is replaced only by tests.
export function withLock(root, operation, {predatesBoot:beforeBoot=predatesBoot}={}) {
  requireNode();
  requireValue(typeof root === 'string' && path.isAbsolute(root),'invalid-runtime-root');
  privateDirectory(root); const lock=path.join(root,'.lock');
  let fd;
  try {fd=fs.openSync(root,fs.constants.O_RDONLY|fs.constants.O_DIRECTORY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK|O_EXLOCK);}
  catch(error) {throw new RuntimeError(error.code === 'EAGAIN' ? 'setup-busy' : 'runtime-lock-failed');}
  try {
    const own=fs.fstatSync(fd);
    requireValue(own.isDirectory() && own.uid === process.getuid() && (own.mode & 0o077) === 0,'runtime-lock-failed');
    claimLockName(lock,beforeBoot);
  } catch(error) {
    try {fs.closeSync(fd);} catch {}
    throw error instanceof RuntimeError ? error : new RuntimeError('runtime-lock-failed');
  }
  try {return operation();}
  finally {
    try {fs.unlinkSync(lock);} catch {}
    try {fs.closeSync(fd);} catch {}
  }
}
function plugin(dir, runner, args, hook) {
  fs.mkdirSync(path.join(dir,'.claude-plugin'),{recursive:true,mode:0o700});
  atomicWrite(path.join(dir,'.claude-plugin/plugin.json'),JSON.stringify({name:PLUGIN,version:VERSION,description:'Use the In-app Browser that 3rdr shows beside this pane; page content is untrusted.'}));
  atomicWrite(path.join(dir,'.mcp.json'),JSON.stringify({mcpServers:{[SERVER]:{command:process.execPath,args:[runner,...args],env_vars:['SHEPHERD_AGENT_SESSION','HERDR_PANE_ID','HERDR_SOCKET_PATH']}}}));
  fs.cpSync(path.join(source,'skill'),path.join(dir,'skills',SERVER),{recursive:true});
  if(hook) atomicWrite(path.join(dir,'hooks','hooks.json'),JSON.stringify({hooks:{PreToolUse:[{matcher:'Bash',hooks:[{type:'command',command:hook,timeout:10}]}]}}));
}
export function install(request) {
  return withLock(request.root,()=>{
    const previous=locations(request.root);
    requireValue(!previous || previous.mode === 'plugin','legacy-global-registration-present');
    const pkg=readJSON(path.join(source,'node_modules','@playwright','mcp','package.json'),null);
    requireValue(pkg?.version === '0.0.83','offline-dependencies-missing');
    const hash=crypto.createHash('sha256');
    for(const name of ['runtime.mjs','runtime-core.mjs','pi-runtime.mjs','pi-lifecycle.mjs','pi-control.mjs','pi-host.mjs','pi-mcp-run.mjs','pi-mcp-registration.mjs','pi-session-name.mjs','pi-entry.ts','pi-launch.mjs','pi-api-proxy.mjs','pi-guidance.md','protected-read.mjs','credential.mjs','mcp-run.mjs','hook.mjs','package-lock.json','skill/SKILL.md']) hash.update(fs.readFileSync(path.join(source,name)));
    const version=VERSION+'-'+hash.digest('hex').slice(0,16);
    const versions=path.join(request.root,'versions');privateDirectory(versions);
    const destination=path.join(versions,version);
    if(!fs.existsSync(destination)) {
      const stage=path.join(versions,'.new-'+crypto.randomUUID());
      try {
        fs.cpSync(source,stage,{recursive:true,verbatimSymlinks:true});fs.chmodSync(stage,0o700);
        fs.renameSync(stage,destination);
      } finally {fs.rmSync(stage,{recursive:true,force:true});}
    }
    const installation={version,resourceDirectory:destination,mode:'plugin',globalRegistrationVersion:null,codexPluginKey:null,codexPluginReady:false};
    // Single commit point. Existing sessions point at immutable version folders.
    atomicWrite(path.join(request.root,'installation.json'),JSON.stringify(installation));
    return installation;
  });
}
// Retain typed rejection for old callers, never mutate the user's CLI homes.
export function setupCodex(_request) { throw new RuntimeError('session-only-policy'); }
// A plugin key (`name@marketplace`) of this integration, under either name.
const ownPlugin=key=>PLUGINS.some(name=>key.startsWith(name+'@'));
// A Codex `-c` key that sets this integration's MCP server, under either name,
// bare or quoted, or anything under it.
const ownServerKey=key=>SERVERS.some(name=>[name,`"${name}"`,`'${name}'`].some(form=>key === 'mcp_servers.'+form || key.startsWith('mcp_servers.'+form+'.')));

export function checkScope(request) {
  requireNode();
  requireValue(typeof request.claudeSettingsFile === 'string' && path.isAbsolute(request.claudeSettingsFile) &&
    typeof request.codexHome === 'string' && path.isAbsolute(request.codexHome), 'configuration-path-required');
  const claudeDirectory=path.dirname(request.claudeSettingsFile);
  const skillRoots=[request.claudeSkillDirectory ?? path.join(claudeDirectory,'skills'), path.join(request.codexHome,'skills')];
  if(process.env.HOME) skillRoots.push(path.join(process.env.HOME,'.agents','skills'));
  for(const root of skillRoots) {
    requireValue(path.isAbsolute(root),'configuration-path-required');
    for(const name of SERVERS) requireValue(!fs.lstatSync(path.join(root,name),{throwIfNoEntry:false}), 'legacy-global-skill-present');
  }
  const files=new Set([request.claudeSettingsFile,path.join(claudeDirectory,'settings.json')]);
  if(process.env.HOME) files.add(path.join(process.env.HOME,'.claude.json'));
  for(const file of files) {
    const config=readJSON(file,{});
    requireValue(!SERVERS.some(name=>config.mcpServers?.[name]),'duplicate-registration');
    requireValue(!Object.entries(config.enabledPlugins ?? {}).some(([name,enabled])=>ownPlugin(name) && enabled === true),'globally-enabled-shepherd-plugin');
  }
  const codex=readCodex(request.codexHome);
  requireValue(!SERVERS.some(name=>codex.mcp_servers?.[name]),'duplicate-registration');
  requireValue(!Object.entries(codex.plugins ?? {}).some(([name,config])=>ownPlugin(name) && config.enabled === true),'globally-enabled-shepherd-plugin');
  return {sessionOnly:true};
}
function mcpSettings(runner, descriptor) {return {command:process.execPath,args:[runner,descriptor],startup_timeout_sec:60,enabled:true};}
function codexOverrides(server) {return Object.entries(server).flatMap(([key,value])=>['-c',`mcp_servers.${SERVER}.${key}=${JSON.stringify(value)}`]);}
// Offline staging only: no process start, native authority or gate override.
export function stagePi(request) {
  return withLock(request.root,()=>{
    const installation=locations(request.root);requireValue(installation?.mode==='plugin','not-installed');
    const cli=resolvePiExecutable(request.executable ?? 'pi');
    const id=crypto.randomUUID(),sessionID=crypto.randomUUID(),folder=path.join(request.root,'pi',id);
    privateDirectory(folder);privateDirectory(path.join(folder,'bin'));privateDirectory(path.join(folder,'sessions'));
    const resources=installation.resourceDirectory, manifest=path.join(folder,'launch.json'),bootstrap=path.join(folder,'bootstrap.json');
    const args=piInvocation({extension:path.join(resources,'pi-entry.ts'),skill:path.join(resources,'skill','SKILL.md'),guidance:path.join(resources,'pi-guidance.md'),sessionID,
      arguments:request.arguments ?? []});
    args.push('--session-dir',path.join(folder,'sessions'));
    const entry=path.join(resources,'pi-launch.mjs');
    const shim=path.join(folder,'bin','pi');
    atomicWrite(shim,'#!/bin/sh\nexec '+quote(process.execPath)+' '+quote(entry)+' '+quote(manifest)+' "$@"\n');fs.chmodSync(shim,0o700);
    const search=process.env.PATH ?? '/usr/bin:/bin';
    requireValue(search.split(path.delimiter).every(p=>path.isAbsolute(p)),'invalid-execution-path');
    return {id,sessionID,folder,manifest,bootstrap,cli,node:process.execPath,entry,resources,arguments:args,
      environment:{PATH:path.join(folder,'bin')+path.delimiter+search},cliVersion:piPackageVersion(cli)};
  });
}
export function reserveLaunch(request) {
  return withLock(request.root,()=>{
    const reservationID=crypto.randomUUID();const folder=path.join(request.root,'reservations',reservationID);
    privateDirectory(folder);atomicWrite(path.join(folder,'.reserved'),JSON.stringify({reservationID}));
    return {reservationID,environment:{SHEPHERD_AGENT_SESSION:path.join(folder,'session.json')}};
  });
}
export function discardReservation(request) {
  return withLock(request.root,()=>{
    requireValue(/^[a-f0-9-]{36}$/.test(request.reservationID),'invalid-reservation');
    const folder=path.join(request.root,'reservations',request.reservationID);
    requireValue(fs.existsSync(path.join(folder,'.reserved')) && !fs.existsSync(path.join(folder,'session.json')),'reservation-already-prepared');
    fs.rmSync(folder,{recursive:true});return {removed:true};
  });
}
export function prepare(request) {
  return withLock(request.root,()=>prepareUnlocked(request));
}
function prepareUnlocked(request) {
  // No runtime flag can bypass the unfinished host/Pi identity qualification.
  requireValue(request.kind !== 'pi', 'pi-launch-unqualified');
  requireValue(typeof request.claudeSettingsFile === 'string' && path.isAbsolute(request.claudeSettingsFile),'configuration-path-required');
  const installation=locations(request.root);requireValue(installation,'not-installed');
  validateEndpoint(request.endpoint,request.pane);
  const kind=request.kind;requireValue(['claude','codex'].includes(kind),'invalid-agent');
  const capability=detect(kind,request.executable);requireValue(capability.readiness !== 'missing','cli-missing');
  requireValue(kind === 'claude' ? capability.sessionPlugin : capability.sessionConfiguration,'cli-unsupported');
  const preferences=request.preferences ?? {};const mode=preferences.mode ?? 'plugin';
  requireValue(mode === 'plugin' && installation.mode === 'plugin','session-only-policy');
  checkScope(request);
  const givenArgs=request.arguments ?? [];
  requireValue(Array.isArray(givenArgs) && givenArgs.every(a=>typeof a === 'string'),'invalid-arguments');
  // An agent goes through the agent proxy only when this launch asks for it:
  // the proxy's own arguments read back from an agent are left out.
  const userArgs=withoutApiProxy(kind,givenArgs,request.root);
  // Treat a manually supplied registration of this integration, under either
  // name, as a conflict rather than appending a second copy. Preserve all
  // unrelated arguments and profiles.
  if(kind === 'claude') inspectClaudeRegistrations(userArgs);
  else for(const override of optionValues(userArgs,['-c','--config'])) {
    const key=override.slice(0,override.indexOf('=')).trim();
    requireValue(!ownServerKey(key) && !(key.startsWith('plugins.') && ownPlugin(key.slice('plugins.'.length))) && !['mcp_servers','plugins'].includes(key),'duplicate-registration');
  }
  const claudeConfig=readJSON(request.claudeSettingsFile ?? path.join(process.env.CLAUDE_CONFIG_DIR ?? path.join(process.env.HOME,'.claude'),'.claude.json'),{});
  let profile=request.profile;
  if(kind === 'codex') for(const selected of optionValues(userArgs,['-p','--profile'])) {requireValue(!profile || profile === selected,'profile-conflict');profile=selected;}
  const codex=kind === 'codex' ? readCodex(request.codexHome ?? process.env.CODEX_HOME ?? path.join(process.env.HOME,'.codex'),profile) : {};
  if(mode === 'plugin') requireValue(!SERVERS.some(name=>claudeConfig.mcpServers?.[name] || codex.mcp_servers?.[name]),'duplicate-registration');
  requireValue(!Object.entries(codex.plugins ?? {}).some(([name,config])=>PLUGINS.some(plugin=>name.startsWith(plugin+'@'+plugin+'-')) && config.enabled === true),'globally-enabled-shepherd-plugin');
  const pluginSettings=readJSON(request.claudePluginSettingsFile ?? path.join(path.dirname(request.claudeSettingsFile),'settings.json'),{});
  requireValue(!Object.entries(pluginSettings.enabledPlugins ?? {}).some(([name,enabled])=>ownPlugin(name) && enabled === true),'globally-enabled-shepherd-plugin');
  // The agent proxy, unless the user's own settings point the agent elsewhere.
  let apiProxy=null;
  if(request.apiProxy !== undefined) {
    requireValue(request.apiProxy && typeof request.apiProxy === 'object' && validApiProxyBase(request.apiProxy.baseURL),'invalid-api-proxy');
    const managed=request.claudeManagedSettingsFile ?? CLAUDE_MANAGED_SETTINGS;
    requireValue(typeof managed === 'string' && path.isAbsolute(managed),'configuration-path-required');
    const reason=apiProxyConflict(kind,{args:userArgs,claudeSettingsFiles:[managed,request.claudeSettingsFile],codex});
    apiProxy={injected:reason === null,reason};
  }
  const outputMaxSize=preferences.outputMaxSize ?? 64*1024*1024;
  requireValue(Number.isSafeInteger(outputMaxSize) && outputMaxSize >= 1024*1024 && outputMaxSize <= 1024*1024*1024,'invalid-output-limit');
  for(const origin of [...(preferences.allowedOrigins ?? []),...(preferences.blockedOrigins ?? [])]) requireValue(/^https?:\/\/[^\s/]+$/.test(origin),'invalid-origin');
  const paneRoot=path.join(request.root,'panes',paneName(request.pane));privateDirectory(paneRoot);
  let sessionFolder;
  if(request.reservationID) {
    requireValue(/^[a-f0-9-]{36}$/.test(request.reservationID),'invalid-reservation');
    sessionFolder=path.join(request.root,'reservations',request.reservationID);privateDirectory(sessionFolder);
    requireValue(readJSON(path.join(sessionFolder,'.reserved'),null)?.reservationID === request.reservationID && !fs.existsSync(path.join(sessionFolder,'session.json')),'reservation-already-prepared');
  } else {sessionFolder=path.join(paneRoot,crypto.randomUUID());privateDirectory(sessionFolder);}
  try {
  const descriptor=path.join(sessionFolder,'session.json');const outputFolder=path.join(paneRoot,'output');privateDirectory(outputFolder);
  const session={pane:request.pane,endpoint:request.endpoint,outputFolder,outputMaxSize,allowedOrigins:preferences.allowedOrigins ?? [],blockedOrigins:preferences.blockedOrigins ?? [],credentialCLI:path.join(installation.resourceDirectory,'credential.mjs')};
  // Capability is provisioned by the app for this exact agent lease, never by
  // Node or the agent. Missing lifecycle integration leaves the CLI unavailable.
  if(request.credentialLeaseFile !== undefined) {
    requireValue(typeof request.credentialLeaseFile === 'string' && path.isAbsolute(request.credentialLeaseFile),'invalid-credential-lease');
    session.credentialLeaseFile=request.credentialLeaseFile;
  }
  atomicWrite(descriptor,JSON.stringify(session));
  const runner=path.join(installation.resourceDirectory,'mcp-run.mjs');
  const pluginDirectory=path.join(sessionFolder,'plugin');
  plugin(pluginDirectory,runner,[descriptor],quote(process.execPath)+' '+quote(path.join(installation.resourceDirectory,'hook.mjs'))+' '+quote(request.root));
  const server=mcpSettings(runner,descriptor);
  const mcpConfiguration=path.join(sessionFolder,'mcp.json');atomicWrite(mcpConfiguration,JSON.stringify({mcpServers:{[SERVER]:server}}));
  let args=[];let injection;
  if(kind === 'claude') {args=['--plugin-dir',pluginDirectory];injection='plugin';}
  else {args=codexOverrides(server);injection='codexConfigurationFallback';}
  if(apiProxy?.injected) {
    if(kind === 'claude') {
      // Claude Code's own environment variables, in a settings file only this
      // user can read: the base URL carries the route's token.
      const settings=path.join(sessionFolder,API_PROXY_SETTINGS);
      atomicWrite(settings,JSON.stringify({env:{ANTHROPIC_BASE_URL:request.apiProxy.baseURL,
        CLAUDE_CODE_GATEWAY_HINT_HEADERS:'1',CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING:'1'}}));
      args.push('--settings',settings);
    } else args.push('-c','openai_base_url='+JSON.stringify(request.apiProxy.baseURL+'/backend-api/codex'));
  }
  // Codex plugins cannot reliably rewrite child commands. This appended
  // instruction is also the tested capability fallback, merged with user text.
  if(kind === 'codex') {
    let instructions=codex;
    for(const value of optionValues(userArgs,['-c','--config'])) {
      const equal=value.indexOf('=');
      if(equal >= 0 && value.slice(0,equal).trim() === 'developer_instructions') instructions={...codex,developer_instructions:instructionOverride(value.slice(equal+1))};
    }
    const skill=fs.readFileSync(path.join(installation.resourceDirectory,'skill','SKILL.md'),'utf8');
    requireValue(Buffer.byteLength(skill) <= 16384,'skill-instructions-too-large');
    // This is session guidance, not a claimed native Codex skill registration.
    args.push('-c','developer_instructions='+JSON.stringify(mergedInstructions(instructions,skill)));
  }
  if(preferences.disableCompetingBrowsers) {
    const names=preferences.competingBrowserServers ?? [];
    requireValue(names.every(n=>/^[a-zA-Z0-9_-]+$/.test(n) && !SERVERS.includes(n)),'invalid-server-name');
    if(kind === 'claude') args.push('--no-chrome',...names.flatMap(n=>['--disallowedTools',`mcp__${n}__*`]));
    else {
      requireValue(names.every(n=>codex.mcp_servers?.[n]),'unknown-competing-server');
      args.push(...names.flatMap(n=>['-c',`mcp_servers.${n}.enabled=false`]));
    }
  }
  args=[...(kind === 'codex' && request.profile && !optionValues(userArgs,['-p','--profile']).length ? ['--profile',request.profile] : []),...userArgs,...args];
  if(request.resumeSession) args=resume(kind,args,request.resumeSession);
  const result={kind,executable:request.executable,arguments:args,environment:request.reservationID ? {SHEPHERD_AGENT_SESSION:descriptor} : {},outputFolder,sessionFolder,pluginDirectory,mcpConfiguration,mcpArguments:server.args,codexPluginKey:null,injection,...(apiProxy ? {apiProxy} : {})};
  const registryFile=path.join(request.root,'panes.json');const registry=readJSON(registryFile,[]).filter(p=>paneName(p.pane) !== paneName(request.pane) || p.kind !== kind);
  if(request.reservationID) fs.unlinkSync(path.join(sessionFolder,'.reserved'));
  // Codex's proxy argument carries the route's token: not kept in the registry.
  registry.push({...result,arguments:withoutApiProxy(kind,args,request.root),pane:request.pane,descriptor});atomicWrite(registryFile,JSON.stringify(registry));
  return result;
  } catch(error) {
    fs.rmSync(sessionFolder,{recursive:true,force:true});
    if(request.reservationID) {privateDirectory(sessionFolder);atomicWrite(path.join(sessionFolder,'.reserved'),JSON.stringify({reservationID:request.reservationID}));}
    throw error;
  }
}
export function registerPane(request) {
  return withLock(request.root,()=>{
    validateEndpoint(request.endpoint,request.pane);
    const file=path.join(request.root,'endpoints.json');
    const entries=readJSON(file,[]).filter(p=>paneName(p.pane) !== paneName(request.pane));
    entries.push(request);atomicWrite(file,JSON.stringify(entries));return {registered:true};
  });
}
export function rewrite(command, root) {
  const child=childCommand(command);if(!child) return {command,reason:'unsupported-command',rewritten:false};
  const entries=readJSON(path.join(root,'panes.json'),[]);
  const session=process.env.HERDR_SOCKET_PATH;
  const parentSession=session?.match(/\/sessions\/([^/]+)\/herdr\.sock$/)?.[1] ?? 'default';
  const matches=entries.filter(p=>p.pane.paneID === child.pane && p.pane.session === parentSession && p.kind === child.kind);
  const endpoints=readJSON(path.join(root,'endpoints.json'),[]).filter(p=>p.pane.paneID === child.pane && p.pane.session === parentSession);
  if(matches.length > 1 || endpoints.length > 1 || (!matches.length && !endpoints.length)) return {command,reason:'unregistered-or-ambiguous-pane',rewritten:false};
  let prepared=matches[0];
  if(prepared && injected(child.kind,child.args,prepared)) return {command,reason:'already-injected',rewritten:false};
  if(endpoints.length === 1) {
    try {prepared=prepare({...endpoints[0],kind:child.kind,executable:endpoints[0].executables?.[child.kind] ?? child.kind,arguments:child.args,forceCodexFallback:child.kind === 'codex'});}
    catch{return {command,reason:'child-preparation-failed',rewritten:false};}
    return {command:[...child.words.slice(0,child.tail),'--',...prepared.arguments].map(quote).join(' '),reason:'injected',rewritten:true};
  }
  // A prepared argv record alone has no current profile/config host context.
  // Never append its stale instructions to a child's newly selected arguments.
  return {command,reason:'fresh-child-context-unavailable',rewritten:false};
}
function assertNoLiveMCP(folder) {
  if(!fs.existsSync(folder)) return;
  for(const file of fs.readdirSync(folder)) {
    const pid=file.match(/^\.mcp-([0-9]+)\.json$/)?.[1];if(!pid) continue;
    let live=false;try{process.kill(+pid,0);live=true;}catch(error){if(error.code !== 'ESRCH') live=true;}
    requireValue(!live,'mcp-still-running');
  }
  for(const name of fs.readdirSync(folder)) {
    const session=path.join(folder,name);if(!fs.lstatSync(session).isDirectory()) continue;
    for(const file of fs.readdirSync(session)) {
      const pid=file.match(/^\.mcp-([0-9]+)\.json$/)?.[1];if(!pid) continue;
      let live=false;try{process.kill(+pid,0);live=true;}catch(error){if(error.code !== 'ESRCH') live=true;}
      requireValue(!live,'mcp-still-running');
    }
  }
}
export function cleanup(request) {
  return withLock(request.root,()=>{
    const name=paneName(request.pane);const folder=path.join(request.root,'panes',name);
    const reservations=path.join(request.root,'reservations');const ownedReservations=[];
    if(fs.existsSync(reservations)) for(const id of fs.readdirSync(reservations)) {
      const candidate=path.join(reservations,id);if(!/^[a-f0-9-]{36}$/.test(id) || !fs.lstatSync(candidate).isDirectory()) continue;
      const session=readJSON(path.join(candidate,'session.json'),null);
      if(session && paneName(session.pane) === name) {assertNoLiveMCP(candidate);ownedReservations.push(candidate);}
    }
    if(fs.existsSync(folder)) {
      const s=fs.lstatSync(folder);requireValue(s.isDirectory() && !s.isSymbolicLink() && s.uid === process.getuid(),'unsafe-cleanup');
      assertNoLiveMCP(folder);
      fs.rmSync(folder,{recursive:true});
    }
    for(const folder of ownedReservations) fs.rmSync(folder,{recursive:true});
    for(const file of ['panes.json','endpoints.json']) {
      const registryFile=path.join(request.root,file);atomicWrite(registryFile,JSON.stringify(readJSON(registryFile,[]).filter(p=>paneName(p.pane) !== name)));
    }
    return {removed:true};
  });
}
export function setMode(_request) { throw new RuntimeError('session-only-policy'); }
if(process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let input='';for await(const chunk of process.stdin) {input+=chunk;requireValue(input.length <= 1024*1024,'request-too-large');}
  try {
    const request=JSON.parse(input);let result;
    switch(request.action) {
      case 'install':result=install(request);break;
      case 'setupCodex':result=setupCodex(request);break;
      case 'checkScope':result=checkScope(request);break;
      case 'prepare':result=prepare(request);break;
      case 'reserveLaunch':result=reserveLaunch(request);break;
      case 'stagePi':result=stagePi(request);break;
      case 'discardReservation':result=discardReservation(request);break;
      case 'setMode':result=setMode(request);break;
      case 'cleanup':result=cleanup(request);break;
      case 'registerPane':result=registerPane(request);break;
      case 'status':result={installation:locations(request.root)};break;
      case 'detect':result=detect(request.kind,request.executable);break;
      default:throw new RuntimeError('invalid-action');
    }
    process.stdout.write(JSON.stringify({ok:true,result})+'\n');
  } catch(error) {
    // runScript throws on nonzero exit and discards stdout. A handled RPC
    // rejection therefore uses a normal transport completion with ok:false;
    // the typed Swift client must (and does) reject that envelope. Crashes or
    // missing executables still fail transport with no valid result.
    process.stdout.write(JSON.stringify({ok:false,error:error instanceof RuntimeError || error instanceof PiIntegrationError ? error.code : 'runtime-failed'})+'\n');
  }
}
