# simpleRDP

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A simple, native macOS RDP client written in **Swift / SwiftUI**, built on top of
[FreeRDP](https://www.freerdp.com/) (the mature open-source C implementation of
the RDP protocol). The app is a thin native shell — UI, favorites, macOS
clipboard/Finder integration — while libfreerdp does the protocol heavy lifting.

## Download

A pre-compiled, portable release for **Apple Silicon Macs** is available for download here:
[simpleRDP Releases](https://github.com/CesarR70/simpleRDP/releases)

## Version 1.2

See [release notes](RELEASE-NOTES-1.2.md) for safety fixes & the native UI refresh

## What it does

- **Connect to Windows RDP endpoints** (Windows 10/11, Server) and **xrdp** Linux
  hosts, with an endpoint-kind hint (Auto / Windows / xrdp) that adjusts the
  security negotiation strategy (NLA-friendly vs. TLS-first).
- **Clipboard redirection (CLIPRDR):** text syncs both directions; **file
  copy/paste works in both directions** as well — Mac → server streams file
  contents over the clipboard channel, server → Mac downloads into
  `~/Library/Caches/simpleRDP/RemoteClipboard/` with live progress, then moves
  the staged files out to a folder you pick. Pasting into Finder with **⌥⌘V**
  ("Move Item Here") also moves them out of the cache; plain ⌘V always
  copies (Finder decides, not the app). (On xrdp, server-side materializes
  via `~/thinclient_drives`.)
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
4. While connected, use the **Resolution** menu in the session toolbar to
   resize live; ⌘-shortcuts stay local; Ctrl-click = right-click.

## Security and clipboard notes

- **Disable certificate verification — Lab Use Only** disables all certificate
  identity checks. Leave it off outside an explicitly trusted lab network.
- One window/session intentionally owns clipboard synchronization.
- Remote downloads use private per-transfer cache directories. Cancelled workers
  clean their own files; completed files are retired on replacement/quit, and
  abandoned directories from crashes are removed on the next application start.
- Save failures preserve unsaved staged files and show an error.
- Same-volume moves avoid a second copy. Cross-volume moves must copy bytes;
  plain Finder ⌘V also copies. Finder ⌥⌘V moves.
- Mac → remote file clipboard currently supports regular files, not folders.

## How it works (architecture in a nutshell)

```
SwiftUI (ConnectView / SessionView)
   │
   ├── SessionViewModel (@MainActor ObservableObject)
   │
   ├── RDPSession (worker owner) ── owns the freerdp* instance, event-loop thread,
   │   └─ settings, clipboard + input channels, deferred resize requests
   │
   ├── Framebuffer ── lock-protected latest frame, fed by EndPaint callback
   │   (polled at ~30 Hz; copies only when changed)
   │
   └── C callbacks (BeginPaint / EndPaint / DesktopResize / cert verify)
       find their Swift targets via small instance→object registries
       (annotated @convention(c) maps can't capture Swift context)
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