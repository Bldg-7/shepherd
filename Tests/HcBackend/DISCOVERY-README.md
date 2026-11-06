# Explicit discovery through the original CmdP switcher

The restored metadata-only sidebar previously hid canonical hc programs created
outside Shepherd if they had no app-owned view. The original Go to Agent or Pane
switcher now also offers those programs. The sidebar/toolbar information
architecture is unchanged; its empty state only explains the existing CmdP
shortcut when an unplaced running program exists.

## Identity and mutation boundaries

- Typed choices distinguish real app pane UUIDs from canonical hc terminal IDs.
  Titles, mutable names, PID/status and labels never become terminal selectors
  or native-session/browser authority.
- Discovery is limited to the current origin's canonical, unambiguous live
  records, excluding already placed same-core references and remote-qualified
  addresses. Unavailable metadata is not treated as a known missing document.
- Selection is revalidated and deferred until the actual sheet dismisses.
  Current owner/profile, core, connection epoch and exact document version must
  still match. Native terminal GET is repeated before a layout write.
- `showTerminal` appends a view to the explicitly selected workspace. If no
  workspace was selected, its new workspace and view are one CAS, including
  the known-missing-document case. It never invokes run/kill/input or resolves
  an uncertain recovery ticket from labels.
- The API can return the new tab without selecting it; Root checks newer row
  and text-input intent before requesting focus. No automatic retry/rebase of
  a conflicting or uncertain layout write is performed.
- Closing the view preserves the program; it can be explicitly discovered again.

## Evidence

- `hc-discovery.wsQaMa/policy`: canonical candidate policy, Debug/optimized.
- `hc-discovery.wsQaMa/real`: official0.1.17 real-core workspace integration adds
  single-CAS workspace/view, no-run/no-kill, no-selection-override and alias
  rejection checks. No provider login/user core/production launchd.
- `.xm9fdig6`:54 actual-root checks. On a truly missing app document (version0),
  the real native CmdP command opens the original switcher; Return selects the
  sole acknowledged out-of-app fixture program. Its workspace/view is version1;
  PID/creation/live state and an empty launch journal are verified. Actual CmdW
  confirmation closes the view but leaves that program alive. The subsequent
  native menu/title/filter/drop/reconnect audit still passes.
- Current hint/source `.4e7zeclc` passes55 and shows the existing shortcut on
  the empty board. `hc-discovery-final.7LR6tm` additionally passes macOS Release,
  iOS Debug and wiring14. `hc-original-ui-current.WsjlyC/run` passes16 original
  UI stages plus current command wiring; this does not turn its unshown-window
  component checks into physical UI approval.
- Receipts explicitly retain physical/whole-UI/release false flags. This is not
  implicit association with a provider's native conversation/session.

```sh
python3 -B Tests/HcBackend/run-switcher-candidate-tests.py \
  --output /private/tmp/<new-owned-root>
python3 -B Tests/CoreProtocol/run-real-core-tests.py --workspace-tests \
  --official-017-archive /path/to/official-0.1.17.tar.gz \
  --output /private/tmp/<another-new-owned-root>
```

The actual-root audit needs current Debug products and genuine owned active/key
readiness. `UI_RUNNING_NO_INPUT` means leave the automated window alone; request
one click only for `UI_FOCUS_REQUIRED`, and never after it has already finished.
