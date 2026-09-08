# simpleRDP

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A simple, native macOS RDP client written in **Swift / SwiftUI**, built on top of
[FreeRDP](https://www.freerdp.com/) (the mature open-source C implementation of
the RDP protocol). The app is a thin native shell — UI, favorites, macOS
clipboard/Finder integration — while libfreerdp does the protocol heavy lifting.

## Download

A pre-compiled, portable release for **Apple Silicon Macs** is available for download here:
[simpleRDP Releases](https://github.com/CesarR70/simpleRDP/releases)

## Version 1.3

See [release notes](RELEASE-NOTES-1.3.md) for session tabs and destination-first file downloads.

## What it does

- **Connect to Windows RDP endpoints** (Windows 10/11, Server) and **xrdp** Linux
  hosts, with an endpoint-kind hint (Auto / Windows / xrdp) that adjusts the
  security negotiation strategy (NLA-friendly vs. TLS-first).
- **Session tabs:** connect to multiple machines in one window; **+** or **⌘T**
  opens another connection. Background sessions remain connected.
- **Clipboard redirection (CLIPRDR):** remote text automatically copies to the Mac
  from the selected tab. A new Mac copy is offered only to the selected connected
  session; paste remotely with Ctrl+V. Mac files stream without a duplicate cache.
- **Explicit remote file downloads:** copy remote files, click **Download Remote
  Files…**, then choose a destination. No file contents download before approval,
  and downloaded files never overwrite the Mac clipboard. Private temporary files
  live inside the selected destination, not the application cache.
- **Resolution control:** pick the starting resolution *before* connecting
  (saved per favorite), and **change resolution live** mid-session from the
  toolbar menu (very handy, this re-negotiates via a reconnect without
  dropping the session).
- **Favorites:** save servers with custom names, endpoint kind, share folder,
  certificate trust flag, and preferred resolution. Passwords are **never**
  persisted — you type them per connect.
- **Optional folder redirection (rdpdr):** share a Mac folder with the session
  (appears as a drive on Windows; under `~/thinclient_drives` on xrdp).
- **Input:** keyboard/mouse captured in the view; ⌘-shortcuts stay on the Mac;
  Ctrl-click = right-click.
- Status bar shows connection state, live resolution, and clipboard download
  progress (with a cancel button for accidental large copies).

## Running

1. Launch the app, enter `host` or `host:port`, pick endpoint kind, optionally
   a share folder, and the starting resolution.
2. Type the password (never saved), click **Connect**.
3. Save the server as a **favorite**, then select it in the left sidebar to fill the form later.
4. While connected, use the **Display** menu in the session toolbar to
   resize live; ⌘-shortcuts stay local; Ctrl-click = right-click.
5. Open another connection with **+** or **⌘T**. Switch tabs without disconnecting.
6. To receive remote files, copy them remotely and use **Download Remote Files…**
   to choose where to save them. The prompt is a toolbar action, not a modal alert.

## Security and clipboard notes

- **Disable certificate verification — Lab Use Only** disables all certificate
  identity checks. Leave it off outside an explicitly trusted lab network.
- One shared clipboard coordinator prevents background tabs from overwriting the
  Mac clipboard or receiving another session's copied text. Switching tabs alone
  never replays stale clipboard contents. Copy locally again to send the same items
  to a different session. Text copied before switching away is not replayed on return.
- Accepted downloads use private `.simpleRDP-download-<UUID>` directories inside
  the chosen destination. Workers clean partial files on cancellation, and successful
  saves remove staging directories. Final save failures preserve files and report
  their recovery location. A crash/forced quit can leave a hidden partial directory;
  use Finder **⌘⇧.** to reveal it and delete it manually.
- Remote clipboard changes cancel unfinished downloads rather than mix file versions.
- No new files are written to `~/Library/Caches/simpleRDP/RemoteClipboard/`.
  Leftover caches from older versions can be removed after quitting those versions.
- Mac → remote file clipboard currently supports regular files, not folders.

## How it works (architecture in a nutshell)

```
SwiftUI window / connection tabs
   │
   └── SessionStore + shared ClipboardCoordinator
       └── SessionViewModel per tab (MainActor ObservableObject)
           └── RDPSession (worker owner)
               ├── FreeRDP instance, event loop, settings, deferred resize
               ├── ClipboardChannel + RemoteInput
               └── Framebuffer (lock-protected latest frame)

C callbacks find their Swift targets through instance → object registries.
Only the selected desktop is rendered; background sessions keep receiving updates.
```

- **FreeRDP interop** goes through the `CFreeRDP` SPM `systemLibrary` target:
  a small `shim.h` re-exposes the headers and provides nillable inline helpers
  for the GDI primary buffer.
- **Event loop** runs on a dedicated thread; a locked abort handle and worker-owned cleanup protect pointer
  lifetime; UI updates hop to `MainActor` via an `AsyncStream`.
- **Channels:** CLIPRDR (clipboard text/files) + RDPDR (share folder) are
  loaded from the `LoadChannels` callback — required timing for FreeRDP.
- **Resize** requests are queued to the event-loop thread and applied via
  `freerdp_reconnect`, keeping the resize on the only thread that drives it.

## Building from source

This is a Swift Package Manager project — no Xcode IDE required (VS Code with
the Swift extension works; a `simpleRDP.code-workspace` file is included).

```bash
git clone https://github.com/CesarR70/simpleRDP.git
cd simpleRDP
brew install freerdp pkg-config

# Build (debug or release)
./Scripts/build.sh release

# Assemble the double-clickable .app (ad-hoc signed for local use)
./Scripts/bundle.sh release

open simpleRDP.app
```

`Scripts/build.sh` wraps `swift build` and sanity-checks the FreeRDP
dependency via pkg-config so a missing/broken install fails with a friendly
message instead of a wall of clang errors. `Package.swift` resolves FreeRDP
through pkg-config **plus** arch-conditional Homebrew prefix flags, so even
SourceKit-LSP in VS Code can build without environment shims.

## Source build requirements

- macOS 13 (Ventura) or newer **and dependencies built for the target OS**; the current portable release requires macOS 26+
- [Xcode Command Line Tools](https://developer.apple.com/download/all/) (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- FreeRDP + pkg-config:

```bash
brew install freerdp pkg-config
```

An Apple Silicon Mac (arm64) is the tested build target; the package also has
Intel-friendly fallbacks via arch-conditional Homebrew prefixes.

## Tests

```bash
./Scripts/test.sh   # regression suite; works with Command Line Tools alone
swift test          # same test cases via XCTest, with full Xcode selected
```

Clipboard paths and symlinks, failed saves, name collisions, ports, wheel
encoding, favorite preservation, cancellation, and lifecycle cleanup are covered.
Live Windows/xrdp interoperability and visual/accessibility testing remain manual.

## Gatekeeper notes

The app is **ad-hoc signed** (`codesign --sign -`). That's fine for local use,
but it means Gatekeeper will flag the downloaded app — this is normal for
unsigned/ad-hoc-signed macOS software, **not** a bug:

- **Option 1:** Right-click the app → **Open** → confirm.
- **Option 2:** Remove the quarantine attribute:

```bash
xattr -dr com.apple.quarantine /path/to/simpleRDP.app
```

**Portable builds:** to make the release `.app` work on machines **without**
Homebrew, vendor the FreeRDP dylib closure into the bundle:

```bash
VENDOR_DYLIBS=1 ./Scripts/bundle.sh release
ditto -c -k --keepParent simpleRDP.app simpleRDP.zip
```

This copies every Homebrew dylib the app needs into `Contents/Frameworks` and
rewrites load paths to `@rpath` (verified by the script). The pre-built binary
attached to GitHub Releases is produced this way.

## Project layout

```
Package.swift          SPM manifest (FreeRDP via pkg-config + brew prefix flags)
Sources/CFreeRDP/      systemLibrary shim around libfreerdp/winpr headers
Sources/simpleRDP/     the Swift app (UI + session + framebuffer + clipboard)
Scripts/build.sh       swift build wrapper with dependency sanity checks
Scripts/bundle.sh      assemble + ad-hoc-sign simpleRDP.app
Scripts/vendor_dylibs.sh  make the .app portable (bundle dylib closure)
Resources/             app icon (.icns)
```

## Roadmap / out of scope (v1)

Not currently included: certificate pinning prompt UI, image clipboard,
audio/printer redirection, multi-monitor, RemoteApp, RD Gateway, session
recording.

## License

Licensed under the [Apache License 2.0](LICENSE) — the same license as
FreeRDP itself, keeping the dependency story simple.