#!/usr/bin/env python3
"""SHPHRD-57: owned host/fake-attach PTY lifetime regression.

Compiles the production LocalTerminalSession against a verified pinned SwiftTerm
product, then operates only output-local hosts and fake attaches. No herdr,
SSH, network service, user shell, or user process is used.
"""
from pathlib import Path
import argparse, hashlib, json, os, platform, signal, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_SWIFTTERM_COMMIT = "5d14406844143538cd8f8851d2d8a67c1fe443e5"
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--swiftterm-products", type=Path, required=True,
                    help="Debug products containing SwiftTerm.swiftmodule and SwiftTerm.o")
parser.add_argument("--compile-only", action="store_true",
                    help="verify provenance and compile every source variant without starting a host or fake")
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in ("home", "tmp", "cache", "modules", "logs"):
    (out / name).mkdir(mode=0o700)
products = args.swiftterm_products.resolve()
object_file = products / "SwiftTerm.o"
module_path = products / "SwiftTerm.swiftmodule"
if not object_file.is_file() or not module_path.exists():
    raise SystemExit("missing supplied SwiftTerm object or module")

# Do not inherit user shell, provider, herdr, or network configuration.
env = {
    "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
    "HOME": str(out / "home"),
    "CFFIXED_USER_HOME": str(out / "home"),
    "TMPDIR": str(out / "tmp"),
    "CLANG_MODULE_CACHE_PATH": str(out / "cache"),
    "PATH": "/usr/bin:/bin",
}

def run(command, timeout=120):
    return subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout, check=True)

def digest(path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    hasher = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        if child.is_file():
            hasher.update(str(child.relative_to(path)).encode() + b"\0")
            hasher.update(child.read_bytes())
    return hasher.hexdigest()

def swiftterm_pin():
    resolution = json.loads((ROOT / "shepherd.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    pins = [pin for pin in resolution["pins"] if pin["identity"] == "swiftterm"]
    assert len(pins) == 1 and pins[0]["state"]["revision"] == EXPECTED_SWIFTTERM_COMMIT, pins
    checkout = ROOT / "build/SourcePackages/checkouts/SwiftTerm"
    revision = run(["git", "-C", str(checkout), "rev-parse", "HEAD"]).stdout.strip()
    clean = run(["git", "-C", str(checkout), "status", "--porcelain"]).stdout == ""
    assert revision == EXPECTED_SWIFTTERM_COMMIT and clean, (revision, clean)
    return checkout, revision

checkout, checkout_revision = swiftterm_pin()
source = (ROOT / "Shepherd/Terminal/LocalTerminalSession.swift").read_text()
assert "private static let spawnGate = OSAllocatedUnfairLock(initialState: SpawnGateState())" in source
assert "if let error = state.blockedError { return .blocked(error) }" in source
assert "process.startProcess" in source and "Self.setCloseOnExec(process.childfd)" in source
assert source.index("if let error = state.blockedError") < source.index("process.startProcess")
assert "descriptorFlags | FD_CLOEXEC" in source

sources = [
    "Shepherd/Terminal/LocalTerminalSession.swift",
    "Tests/AttachLifetime/AttachLifetimeHost.swift",
    "Tests/AttachLifetime/run-tests.py",
    "Tests/AttachLifetime/README.md",
    "shepherd.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "build/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/Pty.swift",
]
(out / "source-hashes.json").write_text(json.dumps({
    source: hashlib.sha256((ROOT / source).read_bytes()).hexdigest() for source in sources
}, indent=2) + "\n")

nio = out / "TestNIO.swift"
nio.write_text("""public struct ByteBuffer: Sendable {
    public init() {}
    public mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {}
}
""")
fake = out / "fake-attach.c"
fake.write_text(r'''#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

static int logfd = -1;
static void hung_up(int signal_number) {
    (void)signal_number;
    if (logfd >= 0) (void)write(logfd, "HUP\n", 4);
    _exit(0);
}
int main(int argc, char **argv) {
    const char *dir = getenv("ATTACH_LIFETIME_LOG_DIR");
    const char *token = argc > 1 ? argv[1] : "unknown";
    if (!dir) return 120;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s-%d.log", dir, token, getpid());
    logfd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (logfd < 0) return 121;
    struct sigaction action; memset(&action, 0, sizeof(action));
    action.sa_handler = hung_up; sigemptyset(&action.sa_mask);
    if (sigaction(SIGHUP, &action, NULL) != 0) return 122;
    sigset_t mask; sigprocmask(SIG_SETMASK, NULL, &mask);
    struct stat stdin_stat; if (fstat(STDIN_FILENO, &stdin_stat) != 0) return 123;
    dprintf(logfd, "READY pid=%d pgrp=%d sid=%d ttysid=%d hup=%d term=%d int=%d ttydev=%llu\n",
            getpid(), getpgrp(), getsid(0), tcgetsid(0), sigismember(&mask, SIGHUP),
            sigismember(&mask, SIGTERM), sigismember(&mask, SIGINT),
            (unsigned long long)stdin_stat.st_rdev);
    for (int fd = 0; fd < getdtablesize(); fd++) {
        if (fcntl(fd, F_GETFD) < 0 || !isatty(fd)) continue;
        struct stat info; if (fstat(fd, &info) == 0)
            dprintf(logfd, "TTY fd=%d dev=%llu\n", fd, (unsigned long long)info.st_rdev);
    }
    dprintf(logfd, "ENUMERATED\n");
    if (fsync(logfd) != 0) return 124;
    if (strcmp(token, "fault-first") == 0) {
        char marker[1024];
        snprintf(marker, sizeof(marker), "%s/fault-first-enumerated", dir);
        int markerfd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (markerfd < 0) return 125;
        if (write(markerfd, "ENUMERATED\n", 11) != 11 || fsync(markerfd) != 0) return 126;
        close(markerfd);
    }
    for (;;) pause();
}
''')

target = platform.machine() + "-apple-macos26.6.2"
run(["xcrun", "swiftc", "-target", target, "-emit-library", "-emit-module", "-module-name", "NIOCore", str(nio),
     "-emit-module-path", str(out / "modules/NIOCore.swiftmodule"), "-o", str(out / "modules/libNIOCore.dylib")])
run(["xcrun", "clang", "-Wall", "-Werror", str(fake), "-o", str(out / "fake-attach")])

probe = out / "SwiftTermProvenance.swift"
probe.write_text("""import SwiftTerm
@main enum SwiftTermProvenance {
    static func main() {
        print("\\(SwiftTermBuildInfo.commit ?? \"unknown\")\\t\\(SwiftTermBuildInfo.hasUncommittedChanges.map(String.init) ?? \"unknown\")")
    }
}
""")
probe_binary = out / "swiftterm-provenance"
run(["xcrun", "swiftc", "-target", target, "-swift-version", "6", "-parse-as-library", "-I", str(out / "modules"), "-I", str(products),
     "-L", str(out / "modules"), "-lNIOCore", "-Xlinker", "-rpath", "-Xlinker", str(out / "modules"), str(probe), str(object_file),
     "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "CoreText", "-o", str(probe_binary)])
probe_output = run([str(probe_binary)], timeout=10).stdout.strip().split("\t")
assert probe_output == [EXPECTED_SWIFTTERM_COMMIT, "false"], probe_output
provenance = {
    "expectedCommit": EXPECTED_SWIFTTERM_COMMIT,
    "resolvedCommit": checkout_revision,
    "checkoutClean": True,
    "buildInfoCommit": probe_output[0],
    "buildInfoHasUncommittedChanges": False,
    "objectSha256": digest(object_file),
    "moduleSha256": digest(module_path),
}
(out / "swiftterm-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")

close_on_exec = '''            if let error = Self.setCloseOnExec(process.childfd) {
                // LocalProcess closes its master asynchronously. Mark the gate
                // before this lock releases so no later fork can inherit it.
                state.blockedError = error
                return .failed(error)
            }
'''
assert source.count(close_on_exec) == 1
pre_fix_source = out / "LocalTerminalSession-pre-fix.swift"
pre_fix = source.replace(close_on_exec, "            // Private pre-fix negative: no FD_CLOEXEC.\n")
assert pre_fix.count("Self.setCloseOnExec(process.childfd)") == 0
assert pre_fix.count("process.startProcess") == 1
pre_fix_source.write_text(pre_fix)

set_close_on_exec = '''    private static func setCloseOnExec(_ fd: Int32) -> CInt? {
        var descriptorFlags: CInt
        repeat { descriptorFlags = fcntl(fd, F_GETFD) } while descriptorFlags == -1 && errno == EINTR
        guard descriptorFlags >= 0 else { return errno == 0 ? EIO : errno }

        var result: CInt
        repeat { result = fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) } while result == -1 && errno == EINTR
        return result == 0 ? nil : (errno == 0 ? EIO : errno)
    }
'''
fault_set_close_on_exec = '''    private static func setCloseOnExec(_ fd: Int32) -> CInt? {
        guard let directory = ProcessInfo.processInfo.environment["ATTACH_LIFETIME_LOG_DIR"] else { return EIO }
        let marker = URL(fileURLWithPath: directory).appendingPathComponent("fault-first-enumerated")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? String(contentsOf: marker, encoding: .utf8)) == "ENUMERATED\\n" { return EIO }
            usleep(10_000)
        }
        return ETIMEDOUT
    }
'''
assert source.count(set_close_on_exec) == 1
fault_source = out / "LocalTerminalSession-fcntl-failure.swift"
fault = source.replace(set_close_on_exec, fault_set_close_on_exec)
launch = "            process.startProcess(executable: executable, args: arguments, environment: environment)"
assert fault.count(launch) == 1
fault = fault.replace(launch, "            FaultLaunchCounter.record()\n" + launch)
fault += '''
#if os(macOS)
private enum FaultLaunchCounter {
    static func record() {
        guard let directory = ProcessInfo.processInfo.environment["ATTACH_LIFETIME_LOG_DIR"] else { return }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("fault-launch-count")
        let count = (try? String(contentsOf: path, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        try? "\\(count + 1)\\n".write(to: path, atomically: true, encoding: .utf8)
    }
}
#endif
'''
assert fault.count("FaultLaunchCounter.record()") == 1
assert fault.count("Self.setCloseOnExec(process.childfd)") == 1
fault_source.write_text(fault)

def compile_host(session_source, output):
    run(["xcrun", "swiftc", "-target", target, "-swift-version", "6", "-parse-as-library",
         "-I", str(out / "modules"), "-I", str(products), "-L", str(out / "modules"), "-lNIOCore", "-Xlinker", "-rpath", "-Xlinker", str(out / "modules"),
         str(session_source), "Tests/AttachLifetime/AttachLifetimeHost.swift", str(object_file),
         "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "CoreText", "-o", str(output)], timeout=180)

# Compile every source variant before any host/fake runtime starts.
host = out / "attach-lifetime-host"
pre_fix_host = out / "attach-lifetime-pre-fix-host"
fault_host = out / "attach-lifetime-fcntl-failure-host"
compile_host(ROOT / "Shepherd/Terminal/LocalTerminalSession.swift", host)
compile_host(pre_fix_source, pre_fix_host)
compile_host(fault_source, fault_host)
(out / "compile-preflight.json").write_text(json.dumps({
    "passed": True,
    "normalSource": str(ROOT / "Shepherd/Terminal/LocalTerminalSession.swift"),
    "preFixSource": str(pre_fix_source),
    "fcntlFailureSource": str(fault_source),
    "swiftTermProvenance": provenance,
}, indent=2) + "\n")
if args.compile_only:
    print("PASS verified SwiftTerm provenance and compiled normal, pre-fix, and fcntl-failure hosts; no host or fake executed")
    sys.exit(0)

def token(path):
    return path.stem.rsplit("-", 1)[0]

def records(log_dir):
    result = {}
    for path in log_dir.glob("*.log"):
        lines = path.read_text().splitlines()
        if not lines or not lines[0].startswith("READY ") or lines.count("ENUMERATED") != 1:
            continue
        enumerated = lines.index("ENUMERATED")
        if any(line.startswith("TTY ") for line in lines[enumerated + 1:]):
            raise AssertionError(f"TTY record after ENUMERATED: {path}")
        fields = dict(field.split("=", 1) for field in lines[0].split()[1:])
        result[path] = (fields, lines[1:])
    return result

def assert_expected_records(log_dir, found, expected_tokens):
    all_logs = list(log_dir.glob("*.log"))
    assert len(all_logs) == len(found), (all_logs, found)
    assert {token(path) for path in found} == set(expected_tokens), list(found)

def wait_for(log_dir, expected_tokens, want_hups=False, timeout=3):
    deadline = time.monotonic() + timeout
    expected_count = len(expected_tokens)
    while time.monotonic() < deadline:
        found = records(log_dir)
        if len(found) == expected_count and (not want_hups or all("HUP" in lines for _, lines in found.values())):
            assert_expected_records(log_dir, found, expected_tokens)
            return found
        time.sleep(0.02)
    raise AssertionError(f"expected completed fake records: {expected_tokens}" + (" with SIGHUP" if want_hups else ""))

def validate(found, expected_tokens, no_cross_owned_master=True):
    assert len(found) == len(expected_tokens)
    for fields, tty_lines in found.values():
        pid = int(fields["pid"])
        assert pid > 0 and int(fields["pgrp"]) == pid and int(fields["sid"]) == pid
        assert int(fields["ttysid"]) == pid
        assert fields["hup"] == fields["term"] == fields["int"] == "0"
        devices = {line.split("dev=", 1)[1] for line in tty_lines if line.startswith("TTY ")}
        if no_cross_owned_master:
            assert devices == {fields["ttydev"]}, (fields, tty_lines)

def start_host(binary, mode, log_dir):
    host_env = dict(env, ATTACH_LIFETIME_FAKE=str(out / "fake-attach"), ATTACH_LIFETIME_LOG_DIR=str(log_dir))
    return subprocess.Popen([str(binary), mode], cwd=ROOT, env=host_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def continue_stop(process, log_dir):
    (log_dir / "host-continue").write_text("ENUMERATED\n")
    stdout, stderr = process.communicate(timeout=10)
    assert process.returncode == 0 and stdout.endswith("STOPPED\n"), stderr

session_tokens = {f"session-{number}" for number in range(8)}
identities = []
for run_number in range(20):
    log_dir = out / "logs" / f"kill-{run_number}"
    log_dir.mkdir()
    process = start_host(host, "hold", log_dir)
    found = wait_for(log_dir, session_tokens)
    validate(found, session_tokens)
    # Capture the owned host's PID/start identity/process group immediately
    # before the only SIGKILL this test sends; never signal a child by PID.
    identity = subprocess.run(["ps", "-o", "pid=,lstart=,pgid=", "-p", str(process.pid)], env=env, text=True, capture_output=True, check=True).stdout.strip()
    assert identity.startswith(str(process.pid)), identity
    identities.append(identity)
    os.kill(process.pid, signal.SIGKILL)
    process.wait(timeout=3)
    validate(wait_for(log_dir, session_tokens, want_hups=True), session_tokens)

# The host observes its known direct fake PIDs only with waitid(...WNOWAIT).
# Its success means LocalTerminalSession's own reaper consumed each child.
stop_dir = out / "logs" / "stop"
stop_dir.mkdir()
stopped = start_host(host, "stop", stop_dir)
validate(wait_for(stop_dir, session_tokens), session_tokens)
continue_stop(stopped, stop_dir)
validate(wait_for(stop_dir, session_tokens, want_hups=True), session_tokens)

# Removing FD_CLOEXEC only is the controlled private negative.
negative_dir = out / "logs" / "pre-fix-negative"
negative_dir.mkdir()
negative = start_host(pre_fix_host, "stop", negative_dir)
negative_records = wait_for(negative_dir, session_tokens)
validate(negative_records, session_tokens, no_cross_owned_master=False)
assert any(
    len({line.split("dev=", 1)[1] for line in tty_lines if line.startswith("TTY ")}) > 1
    for _, tty_lines in negative_records.values()
), "pre-fix fixture did not expose an inherited PTY master"
continue_stop(negative, negative_dir)
validate(wait_for(negative_dir, session_tokens, want_hups=True), session_tokens, no_cross_owned_master=False)

# The first fake's marker is fsync-backed and produced after its completed
# descriptor snapshot. The output-only fcntl helper waits for it before EIO.
fault_dir = out / "logs" / "fcntl-failure"
fault_dir.mkdir()
fault_process = start_host(fault_host, "fault", fault_dir)
fault_records = wait_for(fault_dir, {"fault-first"}, want_hups=True)
validate(fault_records, {"fault-first"})
stdout, stderr = fault_process.communicate(timeout=10)
assert fault_process.returncode == 0 and stdout == "FAULT GATE BLOCKED\n", stderr
assert not list(fault_dir.glob("fault-second-*.log")), "blocked gate permitted a second fork"
assert (fault_dir / "fault-launch-count").read_text() == "1\n", "blocked gate reached startProcess"

(out / "host-identities.json").write_text(json.dumps(identities, indent=2) + "\n")
(out / "validation.json").write_text(json.dumps({
    "passed": True,
    "actualProductionSeam": "Shepherd/Terminal/LocalTerminalSession.swift",
    "swiftTermProvenance": provenance,
    "ownedFakeAttach": True,
    "concurrentSessions": 8,
    "runs": 20,
    "hostKillCleanupSeconds": 3,
    "fcntlFailureGate": True,
    "network": False,
    "realHerdr": False,
    "realSSH": False,
    "userProcessesSignalled": False,
}, indent=2) + "\n")
print("PASS verified SwiftTerm provenance; 8 concurrent LocalTerminalSession attaches x20; completed PTY snapshots; owned-host SIGKILL SIGHUP cleanup; production reaper and sticky fcntl-failure spawn gate")
