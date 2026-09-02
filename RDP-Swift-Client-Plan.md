# macOS Swift RDP Client — Development Planning & Action Items

> **Status:** Brainstorming / architecture doc. This is a scoping document to guide
> actual development on a MacBook using **VSCode + Swift extension + Xcode Command
> Line Tools** (no full Xcode IDE). It is intentionally not the implementation.

---

## 1. Goals & Scope

**Primary goal:** A simple native macOS RDP client written in Swift that can:

1. Connect to **standard Windows RDP endpoints** (Windows 10/11, Windows Server).
2. Connect to **Linux workstations running xrdp**.
3. Provide **clipboard-based file copy/paste** between the Mac and the remote host
   over RDP's native clipboard channel (**CLIPRDR**), with special handling for the
   xrdp case.
4. Offer a **simple UI**: enter a server IP, connect, and **save/favorite servers
   with custom names**.

**Confirmed decisions (from scoping):**

| Decision | Choice |
|---|---|
| Clipboard transport | **CLIPRDR** (RDP's native clipboard virtual channel) |
| Clipboard payload for v1 | **Files** (clipboard-based file copy/paste) |
| Packaging | **Real, double-clickable `.app` bundle** (built without the Xcode IDE) |

**Explicitly out of scope for v1** (candidates for later): text/image clipboard,
audio redirection, printer redirection, multi-monitor, RemoteApp, gateway/RD
Gateway support, session recording.

---

## 2. Key Technical Reality Check (read this first)

### 2.1 You are not going to implement RDP from scratch

RDP is a large, complex protocol (bitmap codecs, virtual channels, security
layers, NLA/CredSSP, etc.). Writing it natively in Swift is a multi-year effort.

**Recommendation: wrap [FreeRDP](https://github.com/FreeRDP/FreeRDP) (v3.x).**
FreeRDP is the mature, open-source C implementation used by most third-party RDP
clients. It already supports:

- Windows endpoints **and** xrdp (same protocol; xrdp is RDP-compliant).
- The `cliprdr` (CLIPRDR) clipboard channel — **including file transfer**.
- The `rdpdr` drive-redirection channel (relevant to the xrdp `thinclient_drives`
  discussion below).
- NLA/CredSSP, TLS, bitmap/RemoteFX/H.264 codecs, etc.

Your Swift app becomes a **thin native shell** (UI, favorites, lifecycle, macOS
clipboard/Finder integration) around **libfreerdp** doing the protocol work.

### 2.2 Clipboard vs. `thinclient_drives` — clearing up the conflation

The original idea was to use xrdp's `thinclient_drives` directory "to accept
clipboard items." Two different RDP features were being merged here:

| Feature | RDP channel | What it is | Where `thinclient_drives` fits |
|---|---|---|---|
| **Clipboard** (text/image/**files**) | `cliprdr` (CLIPRDR) | Cmd-C / Cmd-V style sync, incl. copy-file-paste-file | Not the interface — but see below |
| **Drive redirection** | `rdpdr` | Mounts a client folder as a "drive" on the server | `thinclient_drives` is xrdp's mount point for this |

**How they actually relate on xrdp (the important nuance):**

- On xrdp, virtual channels are handled by **`chansrv`**, which exposes redirected
  content through a **FUSE mount** rooted at `~/thinclient_drives/` (typically
  `~/thinclient_drives/.clipboard/` for clipboard file transfers and
  `~/thinclient_drives/<DRIVE>/` for redirected drives).
- So when you copy a **file** on the Mac and paste it in the xrdp session, the
  bytes travel over **CLIPRDR**, but on the server side xrdp materializes them as
  files the user reads out of the **`thinclient_drives` FUSE tree**. The directory
  is the *plumbing/delivery point*, **not** the API you code against.

**Bottom line for the client:** You implement **CLIPRDR file transfer** (FreeRDP's
`cliprdr` channel, `CB_FILECONTENTS_REQUEST/RESPONSE`, `FILEDESCRIPTOR` format).
You do **not** write to `thinclient_drives` from the client — xrdp's server side
does. Your client's job is to advertise/serve the file list and stream file
contents on request. See §8.

> ⚠️ **xrdp caveat:** clipboard *file* transfer support in xrdp depends on the xrdp
> version and on `chansrv` being built with FUSE support. Text clipboard is broadly
> supported; **file** clipboard is newer and more fragile. Plan to test against the
> specific xrdp version your Linux workstations run, and keep a fallback (e.g.
> explicit drive redirection into `thinclient_drives`) in your back pocket.

---

## 3. Proposed Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Swift macOS App (.app bundle)                               │
│                                                             │
│  ┌───────────────┐   ┌──────────────────┐  ┌─────────────┐  │
│  │ SwiftUI UI     │   │ Favorites Store  │  │ Keychain    │  │
│  │ - connect form │   │ (JSON/UserDef.)  │  │ (creds)     │  │
│  │ - favorites    │   └──────────────────┘  └─────────────┘  │
│  └──────┬────────┘                                          │
│         │                                                   │
│  ┌──────▼──────────────────────────────────────────────┐   │
│  │ RDPSession (Swift wrapper / actor)                   │   │
│  │  - session lifecycle, callbacks, error surface       │   │
│  │  - renders framebuffer into an NSView/Metal layer    │   │
│  │  - bridges macOS pasteboard ↔ CLIPRDR                 │   │
│  └──────┬───────────────────────────────────────────────┘   │
│         │  C interop (module map / bridging)                │
│  ┌──────▼───────────────────────────────────────────────┐   │
│  │ libfreerdp3 / libfreerdp-client3 / libwinpr3 (C)      │   │
│  │  - protocol, TLS/NLA, codecs                          │   │
│  │  - cliprdr channel (CLIPRDR)                           │   │
│  │  - rdpdr channel (drive redirect, optional)           │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**Layering principle:** Keep all `libfreerdp` interaction behind one Swift
type (e.g. `RDPSession`). The UI never touches C directly. This makes the FreeRDP
dependency swappable and testable.

---

## 4. Toolchain & Environment (no full Xcode)

You have: **VSCode**, the **Swift extension** (sourcekit-lsp), and **Xcode Command
Line Tools** (`swiftc`, `swift`, `clang`, `codesign`, `xcrun`).

### 4.1 What the Command Line Tools give you vs. what they don't

| Available with CLT | Needs workaround (no Xcode IDE) |
|---|---|
| `swift build` / Swift Package Manager | Building/running a GUI app target |
| SwiftUI & AppKit **frameworks** (present in the macOS SDK) | `.xcodeproj`, Interface Builder |
| `swiftc`, `clang`, module maps, C interop | Xcode's app-bundle packaging & signing UI |
| `codesign`, `xcrun`, `lldb` | Simulator, Instruments |

**Key point:** SwiftUI and AppKit ship in the macOS SDK, so you **can** build a GUI
app with just the Command Line Tools — you just have to assemble the `.app` bundle
and sign it yourself (or use a helper tool). See §5.

### 4.2 Install dependencies

```bash
# FreeRDP + its deps (Homebrew)
brew install freerdp

# Confirm the libs/headers landed (paths differ on Intel vs Apple Silicon):
#   Apple Silicon: /opt/homebrew/...   Intel: /usr/local/...
brew --prefix freerdp
pkg-config --cflags --libs freerdp3 winpr3   # if freerdp ships .pc files
```

### 4.3 VSCode setup

- Install the **Swift** extension (adds sourcekit-lsp, build tasks, debugging).
- Open the package folder (the one containing `Package.swift`) as the workspace
  root so the language server resolves modules.
- Add `tasks.json` entries for `swift build`, a "bundle" script (§5), and "run".
- Debugging uses **CodeLLDB** / the Swift extension's LLDB integration.

---

## 5. Building a REAL `.app` Bundle Without Xcode

This is the packaging decision you confirmed. Two viable paths:

### Path A (recommended): use `swift-bundler`
[`swift-bundler`](https://github.com/stackotter/swift-bundler) is purpose-built for
"SwiftUI macOS apps with SPM, no Xcode." It produces a proper `.app` with
`Info.plist`, icon, and code signing.

```bash
brew install stackotter/tap/swift-bundler   # or build from source
swift bundler create simpleRDP --template SwiftUI
swift bundler run        # builds .app and launches it
```

### Path B (manual, zero extra tooling): hand-roll the bundle
Understand the mechanics even if you use Path A. An SPM **executable** target is
compiled, then dropped into a bundle skeleton:

```
simpleRDP.app/
└── Contents/
    ├── Info.plist              # CFBundleIdentifier, CFBundleExecutable, etc.
    ├── MacOS/
    │   └── simpleRDP          # the swift build product
    └── Resources/
        └── AppIcon.icns
```

```bash
swift build -c release
APP=simpleRDP.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/simpleRDP "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# ad-hoc sign (fine for local use; real distribution needs a Developer ID)
codesign --force --deep --sign - "$APP"
open "$APP"
```

**`Info.plist` must include** at minimum: `CFBundleExecutable`,
`CFBundleIdentifier`, `CFBundleName`, `CFBundlePackageType` (`APPL`),
`LSMinimumSystemVersion`, and `NSHighResolutionCapable`.

**Gotchas to document for the dev phase:**
- **SwiftUI `@main`** works from an SPM executable, but only behaves like a real
  app (Dock icon, menu bar, window activation) when launched **as a bundle**, not
  as a bare binary. Always test via the `.app`.
- **Bundled dylibs:** the app links `libfreerdp*.dylib` from Homebrew. For a
  portable app, copy the dylibs into `Contents/Frameworks/` and fix load paths with
  `install_name_tool` / `@rpath`. For local dev, linking against the Homebrew
  prefix is fine.
- **Ad-hoc signing** (`--sign -`) is enough to run locally. Distribution to other
  Macs requires a **Developer ID** cert + **notarization** (needs an Apple
  Developer account; can be done from CLI via `notarytool`).

---

## 6. Linking FreeRDP into a Swift Package (C interop)

Use SPM's **system library target** to expose the C headers to Swift.

**`Package.swift` sketch:**
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "simpleRDP",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CFreeRDP", path: "Sources/CFreeRDP"),
        .executableTarget(
            name: "simpleRDP",
            dependencies: ["CFreeRDP"],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lfreerdp3", "-lfreerdp-client3", "-lwinpr3"
                ])
            ]
        )
    ]
)
```

**`Sources/CFreeRDP/module.modulemap`:**
```
module CFreeRDP {
    header "shim.h"
    link "freerdp3"
    export *
}
```

**`Sources/CFreeRDP/shim.h`** just includes the FreeRDP headers you need
(`<freerdp/freerdp.h>`, `<freerdp/client/cliprdr.h>`, `<freerdp/channels/...>`,
`<winpr/...>`). Add `-I$(brew --prefix)/include` via `.unsafeFlags` or
`CPATH`/`pkg-config`.

**Interop notes to plan for:**
- FreeRDP is **callback-heavy** (function pointers for events, channel data,
  graphics). Swift can hold C function pointers only as **global funcs or
  non-capturing closures** — pass your Swift object through the `void* userdata`
  fields and cast back with `Unmanaged`.
- Run the FreeRDP event loop **off the main thread** (an actor or a dedicated
  `Thread`/`DispatchQueue`); marshal UI updates back to the main actor.
- Wrap all pointer lifetime management in one place to avoid use-after-free.

---

## 7. UI Design (SwiftUI)

Keep it deliberately simple for v1.

**Screens / components:**
1. **Connection bar**
   - Text field: **Server IP / hostname** (accept `host` or `host:port`).
   - Optional: username field; password handled via Keychain prompt (§10).
   - **Connect** button.
2. **Favorites list** (sidebar or list under the connect bar)
   - Each favorite: **custom display name** + host/port + optional username +
     endpoint-type hint (`Windows` / `xrdp`).
   - Actions: **Add current as favorite**, **Edit**, **Delete**, **Connect**.
3. **Session window**
   - Hosts the remote framebuffer view (an `NSViewRepresentable` wrapping the
     Metal/`CALayer` surface FreeRDP renders into).
   - Toolbar: disconnect, connection status, clipboard/file-transfer indicator.

**Suggested model types:**
```swift
struct ServerFavorite: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String            // custom label, e.g. "Lab box #3"
    var host: String            // IP or hostname
    var port: Int = 3389
    var username: String?
    var endpointKind: EndpointKind = .auto   // .windows, .xrdp, .auto
}

enum EndpointKind: String, Codable { case auto, windows, xrdp }
```

---

## 8. Clipboard: CLIPRDR File Copy/Paste (v1 target)

**Channel:** `cliprdr` in FreeRDP. You register a `CliprdrClientContext` and wire
up its callbacks.

**Flow for "copy a file on Mac → paste on remote":**
1. macOS side: user copies file(s) in Finder → they land on `NSPasteboard` as
   `public.file-url` items. Observe the pasteboard (poll `changeCount` or hook the
   session focus events).
2. Advertise formats to the server via **Format List PDU**, declaring the
   `FileGroupDescriptorW` (`CF_HDROP`-equivalent) format.
3. When the remote requests contents, respond to **Format Data Request** with a
   `FILEDESCRIPTOR` array (names, sizes, attributes).
4. Stream bytes on **File Contents Request** (`CB_FILECONTENTS_REQUEST`) →
   **File Contents Response**, reading from the local file(s) in ranged chunks.

**Flow for "copy on remote → paste on Mac":** the inverse — receive the remote's
format list, request `FileGroupDescriptorW`, then pull file contents and write them
to a temp dir, exposing them back on `NSPasteboard` as file URLs.

**xrdp specifics (tie-back to §2.2):**
- With xrdp, the pasted files appear to the Linux user under
  `~/thinclient_drives/.clipboard/` (via `chansrv`'s FUSE mount). **Your client
  does nothing special here** — you just serve CLIPRDR correctly; xrdp handles the
  server-side materialization.
- **Verify** the target xrdp version advertises the file-transfer clipboard
  capability. If it doesn't, files won't cross even though text does.

**Fallback option (document, don't build in v1):** if a given xrdp box lacks
clipboard file transfer, enable **`rdpdr` drive redirection** so a chosen Mac
folder mounts under `~/thinclient_drives/<name>/` and the user copies files
in/out manually. This is the "original idea," valid as a Plan B.

---

## 9. Windows vs. xrdp Endpoint Handling

Same protocol, but practical differences to code around:

| Concern | Windows endpoint | xrdp (Linux) |
|---|---|---|
| Security / auth | Often **NLA/CredSSP** required | Frequently **TLS-only**, NLA often off |
| Default port | 3389 | 3389 (configurable) |
| Clipboard files | Robust | Version-dependent (§8) |
| Cert | Self-signed common in labs | Self-signed common |

**Recommendations:**
- Set FreeRDP security negotiation to **auto/negotiate**; let it fall back TLS↔NLA.
- The `endpointKind` hint in a favorite can pre-tune defaults (e.g. don't force NLA
  for `.xrdp`).
- Implement a **certificate-trust callback** — on first connect to a self-signed
  host, surface a "trust this certificate?" prompt and remember the decision
  (store the fingerprint). Never auto-trust silently.

---

## 10. Security & Credentials

- **Never** hardcode or plaintext-store passwords. Use the **macOS Keychain**
  (`Security.framework` / a small wrapper) keyed by host+username.
- Favorites store host/username/label only; the **password reference** lives in
  Keychain and is fetched at connect time (with a system auth prompt as needed).
- **Certificate pinning/TOFU:** store accepted cert fingerprints; warn on change.
- App entitlements / `Info.plist`: outbound network is allowed by default for
  non-sandboxed apps. If you later **sandbox** the app, add
  `com.apple.security.network.client` and file-access entitlements for the
  clipboard-file feature.
- Treat the server IP/hostname as **user-supplied config only** — no auto-connect
  to anything derived from remote content.

---

## 11. Suggested Milestones / Action-Item Checklist

**Milestone 0 — Environment**
- [ ] Install `brew install freerdp`; confirm headers/libs and Homebrew prefix.
- [ ] Install `swift-bundler` (or write the manual bundle script).
- [ ] Create the SPM package; get an empty SwiftUI window building into a `.app`.
- [ ] Configure VSCode tasks: build, bundle, run, debug.

**Milestone 1 — FreeRDP handshake**
- [ ] System-library target + module map linking `libfreerdp3`/`libwinpr3`.
- [ ] `RDPSession` type that opens a connection to a host and logs success/failure.
- [ ] Certificate-trust (TOFU) callback with a SwiftUI prompt.
- [ ] Connect successfully to **both** a Windows box and an **xrdp** box (headless
      OK — verify auth/handshake before worrying about pixels).

**Milestone 2 — Display & input**
- [ ] Render the remote framebuffer into an `NSView`/Metal layer.
- [ ] Forward keyboard/mouse; handle resize/DPI.

**Milestone 3 — UI polish**
- [ ] Connection form (IP/host:port, username).
- [ ] Favorites CRUD with custom names; persist to JSON/UserDefaults.
- [ ] Keychain-backed credentials.

**Milestone 4 — Clipboard file transfer (CLIPRDR)**
- [ ] Register `cliprdr`; negotiate formats.
- [ ] Mac → remote file copy (FILEDESCRIPTOR + file-contents streaming).
- [ ] Remote → Mac file copy.
- [ ] Validate on xrdp; confirm files land under `~/thinclient_drives/.clipboard/`.
- [ ] Document/spike the `rdpdr` drive-redirection fallback.

**Milestone 5 — Packaging & hardening**
- [ ] Bundle Homebrew dylibs into `Contents/Frameworks/`; fix `@rpath`.
- [ ] Decide on ad-hoc vs. Developer ID + notarization for distribution.
- [ ] Error surfaces, reconnection, timeouts.

---

## 12. Open Questions / Risks to Track

1. **xrdp version matrix** — which exact xrdp builds do your Linux workstations
   run? File clipboard support varies. *Confirm before committing to CLIPRDR-files
   as the only mechanism.*
2. **FreeRDP embedding effort** — rendering + input handling from `libfreerdp` is
   the single biggest build cost. Consider studying FreeRDP's own SDL/sample client
   as a reference implementation.
3. **Apple Silicon vs. Intel** paths (`/opt/homebrew` vs `/usr/local`) — make the
   build scripts prefix-agnostic (`brew --prefix`).
4. **Distribution model** — local-only (ad-hoc sign) vs. shared (Developer ID +
   notarization, requires paid Apple Developer account).
5. **Sandboxing** — do you need App Sandbox / eventual App Store? It complicates
   file access and dylib bundling; decide early.
6. **License** — FreeRDP is Apache-2.0 (permissive); fine to bundle. Track the
   licenses of any transitive deps you ship.

---

## 13. Reference Pointers

- FreeRDP: <https://github.com/FreeRDP/FreeRDP> (v3.x API; see `client/common` and
  the SDL client for an embedding reference).
- CLIPRDR spec: MS-RDPECLIP (clipboard virtual channel extension, incl. file
  transfer / `FILEDESCRIPTOR` / file-contents PDUs).
- Drive redirection: MS-RDPEFS (`rdpdr`), and xrdp `chansrv` docs for the
  `thinclient_drives` FUSE mount behavior.
- swift-bundler: <https://github.com/stackotter/swift-bundler> (SwiftUI apps via
  SPM without Xcode).
- SPM system-library targets & module maps (Swift docs).

---

## Appendix A — VSCode Tasks & Bundle Script (framework files)

These files ship alongside this doc as a ready-to-carry framework. Drop the repo
onto the target MacBook, open the folder in VSCode, and the tasks below drive the
whole build/bundle/run loop. They assume the SPM package's executable target is
named **`simpleRDP`** — rename in all three files if you choose another name.

### File layout expected on the Mac
```
<repo root>/
├── Package.swift                 # SPM manifest (see §6)
├── Info.plist                    # optional; bundle.sh generates one if absent
├── Sources/
│   ├── CFreeRDP/                 # system-library target (module.modulemap + shim.h)
│   └── simpleRDP/              # SwiftUI app sources
├── Scripts/
│   └── bundle.sh                 # assembles + signs simpleRDP.app  (chmod +x)
├── Resources/
│   └── AppIcon.icns              # optional
└── .vscode/
    ├── tasks.json                # build / bundle / run / deps-check
    └── launch.json               # LLDB debug config
```

### `.vscode/tasks.json` — what each task does

| Task label | Command | Purpose |
|---|---|---|
| **swift: build (debug)** *(default build)* | `swift build` | Fast compile for the edit loop; `$swiftc` problem matcher surfaces errors inline. |
| **swift: build (release)** | `swift build -c release` | Optimized build used before bundling. |
| **swift: clean** | `rm -rf .build simpleRDP.app` | Reset build + prior bundle. |
| **app: bundle (release)** | `./Scripts/bundle.sh release` | Depends on the release build, then assembles/signs the `.app`. |
| **app: run** | `open ./simpleRDP.app` | Bundles (via `dependsOn`) then launches — the correct way to test SwiftUI behavior. |
| **deps: check freerdp** | `brew --prefix` + `pkg-config` | Verifies FreeRDP is installed and discoverable before you fight linker errors. |

Run tasks from **Terminal → Run Task…**, or bind the default build task to
**Cmd-Shift-B**.

### `Scripts/bundle.sh` highlights
- **Prefix-agnostic:** resolves Homebrew via `brew --prefix`, so the same script
  works on Apple Silicon and Intel.
- **Self-sufficient Info.plist:** copies a checked-in `Info.plist` if present,
  otherwise writes a minimal valid one.
- **Portability toggle:** `VENDOR_DYLIBS=1 ./Scripts/bundle.sh release` copies the
  FreeRDP dylibs into `Contents/Frameworks/` and starts the `@rpath` rewrite for
  distributing to Macs without Homebrew. Off by default (local dev links against
  the Homebrew prefix).
- **Ad-hoc signs** (`codesign --sign -`) so the app runs locally. Distribution
  still needs Developer ID + notarization.

### First-run steps on the target MacBook
```bash
# 1. one-time env
brew install freerdp
chmod +x Scripts/bundle.sh

# 2. sanity check the dependency wiring (VSCode: "deps: check freerdp")
brew --prefix freerdp && pkg-config --exists freerdp3 && echo OK

# 3. build → bundle → run (VSCode: "app: run", or from a terminal:)
swift build -c release && ./Scripts/bundle.sh release && open ./simpleRDP.app
```

> **Rename note:** if the executable target isn't `simpleRDP`, update it in
> `Package.swift`, `.vscode/tasks.json` (clean path + open path),
> `.vscode/launch.json` (`program`), and `Scripts/bundle.sh` (`APP_NAME`).
