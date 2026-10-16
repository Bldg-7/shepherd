import fs from 'node:fs';
import path from 'node:path';

// Qualified local TUI launch only. Resume/headless/children remain separate.
// No preference, argv or environment override of the native binding contract.
export const PI_MANAGED_LAUNCH_QUALIFIED = true;
export const PI_VERSION_RANGE = '^1.0.0';
export const PI_PACKAGE = '@earendil-works/pi-coding-agent';
export const PI_MINIMUM_NODE = '22.19.0';
export class PiIntegrationError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const check = (value, code) => { if (!value) throw new PiIntegrationError(code); };
export function piNodeSupported(version = process.versions.node) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  return !!match && (+match[1] > 22 || (+match[1] === 22 && +match[2] >= 19));
}
// npm caret on a nonzero major: the range's major, at or above its floor. Only a
// plain release `x.y.z` matches; pre-release, build, partial or `v` forms do not.
export function piVersionSupported(version) {
  const release = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
  const [, major, minor, patch] = release.exec(PI_VERSION_RANGE.slice(1)).map(Number);
  const match = typeof version === 'string' && release.exec(version);
  return !!match && +match[1] === major && (+match[2] > minor || (+match[2] === minor && +match[3] >= patch));
}

function executablePath(executable, environment) {
  check(typeof executable === 'string' && executable.length > 0 && !executable.includes('\0'), 'pi-executable-invalid');
  const candidates = path.isAbsolute(executable) ? [executable] :
    executable === 'pi' ? (environment.PATH ?? '').split(path.delimiter).filter(dir => path.isAbsolute(dir)).map(dir => path.join(dir, executable)) : [];
  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      const real = fs.realpathSync(candidate);
      if (fs.statSync(real).isFile()) return real;
    } catch {}
  }
  return null;
}

function packageManifest(executable) {
  let directory = path.dirname(executable);
  for (let depth = 0; depth < 6; depth++) {
    const file = path.join(directory, 'package.json');
    if (fs.existsSync(file)) {
      const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try {
        const stat = fs.fstatSync(fd);
        check(stat.isFile() && stat.size <= 65536 && (stat.mode & 0o022) === 0, 'pi-manifest-unsafe');
        const manifest = JSON.parse(fs.readFileSync(fd, 'utf8'));
        const bin = typeof manifest.bin === 'string' ? manifest.bin : manifest.bin?.pi;
        check(manifest.name === PI_PACKAGE && typeof bin === 'string' && path.resolve(directory, bin) === executable, 'pi-package-unsupported');
        return manifest;
      } finally { fs.closeSync(fd); }
    }
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  throw new PiIntegrationError('pi-package-unsupported');
}

export function resolvePiExecutable(executable, environment = process.env) {
  check(piNodeSupported(), 'node-version-unsupported');
  const real = executablePath(executable, environment);
  check(real && piVersionSupported(packageManifest(real).version), 'pi-package-unsupported');
  return real;
}

// No `pi --help`, `pi --version`, settings, auth, extensions or MCP invocation.
// Even Pi's --version creates a settings manager before its early exit. This
// read-only manifest probe is intentionally NOT executable/login qualification.
export function detectPi(executable, { environment = process.env, nodeVersion = process.versions.node } = {}) {
  const result = { kind: 'pi', executable, version: null, nodeVersion,
    nodeSupported: piNodeSupported(nodeVersion), readiness: 'missing',
    sessionPlugin: false, sessionConfiguration: false, hookRewrite: false };
  try {
    const real = executablePath(executable, environment);
    if (!real) return result;
    if (!result.nodeSupported) return { ...result, readiness: 'unsupportedPrerequisite' };
    const manifest = packageManifest(real);
    result.version = typeof manifest.version === 'string' ? manifest.version : null;
    const qualified=piVersionSupported(result.version) && PI_MANAGED_LAUNCH_QUALIFIED;
    return { ...result, sessionPlugin:qualified,
      readiness: piVersionSupported(result.version) ? (qualified?'availableAuthenticationUnknown':'integrationUnavailable') : 'unsupported' };
  } catch { return { ...result, readiness: 'unsupported' }; }
}

// Pure argv planning, not authorization to start. No shell parsing, configuration
// reads/writes, token parameters, or automatic trust/extension suppression.
// "Block other browser tools" does not reach Pi: Pi keeps all of its MCP servers.
export function piInvocation({ extension, skill, guidance, sessionID, arguments: args = [] }) {
  for (const file of [extension, skill, guidance]) check(typeof file === 'string' && path.isAbsolute(file) && !file.includes('\0'), 'pi-resource-path-invalid');
  check(typeof sessionID === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(sessionID), 'pi-session-invalid');
  check(Array.isArray(args) && args.every(arg => typeof arg === 'string' && !arg.includes('\0')), 'pi-arguments-invalid');
  // Only a small, value-taking set is accepted initially. Unknown options or
  // prompts cannot hide resource/session flags. Preserve accepted user values.
  const allowed = new Set(['--provider', '--model', '--thinking', '--models', '--system-prompt', '--append-system-prompt', '--tui-mode', '--name']);
  for (let i = 0; i < args.length; i++) {
    const equal = args[i].indexOf('=');
    const flag = equal < 0 ? args[i] : args[i].slice(0, equal);
    check(allowed.has(flag), 'pi-argument-unqualified');
    const value = equal < 0 ? args[++i] : args[i].slice(equal + 1);
    check(typeof value === 'string' && value.length > 0, 'pi-option-value-missing');
    if (flag === '--tui-mode') check(['regular', 'fullscreen'].includes(value), 'pi-argument-unqualified');
  }
  return [...args, '--extension', extension, '--skill', skill, '--append-system-prompt', guidance, '--session-id', sessionID];
}
