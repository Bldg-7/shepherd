# Bounded installer fixtures — not a user installation

`run-installer-fixture-tests.py` executes a separately supplied, SHA-256-pinned
snapshot of the official installer. The selected binary is still official hc
0.1.17, verified by the existing artifact loader. It never invokes the installer
against the user's HOME, executable, package manager or service domain.

## Exercised boundary

- A `file://` mirror supplies the manifest/archive; all network is denied and an
  owned loopback denial canary must pass. This is not HTTP/TLS delivery evidence.
- Fresh installation emits the exact official executable and a relative `hc`
  alias. The installed alias reports 0.1.17; no core socket is created.
- An unrelated executable named `hc` is preserved byte-for-byte.
- A checksum-negative download creates neither executable nor alias; installer
  temporary directories are retired on success and failure.
- Children cannot read the real home, write outside the owned output root or
  execute `launchctl`, `find`, `osascript` or `security`.

Darwin's bare `mktemp -d` used by this installer selected the account's system
per-user temp directory despite the fixture's `TMPDIR`. The initial attempt was
correctly denied, not allowed to write outside the fixture. For these component
fixtures only, a disclosed PATH wrapper delegates to the real `/usr/bin/mktemp`
with an explicit owned template. The official installer bytes are not rewritten.
**Native default-temp behavior, existing-install update/handover, package-manager
ownership, production launchd/app-quit survival and release remain unqualified.**

## Reproduce

Supply an inspected installer snapshot and its independently recorded SHA-256.
A changed download must not silently become the test's approved installer.

```sh
python3 -B Tests/HcBackend/run-installer-fixture-tests.py \
  --installer /path/to/inspected-install.sh \
  --installer-sha256 <recorded-sha256> \
  --official-017-archive /path/to/official-0.1.17.tar.gz \
  --output /private/tmp/<owned-output-root-that-does-not-exist>
```

The inspected snapshot used here has SHA-256
`4d052d135b76140a6e1ea998985fe9a92b639a8551a8f6d970fcf2226de09f90`.
Evidence: `/private/tmp/hc-private-installer-owned-temp.S9KR8j/run`, 15 checks.
The earlier denial is retained at `hc-private-installer.DTmusc/run`.
Reports retain explicit false qualification flags rather than turning a fixture
pass into installer execution approval, service qualification or deployment.
