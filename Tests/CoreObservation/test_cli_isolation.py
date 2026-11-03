"""Pure isolation construction tests; no real CLI/account/process is consulted."""
from pathlib import Path
import json
import tempfile
import unittest
import cli_isolation as isolation


class CLIIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cli-policy-test.')
        self.root=Path(self.temp.name).resolve()
    def tearDown(self):self.temp.cleanup()

    def test_environment_is_explicit_and_private(self):
        home=self.root/'home';env=isolation.environment(home,self.root/'bin/node')
        self.assertEqual(env['HOME'],str(home))
        for key in ['PI_CODING_AGENT_DIR','PI_CODING_AGENT_SESSION_DIR','CODEX_HOME','CLAUDE_CONFIG_DIR','TMPDIR','XDG_CONFIG_HOME']:
            self.assertTrue(Path(env[key]).is_relative_to(home))
        for key in ['ANTHROPIC_API_KEY','OPENAI_API_KEY','SHEPHERD_PI_BRIDGE','HERDR_SOCKET_PATH','PI_SESSION_ID','PI_SESSION_FILE','NODE_OPTIONS','HTTP_PROXY','HTTPS_PROXY']:
            self.assertNotIn(key,env)
        self.assertEqual(env['PI_OFFLINE'],'1')
        self.assertEqual(env['DISABLE_AUTOUPDATER'],'1')

    def test_policy_blocks_services_network_and_other_processes(self):
        profile=isolation.profile(self.root,[self.root/'node'],[self.root/'public-package'])
        for rule in ['(deny network*)','(deny mach-lookup)','(deny process-info*)','(deny signal)','(deny process-exec)',
                     '(deny sysctl-read','(subpath "/Library/Keychains")','(subpath "/System/Library/Keychains")']:
            self.assertIn(rule,profile)
        self.assertIn('(deny file-read* (require-not',profile)
        self.assertIn('(deny file-write* (require-not',profile)
        self.assertNotIn('(deny file-read*)',profile) # unconditional deny also blocks the required runtime

    def test_missing_system_policy_exception_cannot_read_regular_files(self):
        profile=isolation.profile(self.root,[self.root/'node'],[],missing_config_roots=['/private/etc/codex'])
        self.assertIn('(require-all (subpath "/private/etc/codex") (require-not (vnode-type REGULAR-FILE)))',profile)

    def test_inherited_core_boundary_keeps_network_and_processes_scoped(self):
        with self.assertRaises(ValueError):isolation.profile(self.root,[],[],core_runtime=True,core_home=self.root.parent)
        profile=isolation.profile(self.root,[self.root/'core'],[],core_runtime=True,core_home=self.root/'owned-core')
        self.assertIn('(deny network* (require-not',profile)
        self.assertIn('(deny signal (require-not (target same-sandbox)))',profile)
        self.assertIn('(deny mach-lookup)',profile)
        self.assertNotIn('(allow network*)',profile)

    def test_only_the_owned_tty_is_added(self):
        profile=isolation.profile(self.root,[self.root/'node'],[],tty_path='/dev/ttys123')
        self.assertIn('(literal "/dev/ttys123")',profile)
        self.assertNotIn('(subpath "/dev")',profile)
        self.assertNotIn('^/dev/ttys',profile)

    def test_paths_cannot_inject_profile_rules(self):
        path=self.root/'a" ) (allow network*)'
        profile=isolation.profile(self.root,[path],[])
        self.assertIn(json.dumps(str(path)),profile)
        self.assertEqual(profile.count('\n(deny network*)\n'),1)
        self.assertNotIn('\n(allow network*)',profile)

    def package(self,path,dependencies=None):
        path.mkdir(parents=True)
        (path/'package.json').write_text(json.dumps({'name':path.name,'dependencies':dependencies or {}}))
        (path/'cli.js').write_text('// inert fixture')
        return path/'cli.js'

    def test_dependency_closure_is_code_only_and_handles_cycles(self):
        modules=self.root/'install/node_modules'
        entry=self.package(modules/'@scope/agent',{'dep':'1'})
        self.package(modules/'dep',{'@scope/agent':'1'})
        self.assertEqual(set(isolation.package_roots(entry)),{modules/'@scope/agent',modules/'dep'})

    def test_dependency_link_leaving_installation_is_rejected(self):
        modules=self.root/'install/node_modules'
        entry=self.package(modules/'agent',{'dep':'1'})
        self.package(self.root/'outside')
        (modules/'dep').symlink_to(self.root/'outside',target_is_directory=True)
        with self.assertRaises(ValueError):isolation.package_roots(entry)

    def test_invocation_does_not_load_parent_resources(self):
        for flag in ['--no-extensions','--no-mcp','--no-context-files','--no-approve','--no-tools']:
            self.assertIn(flag,isolation.PI_FLAGS)
        self.assertNotIn('--continue',isolation.PI_FLAGS)
        self.assertNotIn('--approve',isolation.PI_FLAGS)


if __name__=='__main__':unittest.main()
