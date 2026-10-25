# Mobile agent-list cache coordinator harness

```sh
python3 Tests/Mobile/run-agent-list-cache-coordinator-harness.py --output /owned/output
```

This is an executable controlled-timing harness, not a source-substring check.
It compiles and runs the production `MobileAgentListCache`,
`MobileBoardLoadCoordinator`, `AgentListCache`, `MachineStore`, and the private
`RetiredCacheIdentities` journal. It uses an owned output directory, an
isolated per-run `UserDefaults` suite for `MachineStore`, and an in-memory
`MachineSecretStore`; it never opens Keychain, a real machine, network, SSH,
or a simulator.

The private harness module supplies only controllable monitor publication
values/registry and lightweight Agent/Tab/Workspace fixture values. Its timing
hooks suspend actual coordinator load, pre-store, and eviction operations;
the cache actor and journal still read/write the owned disk files. Cases cover:

- Board cache hydration before lease/refresh work begins;
- nested-before-host merge and actor recreation;
- delayed disk load and delayed old writer freshness guards (including a held
  old candidate negative control);
- ordinary and paired-address A→B→A fresh cache recovery;
- process loss while edit/removal eviction is delayed, without retired disk
  resurrection;
- journal persistence failure rejecting a replacement credential before its
  write;
- bounded burst coalescing plus explicit flush; and
- successful empty publication and failed/no-publication retention.

It does not run a SwiftUI device interaction. Cached rows' non-navigation
behavior remains covered by the Board composition/source-contract runner and
simulator-target compilation; this harness proves the view-independent Board
entry ordering with executable lease/refresh closures.
