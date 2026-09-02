#!/usr/bin/env bash
#
# vendor_dylibs.sh — make simpleRDP.app portable by bundling the FreeRDP
# dylib dependency closure and rewriting all load paths to @rpath.
#
# Why: the binary links FreeRDP/WinPR via absolute /opt/homebrew paths, so the
# app only runs on a machine with `brew install freerdp`. This script vendors
# every Homebrew dylib the app (transitively) needs into Contents/Frameworks
# and rewrites install names to @rpath, so the app runs with no Homebrew.
#
# The subtlety: libs reference each other by SYMLINK names (e.g. a dep on
# "libavutil.61.dylib", a symlink whose real file is "libavutil.61.1.101.dylib").
# So we copy each lib under the NAME IT IS REFERENCED BY, and rewrite each
# binary/lib against the exact reference strings other files actually use.
#
# Usage:  VENDOR_DYLIBS=1 ./Scripts/bundle.sh release
#         (bundle.sh calls this; or standalone: ./Scripts/vendor_dylibs.sh app)
#
# After vendoring, the caller re-signs the app (ad-hoc). Distribution to other
# Macs additionally needs Developer ID + notarization (plan §5/§11).
#
set -euo pipefail

APP="${1:-simpleRDP.app}"
BIN="$APP/Contents/MacOS/simpleRDP"
FW="$APP/Contents/Frameworks"

[[ -f "$BIN" ]] || { echo "error: $BIN not found" >&2; exit 1; }
mkdir -p "$FW"

BREW="$(brew --prefix)"

echo "==> Computing Homebrew dylib closure"

# Emit TAB-separated pairs:  <real-path>\t<referenced-path>
# for every Homebrew dylib reachable from the binary. The referenced path is
# the exact string some file links against (may be a symlink); the real path
# is what we copy.
PAIRS=$(python3 - "$BIN" "$BREW" <<'PYEOF'
import subprocess, re, os, sys
root, brew = sys.argv[1], sys.argv[2]
def refs(p):
    out = subprocess.run(["otool","-L",p], capture_output=True, text=True).stdout
    r = []
    for line in out.splitlines()[1:]:
        m = re.match(r"^\s+(/\S+)\s+\(", line)
        if m and m.group(1).startswith(brew + "/"):
            r.append(m.group(1))
    return r
seen_ref = {}   # referenced path -> real path
stack = [os.path.realpath(root)]
seen_real = {os.path.realpath(root)}
while stack:
    cur = stack.pop()
    for ref in refs(cur):
        real = os.path.realpath(ref)
        if ref not in seen_ref:
            seen_ref[ref] = real
        if real not in seen_real:
            seen_real.add(real)
            stack.append(real)
for ref in sorted(seen_ref):
    print(f"{seen_ref[ref]}\t{ref}")
PYEOF
)

COUNT=$(echo "$PAIRS" | grep -c .)
echo "==> Vendoring $COUNT dylibs (copied under their referenced names)"

# Pass 1: copy each lib into Frameworks under its REFERENCED basename and set
# its install-name ID to @rpath/<referenced-basename>.
while IFS=$'\t' read -r real ref; do
    [[ -n "$real" ]] || continue
    base="$(basename "$ref")"
    cp -f "$real" "$FW/$base"
    chmod u+w "$FW/$base"
    install_name_tool -id "@rpath/$base" "$FW/$base"
done <<< "$PAIRS"

# Pass 2: rewrite every Homebrew reference in the binary AND in each vendored
# lib to @rpath/<referenced-basename>, using the referenced path string.
relink() {
    local target="$1"
    while IFS=$'\t' read -r real ref; do
        [[ -n "$ref" ]] || continue
        base="$(basename "$ref")"
        # Only rewrite if this exact reference string is present in target.
        if otool -L "$target" | grep -qF "$ref ("; then
            install_name_tool -change "$ref" "@rpath/$base" "$target" 2>/dev/null || true
        fi
    done <<< "$PAIRS"
}

echo "==> Rewriting references to @rpath"
relink "$BIN"
for f in "$FW"/*.dylib; do
    relink "$f"
done

# Rpath: binary and bundled libs find each other.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
for f in "$FW"/*.dylib; do
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
done

# Verify: no remaining Homebrew/Cellar references anywhere.
echo "==> Verifying no Homebrew references remain"
LEAK=0
for f in "$BIN" "$FW"/*.dylib; do
    if otool -L "$f" | grep -qE "$BREW|Cellar"; then
        echo "    STILL LINKED: $(basename "$f")"
        otool -L "$f" | grep -E "$BREW|Cellar" | sed 's/^/      /'
        LEAK=1
    fi
done
if [[ "$LEAK" == "1" ]]; then
    echo "error: some Homebrew references could not be rewritten" >&2
    exit 1
fi
echo "    clean: all references use @rpath"
echo "==> Vendored $COUNT dylibs into $FW"
