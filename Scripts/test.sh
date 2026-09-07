#!/usr/bin/env bash
# Runs without Xcode: compile the real application sources with a tiny assertion
# runner. With full Xcode selected, `swift test` can run the XCTest target too.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/simplerdp-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
BREW="$(brew --prefix)"
SOURCES=()
for source in "$ROOT"/Sources/simpleRDP/*.swift; do
  [[ "$(basename "$source")" == "App.swift" ]] || SOURCES+=("$source")
done
swiftc -D STANDALONE_TESTS -swift-version 5 -parse-as-library \
  -I "$ROOT/Sources/CFreeRDP" \
  -Xcc "-I$BREW/include/freerdp3" -Xcc "-I$BREW/include/winpr3" \
  -L "$BREW/lib" -lfreerdp3 -lfreerdp-client3 -lwinpr3 \
  "${SOURCES[@]}" "$ROOT"/Tests/simpleRDPTests/*.swift \
  "$ROOT/Tests/StandaloneRunner.swift" -o "$BUILD/regression-tests"
"$BUILD/regression-tests"