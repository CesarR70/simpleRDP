#!/usr/bin/env bash
#
# build.sh — thin wrapper around `swift build` that sanity-checks the FreeRDP
# dependency first, so a missing/broken install fails with a friendly hint
# instead of a wall of clang "file not found" errors.
#
# Usage:  ./Scripts/build.sh [debug|release]   (default: debug)
#
# Note: no PKG_CONFIG_PATH shim is needed anymore. Package.swift resolves
# FreeRDP via the stock "freerdp3" pkg-config module (on pkg-config's default
# search path) plus arch-conditional Homebrew prefix flags, so plain
# `swift build` — and, importantly, SourceKit-LSP inside VSCode — work
# without any environment setup.

set -euo pipefail

CONFIG="debug"
# Parse the optional first positional argument; everything else passes to swift build.
if [[ $# -ge 1 && ( "$1" == "debug" || "$1" == "release" ) ]]; then
  CONFIG="$1"
  shift
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve the three modules via pkg-config. Bail early with a helpful hint if
# any are missing (brew install freerdp pkg-config). freerdp3/winpr3 must be
# found on pkg-config's DEFAULT search path (no PKG_CONFIG_PATH tricks), since
# that is exactly what SourceKit-LSP in VSCode relies on.
if ! command -v pkg-config >/dev/null 2>&1; then
  echo "error: pkg-config not found. Install with: brew install pkg-config" >&2
  exit 1
fi
for mod in freerdp3 freerdp-client3 winpr3; do
  if ! pkg-config --exists "$mod"; then
    echo "error: pkg-config module '$mod' not found. Install with: brew install freerdp pkg-config" >&2
    exit 1
  fi
done

cd "${ROOT}"
echo "==> swift build -c ${CONFIG}"
exec swift build -c "${CONFIG}" "$@"
