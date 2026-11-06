# Scoped hc workspace row references

The original sidebar row-to-terminal interaction now uses real node UUIDs from
`3rdr-workspace-v1`. The pasted UUID is an **app-owned pane/tab metadata ID**, not
a hc terminal selector, legacy `w1:pN` identity, PID or native-agent authority.
Terminal selectors still come only from explicit `TerminalReference` values.

Rows use the native List `itemProvider` path, the shared terminal text-drop
pipeline and existing accent drop highlight. Plain UTF-8 reference text is
available to other applications; the acceptance marker is own-process only.
A terminal pastes the UUID plus one space, without Return, using the existing
normal/bracketed-paste behavior. File-drop permission remains independent.

The source model must remain connected at its captured epoch and fresh document
revision. Destination guards recheck current exact Machine connection identity,
core ID, revision, node presence/reference and live target. Another window on the
same current machine/origin may accept the same metadata; a retired source,
changed profile, different origin/revision, foreign terminal reference or
unmarked/external drag cannot supply paste text. The drag record weakly retains
its source model; no proxy/session/terminal action is started by a provider.

## Evidence boundaries

- `run-workspace-item-drag-tests.py`: 25 policy checks per Debug/optimized mode,
  including exact payload/revision, control strings, missing nodes, replaced and
  foreign terminal references. No GUI/core/credential use.
- `/private/tmp/hc-screen-app.rrvo2dnm`: 42 current-root checks including a
  **component integration** of the real provider/terminal destination with an
  explicitly synthetic `NSDraggingInfo` and uniquely owned pasteboard. It rejects
  a nil/external source, accepts the scoped reference while File Drop is off,
  verifies exact bytes at the real owned PTY, and rejects the retired callback
  after the actual Retry reconnect. This is **not physical List dragging**.
- The receipt deliberately says `rowDragComponentIntegration=true` and
  `physicalRowDragQualified=false`. Whole UI parity/release are not inferred.

```sh
python3 -B Tests/HcBackend/run-workspace-item-drag-tests.py \
  --output /private/tmp/<owned-new-root>
```

The full current-root runner additionally needs current Debug products, the
pinned official0.1.17 archive and genuine owned active/key-window readiness.
