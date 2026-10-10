import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {pathToFileURL} from 'node:url';
import crypto from 'node:crypto';
const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const {control,privateJSON}=await import(pathToFileURL(path.join(config.resources,'pi-control.mjs')));
if(process.argv[3]==='intruder') {
  const reply=await control(config.bootstrap,'open',crypto.randomUUID(),config.identity);
  assert.equal(reply.ok,false); process.stdout.write('INTRUDER_DENIED\n');
} else {
  const deadline=Date.now()+10000;
  while(!fs.existsSync(config.go)) {
    if(Date.now()>deadline)throw new Error('fixture admission deadline');
    await new Promise(resolve=>setTimeout(resolve,500));
  }
  if(config.mode==='exec') {
    const originalArguments=[...process.argv];
    process.title='pi';
    if(process.env.SHEPHERD_FIXTURE_REEXEC!=='1') {
      process.execve(process.execPath,originalArguments,{...process.env,SHEPHERD_FIXTURE_REEXEC:'1'});
      throw new Error('exec unexpectedly returned');
    }
    const reply=await control(config.bootstrap,'open',crypto.randomUUID(),{...config.identity,pid:process.pid});
    assert.equal(reply.ok,false);
    fs.writeFileSync(config.result,JSON.stringify({passed:true,mode:'exec',samePID:true}),{mode:0o600});
    process.stdout.write('PASS same-PID same-Node exec rejected despite matching Pi title\n');
    process.exit(0);
  }
  const {createPiHost}=await import(pathToFileURL(path.join(config.resources,'pi-host.mjs')));
  const {registerPiLifecycle}=await import(pathToFileURL(path.join(config.resources,'pi-lifecycle.mjs')));
  const identity={...config.identity,pid:process.pid};
  const handlers=new Map(), children=[], statuses=[];
  let active, registerCount=0, controller;
  const api={
    on(name,fn){handlers.set(name,fn);},
    registerMcpServer(name,server){
      assert.equal(name,'shepherd-browser');registerCount++;
      if(config.mode==='shadow')return; // configured server replaced our registration
      const child=spawn(server.command,server.args,{cwd:config.cwd,stdio:['pipe','pipe','pipe'],
        env:{HOME:config.home,PATH:process.env.PATH,LANG:'en_US.UTF-8'}});
      children.push(child);active=child;
      let pending='';
      child.stderr.resume();
      child.stdout.on('data',data=>{
        pending+=data;
        if(pending.length>1024*1024)throw new Error('MCP fixture output limit');
        let nl;
        while((nl=pending.indexOf('\n'))>=0){
          const line=pending.slice(0,nl);pending=pending.slice(nl+1);
          const message=JSON.parse(line);
          if(message.id===1){
            assert(message.result?.protocolVersion);
            child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
            child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list',params:{}})+'\n');
          }
          if(message.id===2)assert(message.result?.tools.some(tool=>tool.name==='browser_snapshot'));
        }
      });
      child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'owned-shepherd-pi-fixture',version:'1'}}})+'\n');
    },
    unregisterMcpServer(){active?.stdin.end();active=undefined;}
  };
  const host=createPiHost(config.bootstrap,{report:state=>statuses.push(state),onFailure:()=>{void controller?.shutdown();}});
  controller=registerPiLifecycle(api,host);
  const context={cwd:config.cwd,sessionManager:{getSessionId:()=>identity.sessionID,getSessionFile:()=>identity.sessionFile,getLeafId:()=>identity.leafID},
    isIdle:()=>true,hasPendingMessages:()=>false};
  await handlers.get('session_start')({reason:'startup'},context);
  if(config.mode==='shadow'){
    assert.equal(controller.state(),'failed');assert.equal(children.length,0);
  } else {
    assert.equal(controller.state(),'ready');
    const intruderConfig=path.join(config.cwd,'intruder.json');
    fs.writeFileSync(intruderConfig,JSON.stringify({...config,identity}),{mode:0o600});
    const intruder=spawn(process.execPath,[process.argv[1],intruderConfig,'intruder'],{cwd:config.cwd,stdio:['ignore','pipe','pipe']});
    let stdout='';intruder.stdout.on('data',d=>stdout+=d);intruder.stderr.resume();
    const [code]=await once(intruder,'exit');assert.equal(code,0);assert(stdout.includes('INTRUDER_DENIED'));
    await handlers.get('agent_start')({},context);
    await handlers.get('agent_settled')({},context);assert.equal(controller.state(),'idle');
    assert.equal(await handlers.get('session_before_tree')({},context),undefined);
    identity.leafID='branch-two';
    await handlers.get('session_tree')({},context);assert.equal(controller.state(),'ready');
    assert.equal(registerCount,2);
    await handlers.get('session_before_switch')({},context);
    identity.sessionID=crypto.randomUUID();
    identity.sessionFile=path.join(config.sessions,'different_'+identity.sessionID+'.jsonl');
    await handlers.get('session_start')({reason:'new'},context);assert.equal(controller.state(),'failed');
  }
  await controller.shutdown();
  for(const child of children) {
    if(child.exitCode===null && child.signalCode===null)await once(child,'exit');
    assert.equal(child.exitCode,0);
  }
  fs.writeFileSync(config.result,JSON.stringify({passed:true,mode:config.mode,registerCount,states:statuses,childrenExited:children.length}),{mode:0o600});
  process.stdout.write('PASS owned Pi client '+config.mode+'\n');
}
