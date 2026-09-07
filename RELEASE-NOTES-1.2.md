# simpleRDP 1.2

## Changes

- Renamed the security override to **Disable certificate verification — Lab Use Only**,
  with an explicit warning that all server identity checks are disabled.
- Validated incoming clipboard paths, descriptor sizes and conflicts. Download
  directories are private and writes use descriptor-relative, no-follow opens
  to prevent path traversal and symlink escapes.
- Failed and partial saves preserve unsaved files and show an error. Destination
  name collisions do not overwrite existing files. Same-volume moves avoid a
  second copy; moving to another volume necessarily copies data.
- Transfers have independent cancellation tokens, directories, and offer IDs.
  Stale results cannot overwrite a newer local clipboard. Format requests are
  serialized and pending file requests expire/cancel without retaining handlers.
- Connection allocation, handshake, reconnect and teardown run on one worker.
  Cancellation uses FreeRDP's abort API; C resources are never freed after a
  timed-out thread wait. Disconnect and failed connections share cleanup.
- Single-window UI, window-close disconnect, and orderly app termination.
- Favorites in a native sidebar, collapsible connection options, native folder
  choosers, compact session toolbar, contextual file-transfer popover.
- Favorite creation retains all current settings. Host/port and share-directory
  validation give errors instead of accepting invalid input. Corrupt favorites
  are preserved instead of overwritten.
- Correct signed mouse-wheel packets, key repeat, Ctrl-click release pairing,
  modifier handling, and release of held mouse buttons on focus loss.
- Removed unused password-persistence code; passwords remain unsaved.
- Corrected framebuffer allocation/deallocation pairing and reduced filesystem
  polling from 30 Hz to 2 Hz.
- Repaired bundle creation; portable bundles validate every dependency and record
  actual architecture and deployment requirements in DependencyManifest.json.
- Added regression tests and a Command Line Tools-compatible test runner.

## Portable release requirements

- Apple Silicon (arm64).
- **macOS 26 or later for this prebuilt release.** The installed FreeRDP/WinPR
  libraries require macOS 26. Source remains targeted at macOS 13, but older
  systems need a dependency closure built for that deployment target.
- No Homebrew installation is needed to run the portable application release.
- Ad-hoc signed; not Developer ID signed or notarized. Gatekeeper may require
  approval in System Settings → Privacy & Security after the first launch attempt.