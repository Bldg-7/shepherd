# Pairing by QR code

Three runners test pairing a Mac with the iPhone and iPad app (SHPHRD-77). Each
needs a fresh output directory and the products of a macOS Debug build of the
Shepherd scheme; replace `FRESH` with a new folder name. They compile the
package's and the apps' sources themselves and never download packages.

```sh
python3 Tests/Pairing/run-tests.py --output /tmp/shepherd-pairing-FRESH \
  --products DerivedData/Build/Products/Debug
python3 Tests/Pairing/run-mac-tests.py --output /tmp/shepherd-pairing-mac-FRESH \
  --products DerivedData/Build/Products/Debug
python3 Tests/Pairing/run-device-tests.py --output /tmp/shepherd-pairing-device-FRESH \
  --products DerivedData/Build/Products/Debug
```

The test programs run under `sandbox-exec` with a profile that allows only
loopback connections and denies the socket of mDNSResponder (macOS's name lookup
service), so no name can be looked
up and nothing outside this Mac can be reached. Listeners are on 127.0.0.1.
Nothing here runs an app or the Simulator, uses the camera, the Keychain, the
Secure Enclave or LocalAuthentication (Touch ID), connects to an SSH server
(127.0.0.1:22 included) or starts one, or touches System Settings, the
pasteboard, user defaults or a real `~/.ssh`. Stand-ins take their place: a
software P-256 key for the Secure Enclave key, an in-memory secret store for the
Keychain, a stand-in resolver for DNS, and a stand-in for the Touch ID approval.
Where a test must show that nothing connected, it opens its own listener on
127.0.0.1 and counts the connections it receives.

## Shared code (`run-tests.py`)

- Core (`PairingCoreTests.swift`):
  - addresses: dotted-decimal parsing; `.local` and MagicDNS names accepted and
    refused (capitals, a trailing dot, IDN, 254 bytes,
    `evil.ts.net.example.com`, `xts.net`); the edges of the private IPv4,
    link-local and Tailscale ranges (172.15.255.255, 172.16.0.0,
    172.31.255.255, 172.32.0.0, 100.63.255.255, 100.64.0.0, 100.127.255.255,
    100.128.0.0, and 100.100.100.100 and 100.115.92.0/23, which Tailscale
    reserves and no device has) and Tailscale's IPv6 prefix;
  - one name lookup per connection that keeps only an address in the kind's
    range: public and private answers mixed, a MagicDNS name answering a public
    address or 100.100.100.100, no answer, a timeout;
  - `Machine` JSON saved before the address kind existed, and JSON saved with
    it;
  - the QR code: each address kind, a herdr session or none, the 1 KiB limit, a
    later version or an unknown address kind (the app asks for an update),
    unknown, repeated, missing and cut-short fields, the machine the device
    saves from it;
  - the messages (the device's request, the Mac's answer and the device's
    report): each read a byte at a time; the confirmation code worked out the
    same on both sides; a wrong pre-shared secret, another session, another
    Mac key and changed bytes refused; frames over 8 KiB refused;
  - the `authorized_keys` line: its text; finding a line by its key and its
    `shepherd-mobile:` marker; reading lines the way sshd does; refusing device
    keys that aren't valid P-256 public keys; the runner also reads the line with
    `ssh-keygen -l` and compares its comment and fingerprint;
  - the device key: its stored form, signing, its `ecdsa-sha2-nistp256` blob,
    public key line and fingerprint.
- SSH (`PairingSSHTests.swift`), linked with the build's Citadel and
  swift-nio-ssh: the device key as swift-nio-ssh uses it; the key offered once,
  through Citadel's custom authentication; the QR code's host key pin against
  `HostKeyFingerprint.compute`; `SSHHerdrTransport`, given an address kind,
  refusing an address outside the kind's range before it connects (127.0.0.1,
  100.100.100.100, `localhost`, a name resolving to loopback or a public
  address, a slow lookup); `MachineStore.updatePairedAddress`.
- Static checks: the transport looks the address up before it reads the
  credential or connects, and connects to the address it found.

## The Mac's side (`run-mac-tests.py`)

- Core: the address list from made-up networks (Wi-Fi alone, Wi-Fi and wired,
  bridge, VM and VPN interfaces left out, a Tailscale tunnel with and without
  its IPv6 prefix, no `.local` name, no local network), which address is
  picked by default and which after a network change; the listener's filter by kind; MagicDNS lookups
  with a stand-in resolver; the firewall's state; `authorized_keys` in a
  temporary home (created 0700 and 0600, appended, the same key not written
  twice, a linked or group-writable file or folder refused, only the matching
  line removed with the file's mode kept, a file that changed during removal
  left alone); the device list and history; the QR code drawn and read back
  with Core Image; the pairing coordinator with a device on 127.0.0.1: what a
  code holds, a new code when the choice or address changes and the old one
  refused, the two-minute refresh, the ten-minute stop, request, approval, the
  line written, answer and report, Reject, a second request for a used code,
  the 60-second and 120-second limits, a device that goes away while the Mac
  is asking, a key that can't be written, oversized and garbage frames, and 20
  failures.
  With the window on another machine (SHPHRD-110), the code shown is taken away
  and its listener closed, no new code is shown after a request is answered, and
  a request already on screen can still be approved: its Touch ID approval, its
  `authorized_keys` line and the device's report all go ahead.
- Probe: the parts of the Remote Login check that read the host key during the
  key exchange and offer no login are tested without connecting; the check is
  never run against 127.0.0.1:22.
- Views: the iPhone and iPad pages in never-shown windows, read and pressed
  through accessibility, from the list and its history to a request approved,
  rejected or failing, with Remote Login off, the firewall blocking all, herdr
  not running and no address. Nothing pressed opens System Settings, a dialog
  or the pasteboard.
  With another machine shown, Add Device… is greyed out with the reason under
  the list, the Add Device page's code is taken away and the reason shown in its
  place, and a request already on screen can still be approved, after which the
  result's Add Another Device is greyed out.
- Static checks: the row's place on Settings' first page, a listener that is
  IPv4 only and not inherited by child processes, the Remote Login check's host and
  port, and LocalAuthentication used only in `PairingApproval.swift`.
  Also, that Settings tells the iPhone and iPad page whether the window shows
  This Mac, and that the Add Device page uses that value.

## The device's side (`run-device-tests.py`)

- Device: the iOS app's `PairingClient` and `PairingFlow`, compiled for the
  Mac, with their connections sent to 127.0.0.1, against the Mac app's own
  `PairingCoordinator`: scanning and its notices, the request and confirmation
  code, approval, rejection, the Mac's timeout, expiry (decided by the Mac's
  clock; the device itself refuses a code only 30 seconds after its expiry
  time, in case the clocks differ), a used or replaced code, retries while the
  listener is busy, the device waiting up to 150 seconds for the Mac's answer,
  cancel, a first login that
  fails, scanning the same Mac again (same address, new address, another host
  key), and names resolving outside their kind's range. Nothing is saved and no
  key is kept unless the Mac approved.
- SSH: the app's SSH check refuses an address outside its kind's range before
  connecting.
- Static checks: where the scanner and pairing are wired in, and that the iOS
  app's two string catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`)
  have Korean and Japanese.
