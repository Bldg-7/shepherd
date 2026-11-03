#!/usr/bin/env python3
"""Build/qualify a PREPARED scratch hc checkout; never install or run a user core.

Source preparation is explicit (see README). Require the exact recipe and patch,
use private Cargo/Zig caches and HOME, retain logs and publish a local test receipt
only after every build/test succeeds. This receipt is provenance, not a signature.
"""
from pathlib import Path
import argparse, hashlib, json, platform, re, shlex, subprocess, tarfile

HERE = Path(__file__).resolve().parent
RECIPE = HERE / "recipe.json"
r = json.loads(RECIPE.read_text())
p = argparse.ArgumentParser()
p.add_argument("--workspace", type=Path, required=True, help="owned scratch directory containing core/")
p.add_argument("--output", type=Path, required=True, help="fresh qualification/artifact directory")
p.add_argument("--cargo", type=Path, required=True, help="actual toolchain cargo, not a rustup proxy")
p.add_argument("--zig", type=Path, required=True)
a = p.parse_args()
root, out, cargo, zig = a.workspace.resolve(), a.output.resolve(), a.cargo.resolve(), a.zig.resolve()
core = root / "core"; ghostty = core / "vendor/ghostty"
def require(condition, message):
    if not condition: raise ValueError(message)

require(platform.system() == "Darwin" and platform.machine() == "arm64", "macOS ARM64 required")

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        while b := f.read(1 << 20): h.update(b)
    return h.hexdigest()

def git(path, *args):
    return subprocess.check_output(["/usr/bin/git", "-C", str(path), *args], text=True).strip()

def verify_sources():
    require(git(core, "rev-parse", "HEAD") == r["coreCommit"], "wrong core commit")
    require(git(ghostty, "rev-parse", "HEAD") == r["ghosttyCommit"], "wrong Ghostty commit")
    require(git(core, "diff", "HEAD", "--name-only") == "vendor/ghostty", "unexpected core edits")
    require(git(ghostty, "diff", "HEAD", "--name-only") == "src/terminal/formatter.zig", "unexpected Ghostty edits")
    for repo in (core, ghostty):
        require(not git(repo, "ls-files", "--others", "--exclude-standard"), "untracked source/configuration files")
    require(digest(core / "Cargo.lock") == r["cargoLockSHA256"], "lockfile changed")
    require(digest(HERE / r["patchFile"]) == r["patchSHA256"], "patch changed")
    require(digest(ghostty / "src/terminal/formatter.zig") == r["patchedFormatterSHA256"], "formatter changed")

verify_sources()
require(digest(zig) == r["zigBinarySHA256"], "use the pinned Zig distribution")
subprocess.run(["/usr/bin/git", "-C", str(ghostty), "apply", "--reverse", "--check", str(HERE / r["patchFile"])], check=True)
rustc = cargo.parent / "rustc"
require(cargo.is_file() and rustc.is_file(), "actual Cargo/Rust executables required")
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ["home", "tmp", "cargo-home", "zig-global-cache", "state", "config"]:
    (root / name).mkdir(mode=0o700, exist_ok=True)
wrapper = out / "zig-wrapper"
wrapper.write_text("#!/bin/sh\nset -eu\nif [ \"${1:-}\" = build ]; then\n shift\n exec " + shlex.quote(str(zig)) + " build " +
                   " ".join(map(shlex.quote, r["zigBuildOptions"])) + " \"$@\"\nfi\nexec " + shlex.quote(str(zig)) + " \"$@\"\n")
wrapper.chmod(0o700)
env = {"PATH": str(cargo.parent) + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root / "home"),
       "TMPDIR": str(root / "tmp"), "CARGO_HOME": str(root / "cargo-home"), "CARGO_TARGET_DIR": str(root / "target"),
       "CARGO_BUILD_JOBS": "4", "RUSTC": str(rustc), "ZIG": str(wrapper),
       "ZIG_GLOBAL_CACHE_DIR": str(root / "zig-global-cache"), "XDG_STATE_HOME": str(root / "state"),
       "XDG_CONFIG_HOME": str(root / "config"), "HC_SESSION": "owned-backport", "CI": "1", "DO_NOT_TRACK": "1"}
toolchain = {"rustc": subprocess.check_output([str(rustc), "--version"], env=env, text=True).strip(),
             "cargo": subprocess.check_output([str(cargo), "--version"], env=env, text=True).strip(),
             "zig": subprocess.check_output([str(zig), "version"], env=env, text=True).strip(),
             "rustcSHA256": digest(rustc), "cargoSHA256": digest(cargo), "zigSHA256": digest(zig)}
require(toolchain["zig"] == r["zigVersion"], "wrong Zig version")
require(toolchain["rustc"].split()[1] == "1.95.0", "use upstream CI Rust 1.95.0 in an isolated toolchain")
(out / "toolchain.json").write_text(json.dumps(toolchain, indent=2))
checks = {}

def stage(name, cwd, args, timeout):
    print(name + ": start", flush=True)
    log = out / (name + ".log")
    with log.open("wb") as f:
        result = subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    passed = result.returncode == 0
    count = None
    if name in {"formatter-tests", "rust-vt-tests", "rust-core-unit-tests"}:
        pattern = r"([0-9]+)/[0-9]+ tests passed" if name == "formatter-tests" else r"test result: ok\. ([0-9]+) passed"
        counts = re.findall(pattern, log.read_text())
        # A core unit test runs an isolated child test binary; its summary
        # precedes the outer harness summary. Record the latter, not the child.
        count = int(counts[-1]) if counts else 0
        passed = passed and count > 0
    checks[name] = {"passed": passed, "testCount": count, "logSHA256": digest(log), "command": list(map(str, args))}
    (out / "checks.json").write_text(json.dumps(checks, indent=2))
    if not passed: raise RuntimeError(name + " failed or executed zero tests: " + str(log))
    print(name + ": passed", flush=True)

stage("formatter-format", ghostty, [zig, "fmt", "--check", "src/terminal/formatter.zig"], 30)
stage("formatter-tests", ghostty, [wrapper, "build", "test-lib-vt", "-Demit-lib-vt", "-Dtest-filter=formatter",
                                   "--cache-dir", root / "formatter-test-cache", "--prefix", root / "formatter-tests", "--summary", "all"], 1200)
stage("core-build", core, [cargo, "build", "--locked", "--release", "-p", "herdr-core"], 1200)
stage("rust-vt-tests", core, [cargo, "test", "--locked", "--release", "-p", "ghostty-vt", "--lib"], 1200)
stage("rust-core-unit-tests", core, [cargo, "test", "--locked", "--release", "-p", "herdr-core", "--lib", "--", "--test-threads=1"], 1200)
# Source must not have changed behind the build.
verify_sources()
binary = root / "target/release/herdr-core"
receipt = {"schema": 1, "variant": r["id"], "version": r["version"], "officialRelease": False,
           "recipeSHA256": digest(RECIPE), "buildScriptSHA256": digest(Path(__file__).resolve()), "coreCommit": r["coreCommit"], "ghosttyCommit": r["ghosttyCommit"],
           "upstreamCommit": r["upstreamCommit"], "patchSHA256": r["patchSHA256"],
           "patchedFormatterSHA256": r["patchedFormatterSHA256"], "cargoLockSHA256": r["cargoLockSHA256"],
           "binarySHA256": digest(binary), "toolchain": toolchain, "checks": checks}
provenance = out / "SOURCE-PROVENANCE.json"
provenance.write_text(json.dumps(receipt, indent=2))
archive = out / r["archiveName"]
with tarfile.open(archive, "w:gz") as package:
    for path, name in [(binary, "herdr-core"), (core / "LICENSE", "LICENSE"),
                       (core / "crates/herdr-core/THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES"),
                       (HERE / "GHOSTTY-LICENSE", "GHOSTTY-LICENSE"), (HERE / r["patchFile"], "BACKPORT.patch"),
                       (provenance, "SOURCE-PROVENANCE.json")]:
        package.add(path, arcname=name, recursive=False)
receipt.update(archive=r["archiveName"], archiveSHA256=digest(archive))
(out / "build-receipt.json").write_text(json.dumps(receipt, indent=2))
print("QUALIFIED BUILD RECEIPT: " + str(out / "build-receipt.json"), flush=True)
