#!/usr/bin/env bash
#
# bundle.sh — assemble a double-clickable macOS .app from the SPM build product,
# without Xcode. Referenced by .vscode/tasks.json ("app: bundle (release)").
#
# Usage:  ./Scripts/bundle.sh [debug|release]   (default: release)
#
# What it does:
#   1. Locates the compiled executable from `swift build`.
#   2. Builds the simpleRDP.app/Contents/{MacOS,Resources} skeleton.
#   3. Copies the binary + Info.plist (+ icon if present).
#   4. (Optional) vendors Homebrew dylibs into Contents/Frameworks and rewrites
#      their load paths to @rpath so the app is portable to other Macs.
#   5. Ad-hoc code-signs so it runs locally.
#
# NOTE: ad-hoc signing (`--sign -`) is fine for local dev. Distribution to other
# machines requires a Developer ID cert + notarization (see plan doc §5/§11).

set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="simpleRDP"
APP="${APP_NAME}.app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=".build/${CONFIG}/${APP_NAME}"
if [[ ! -f "$BIN" ]]; then
  echo "error: build product not found at $BIN — run 'swift build -c ${CONFIG}' first." >&2
  exit 1
fi

echo "==> Assembling ${APP} (${CONFIG})"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"

cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"

# Info.plist: use a checked-in one if present (repo root first, then the
# target source dir), else generate a minimal default.
if [[ -f "Info.plist" ]]; then
  cp "Info.plist" "${APP}/Contents/Info.plist"
elif [[ -f "Sources/${APP_NAME}/Info.plist" ]]; then
  cp "Sources/${APP_NAME}/Info.plist" "${APP}/Contents/Info.plist"
else
  echo "==> No Info.plist found; generating a minimal default."
  cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>com.example.${APP_NAME}</string>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
</dict>
</plist>
PLIST
fi

# Optional icon
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
fi

# --- Optional: vendor Homebrew dylibs for portability -----------------------
# Toggle by setting VENDOR_DYLIBS=1 in the environment. Off by default because
 the Homebrew prefix works fine.
if [[ "${VENDOR_DYLIBS:-0}" == "1" ]]; then
  "${ROOT}/Scripts/vendor_dylibs.sh" "${APP}"
fi
# ---------------------------------------------------------------------------

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo "==> Done: ${ROOT}/${APP}"
