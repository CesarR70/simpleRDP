// swift-tools-version:5.9
//
// simpleRDP — macOS Swift RDP client wrapping FreeRDP via C interop.
//
// FreeRDP + WinPR headers/libs come from Homebrew. Two mechanisms are layered
// so the package builds from ANY environment — terminal, VSCode task, or
// SourceKit-LSP (which does NOT inherit PKG_CONFIG_PATH from Scripts/build.sh):
//   1. pkg-config "freerdp3": it lives in $(brew --prefix)/lib/pkgconfig,
//      which is on pkg-config's default search path, so no PKG_CONFIG_PATH
//      is required.
//   2. Arch-conditional Homebrew prefix flags as a safety net — SPM's
//      pkg-config parser does not follow `Requires:` (freerdp3.pc gets the
//      winpr3 include dir that way), and non-default Homebrew prefixes are
//      not on pkg-config's default path.
//
// Install with:  brew install freerdp pkg-config
// See RDP-Swift-Client-Plan.md §6 for design notes.

import PackageDescription

// Homebrew's default prefix is arch-dependent: /opt/homebrew on Apple Silicon,
// /usr/local on Intel. Package manifests are sandboxed and cannot shell out to
// `brew --prefix`, so select by build architecture instead.
#if arch(arm64)
let brewPrefix = "/opt/homebrew"
#else
let brewPrefix = "/usr/local"
#endif

let package = Package(
    name: "simpleRDP",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CFreeRDP",
            path: "Sources/CFreeRDP",
            pkgConfig: "freerdp3",
            providers: [
                .brew(["freerdp", "pkg-config"]),
            ]
        ),
        .executableTarget(
            name: "simpleRDP",
            dependencies: [
                "CFreeRDP",
            ],
            exclude: [
                "Info.plist", // bundled by Scripts/bundle.sh, not by SPM
            ],
            cSettings: [
                // Passed as -Xcc when compiling this target's Swift sources, so
                // the clang importer finds <freerdp/...> and <winpr/...> while
                // building the CFreeRDP module from shim.h — even when the
                // driving tool (e.g. SourceKit-LSP in VSCode) has no pkg-config
                // metadata available.
                .unsafeFlags([
                    "-I\(brewPrefix)/include/freerdp3",
                    "-I\(brewPrefix)/include/winpr3",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"]),
                .linkedLibrary("freerdp3"),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("winpr3"),
            ]
        )
    ]
)