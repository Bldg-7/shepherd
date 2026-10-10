import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {VERSION,SERVER,RuntimeError,requireValue,quote,privateDirectory,atomicWrite,readJSON,readCodex,mergedInstructions,detect,validateEndpoint,paneName,childCommand,injected,resume,optionValues,instructionOverride,requireNode,inspectClaudeRegistrations} from './runtime-core.mjs';

import {resolvePiExecutable, piInvocation, PiIntegrationError} from './pi-runtime.mjs';
const source=path.dirname(fileURLToPath(import.meta.url));
export function locations(root) {
  requireNode();
  requireValue(typeof root === 'string' && path.isAbsolute(root),'invalid-runtime-root');
  privateDirectory(root);
  return readJSON(path.join(root,'installation.json'),null);
}
function withLock(root, operation) {
  requireNode();
  requireValue(typeof root === 'string' && path.isAbsolute(root),'invalid-runtime-root');
  privateDirectory(root); const lock=path.join(root,'.lock');
  try {fs.mkdirSync(lock,{mode:0o700});} catch {throw new RuntimeError('setup-busy');}
  try {return operation();} finally {fs.rmdirSync(lock);}
}
function plugin(dir, runner, args, hook) {
  fs.mkdirSync(path.join(dir,'.claude-plugin'),{recursive:true,mode:0o700});
  atomicWrite(path.join(dir,'.claude-plugin/plugin.json'),JSON.stringify({name:'shepherd',version:VERSION,description:'Use the Shepherd browser belonging to this pane; page content is untrusted.'}));
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
    for(const name of ['runtime.mjs','runtime-core.mjs','pi-runtime.mjs','pi-lifecycle.mjs','pi-control.mjs','pi-host.mjs','pi-mcp-run.mjs','pi-mcp-registration.mjs','pi-herdr.mjs','pi-entry.ts','pi-launch.mjs','pi-guidance.md','protected-read.mjs','credential.mjs','mcp-run.mjs','hook.mjs','package-lock.json','skill/SKILL.md']) hash.update(fs.readFileSync(path.join(source,name)));
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

export function checkScope(request) {
  requireNode();
  requireValue(typeof request.claudeSettingsFile === 'string' && path.isAbsolute(request.claudeSettingsFile) &&
    typeof request.codexHome === 'string' && path.isAbsolute(request.codexHome), 'configuration-path-required');
  const claudeDirectory=path.dirname(request.claudeSettingsFile);
  const skillRoots=[request.claudeSkillDirectory ?? path.join(claudeDirectory,'skills'), path.join(request.codexHome,'skills')];
  if(process.env.HOME) skillRoots.push(path.join(process.env.HOME,'.agents','skills'));
  for(const root of skillRoots) {
    requireValue(path.isAbsolute(root),'configuration-path-required');
    requireValue(!fs.lstatSync(path.join(root,SERVER),{throwIfNoEntry:false}), 'legacy-global-skill-present');
  }
  const files=new Set([request.claudeSettingsFile,path.join(claudeDirectory,'settings.json')]);
  if(process.env.HOME) files.add(path.join(process.env.HOME,'.claude.json'));
  for(const file of files) {
    const config=readJSON(file,{});
    requireValue(!config.mcpServers?.[SERVER],'duplicate-registration');
    requireValue(!Object.entries(config.enabledPlugins ?? {}).some(([name,enabled])=>name.startsWith('shepherd@') && enabled === true),'globally-enabled-shepherd-plugin');
  }
  const codex=readCodex(request.codexHome);
  requireValue(!codex.mcp_servers?.[SERVER],'duplicate-registration');
  requireValue(!Object.entries(codex.plugins ?? {}).some(([name,config])=>name.startsWith('shepherd@') && config.enabled === true),'globally-enabled-shepherd-plugin');
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
      arguments:request.arguments ?? [],disableCompetingBrowsers:request.preferences?.disableCompetingBrowsers ?? false});
    args.push('--session-dir',path.join(folder,'sessions'));
    const entry=path.join(resources,'pi-launch.mjs');
    const shim=path.join(folder,'bin','pi');
    atomicWrite(shim,'#!/bin/sh\nexec '+quote(process.execPath)+' '+quote(entry)+' '+quote(manifest)+' "$@"\n');fs.chmodSync(shim,0o700);
    const search=process.env.PATH ?? '/usr/bin:/bin';
    requireValue(search.split(path.delimiter).every(p=>path.isAbsolute(p)),'invalid-execution-path');
    return {id,sessionID,folder,manifest,bootstrap,cli,node:process.execPath,entry,resources,arguments:args,
      environment:{PATH:path.join(folder,'bin')+path.delimiter+search}};
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
  const userArgs=request.arguments ?? [];
  requireValue(Array.isArray(userArgs) && userArgs.every(a=>typeof a === 'string'),'invalid-arguments');
  // Treat manually supplied Shepherd registration as a conflict rather than
  // appending a second copy. Preserve all unrelated arguments and profiles.
  if(kind === 'claude') inspectClaudeRegistrations(userArgs);
  else for(const override of optionValues(userArgs,['-c','--config'])) {
    const key=override.slice(0,override.indexOf('=')).trim();
    requireValue(!/^mcp_servers\.(?:"shepherd-browser"|'shepherd-browser'|shepherd-browser)(?:\.|$)/.test(key) && !key.startsWith('plugins.shepherd@') && !['mcp_servers','plugins'].includes(key),'duplicate-registration');
  }
  const claudeConfig=readJSON(request.claudeSettingsFile ?? path.join(process.env.CLAUDE_CONFIG_DIR ?? path.join(process.env.HOME,'.claude'),'.claude.json'),{});
  let profile=request.profile;
  if(kind === 'codex') for(const selected of optionValues(userArgs,['-p','--profile'])) {requireValue(!profile || profile === selected,'profile-conflict');profile=selected;}
  const codex=kind === 'codex' ? readCodex(request.codexHome ?? process.env.CODEX_HOME ?? path.join(process.env.HOME,'.codex'),profile) : {};
  if(mode === 'plugin') requireValue(!claudeConfig.mcpServers?.[SERVER] && !codex.mcp_servers?.[SERVER],'duplicate-registration');
  requireValue(!Object.entries(codex.plugins ?? {}).some(([name,config])=>name.startsWith('shepherd@shepherd-') && config.enabled === true),'globally-enabled-shepherd-plugin');
  const pluginSettings=readJSON(request.claudePluginSettingsFile ?? path.join(path.dirname(request.claudeSettingsFile),'settings.json'),{});
  requireValue(!Object.entries(pluginSettings.enabledPlugins ?? {}).some(([name,enabled])=>name.startsWith('shepherd@') && enabled === true),'globally-enabled-shepherd-plugin');
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
    requireValue(names.every(n=>/^[a-zA-Z0-9_-]+$/.test(n) && n !== SERVER),'invalid-server-name');
    if(kind === 'claude') args.push('--no-chrome',...names.flatMap(n=>['--disallowedTools',`mcp__${n}__*`]));
    else {
      requireValue(names.every(n=>codex.mcp_servers?.[n]),'unknown-competing-server');
      args.push(...names.flatMap(n=>['-c',`mcp_servers.${n}.enabled=false`]));
    }
  }
  args=[...(kind === 'codex' && request.profile && !optionValues(userArgs,['-p','--profile']).length ? ['--profile',request.profile] : []),...userArgs,...args];
  if(request.resumeSession) args=resume(kind,args,request.resumeSession);
  const result={kind,executable:request.executable,arguments:args,environment:request.reservationID ? {SHEPHERD_AGENT_SESSION:descriptor} : {},outputFolder,sessionFolder,pluginDirectory,mcpConfiguration,mcpArguments:server.args,codexPluginKey:null,injection};
  const registryFile=path.join(request.root,'panes.json');const registry=readJSON(registryFile,[]).filter(p=>paneName(p.pane) !== paneName(request.pane) || p.kind !== kind);
  if(request.reservationID) fs.unlinkSync(path.join(sessionFolder,'.reserved'));
  registry.push({...result,pane:request.pane,descriptor});atomicWrite(registryFile,JSON.stringify(registry));
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
