#!/usr/bin/env python3
"""Experimental Features is two cards, one per feature: the real page, rendered in a never-shown window; no app."""
from pathlib import Path
import argparse,os,json,hashlib,subprocess,sys,platform,re
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False)
for n in ['home','tmp','cache','renders']:(out/n).mkdir(mode=0o700)
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',HOME=str(out/'home'),CFFIXED_USER_HOME=str(out/'home'),TMPDIR=str(out/'tmp'),CLANG_MODULE_CACHE_PATH=str(out/'cache'))
page,agents,passwords='Shepherd/Hosts/Views/ExperimentalFeaturesSettingsView.swift','Shepherd/Hosts/Views/AgentSkillRows.swift','Shepherd/PasswordManagers/PasswordManagerSettingsRows.swift'
# The launch service's own stand-ins, as in Phase3's run-managed-skill-tests.py.
service=['Shepherd/Agents/'+n+'.swift' for n in ['AgentRuntime','PiProcessIdentity','AgentHostExecutables','AgentSkillPreparation','AgentLaunchService','ExperimentalSettingsDiagnostics','AgentSavedSession','AgentIdleStopPolicy','AgentLaunchState','AgentResumeConfirmation','AgentBrowserAdapter']]
service+=['Shepherd/Hosts/Models/Machine.swift','Shepherd/Hosts/Models/AgentSkillSetup.swift','Shepherd/Browser/BrowserKey.swift','Shepherd/Browser/CDPPolicy.swift','Shepherd/HerdrKit/HerdrClient.swift','Shepherd/HerdrKit/Transport/HerdrTransport.swift','Shepherd/HerdrKit/Terminal/ShellQuoting.swift']
service+=[str(x.relative_to(ROOT)) for x in sorted((ROOT/'Shepherd/HerdrKit/Models').glob('*.swift'))]+['Tests/AgentBrowser/Phase3/AgentSkillPreparationSeams.swift']
# The password manager rows, as in Phase3's run-password-selection-tests.py.
credentials=['Shepherd/CredentialBroker/CredentialBrokerContracts.swift','Shepherd/CredentialBroker/CredentialBroker.swift','Shepherd/CredentialBroker/Interface/CredentialCLIService.swift','Shepherd/CredentialBroker/Interface/CredentialGrantView.swift']
credentials+=['Shepherd/PasswordManagers/'+n+'.swift' for n in ['PasswordManagerProviderID','PasswordManagerPreferences','PasswordManagerProvider','PasswordManagerCommandExecutor','BitwardenUnlockCommand','CLICredentialProvider','PasswordManagerConnectionCoordinator','PasswordManagerConnectionSetupView']]
credentials+=['Shepherd/HerdrKit/Terminal/LocalCommand.swift']
sources=service+credentials+[page,agents,passwords,'Shepherd/Hosts/Views/SettingsPageChrome.swift','Shepherd/Hosts/Views/InfoButton.swift','Shepherd/FileDrop/TerminalFileDropFeature.swift','Shepherd/Terminal/LinkDestinationPolicy.swift','Tests/Settings/ExperimentalFeaturesLayoutTests.swift']
(out/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in sources},indent=2))
def stage(name,seconds,args):
 log=out/(name+'.log')
 code=subprocess.run([sys.executable,str(ROOT/'Tests/AgentBrowser/Phase2/run-stage.py'),'--timeout',str(seconds),'--natural-exit-grace','10','--log',str(log),'--',*args],cwd=ROOT,env=env,timeout=seconds+40).returncode
 j=json.loads(log.with_suffix('.stage.json').read_text());assert code==0 and j['naturalExitConfirmed'] and not j['signalsSent'] and j['cleanupVerified'],name
stage('build',300,['xcrun','swiftc','-swift-version','6','-default-isolation','MainActor','-target',platform.machine()+'-apple-macos26.6.2','-parse-as-library',*sources,'-o',str(out/'layout-tests')])
stage('tests',90,[str(out/'layout-tests'),str(out/'renders')])
# What the renders cannot reach (a remote machine, an open connection setup):
# the browser's rows are rows, and the page has one Section per feature.
e,a,w=[(ROOT/v).read_text() for v in [page,agents,passwords]]
assert len(re.findall(r'\bSection\b',e))==2 and e.count('            Section {\n')==2
assert not re.search(r'\bSection\b',a+w)
assert e.index('Text("hrdrhrdrhrdr Browser")')<e.index('PasswordManagerSettingsRows(')<e.index('AgentSkillRows(')<e.index('                    advancedSettings\n')<e.index('if showsDiagnostics { diagnosticsRows }')<e.index('Text("Terminal File Drop")')
assert '            Text("Diagnostics")\n' in e
(out/'validation.json').write_text(json.dumps({'passed':True,'stages':2,'twoCards':True,'browserRowsInBrowserCard':True,'diagnosticsLastInBrowserCard':True,'neverShownWindow':True,'appOrUserInput':False},indent=2))
