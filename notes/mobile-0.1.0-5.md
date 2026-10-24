# hrdrhrdrhrdr — TestFlight 0.1.0 (5)

One build for iPhone and iPad, requiring iOS/iPadOS 26 or newer.

## Changes

- The pane header reserves enough width for its full localized status badge. Status changes no longer resize the badge, and longer titles yield space instead of truncating the badge.
- Toolbar actions remain intrinsic-sized icon controls. The native inline title uses the remaining space and keeps normal back navigation and accessibility behavior.
- When no captured conversation is available yet, or the initial connection to the conversation reader fails, the app now explains why it is showing Screen rather than silently hiding the conversation controls.

## What to test

- Open panes with short and long titles on iPhone and iPad, including narrow iPad windows and larger text settings. The status label should remain complete while the title truncates as needed.
- Switch between idle, working, blocked and done states; the badge should keep a stable width.
- Verify Korean and Japanese status labels and the native Back button.
- With macOS 0.7.1, enable Show Conversations on iPhone and iPad and start a new Pi tab on This Mac using OpenAI with ChatGPT sign-in. Send a message and open the pane on the paired device to verify Conversation / Screen switching.

## Scope

The OpenAI capture-path correction is in macOS 0.7.1; updating this mobile app alone does not update the Mac. Mobile 0.1.0(4) is already compatible with that Mac-side fix, while this build adds the header and state-explanation improvements. Re-pairing is not required. Existing Pi sessions keep their original extension until they end; the app does not restart them.

API-key authentication, custom endpoints and nested herdr machines remain outside this conversation-capture scope. Conversation content remains bounded and memory-only.
