# Agent-list cache storage checks

```sh
python3 Tests/Machines/run-agent-list-cache-tests.py --output /tmp/shepherd-agent-list-cache-FRESH
```

This runner compiles only `Machine.swift`, the new `AgentListCache` storage/DTO
contract, and its executable test. It uses a newly created owned output
location, a private HOME/module cache, and synthetic DTOs; it does not access
Keychain, SSH, herdr, the installed app, or the network.

The checks cover restart persistence, the explicit DTO allowlist (including no
raw Keychain reference or session/output/transcript fields), authoritative
empty snapshots, retaining an old DTO when a caller has a partial nested
round, connection-generation invalidation, count/string bounds, corrupt-file
preservation, and a failed atomic replacement preserving the prior file.

`AgentListCache` deliberately has no singleton and no default Application
Support location. The iOS composition owner must pass its app-owned Application
Support directory. This test-only storage contract does not enable cache files
on macOS.
