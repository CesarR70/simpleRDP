#!/usr/bin/env python3
"""Validate the vendored closure and record its real deployment requirements."""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
contents = app / "Contents"
binary = contents / "MacOS/simpleRDP"
frameworks = contents / "Frameworks"
files = [binary, *sorted(frameworks.glob("*.dylib"))]
minimum = (13, 0)
manifest = []
for path in files:
    headers = subprocess.check_output(["otool", "-l", str(path)], text=True)
    # Only version lines within LC_VERSION_MIN_MACOSX are deployment targets.
    versions = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([\d.]+)", headers)
    versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)", headers)
    if not versions:
        raise SystemExit(f"No macOS deployment target found in {path}")
    target = max(tuple(map(int, v.split("."))) for v in versions)
    minimum = max(minimum, target)
    architecture = subprocess.check_output(["lipo", "-archs", str(path)], text=True).strip()
    if "arm64" not in architecture.split():
        raise SystemExit(f"Missing arm64 architecture: {path}")
    links = subprocess.check_output(["otool", "-L", str(path)], text=True)
    dependencies = []
    for line in links.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        dependencies.append(dependency)
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        if dependency.startswith(("@rpath/", "@loader_path/")):
            if (frameworks / Path(dependency).name).is_file():
                continue
        raise SystemExit(f"Unresolved/nonportable dependency in {path.name}: {dependency}")
    manifest.append({"file": str(path.relative_to(contents)), "architectures": architecture,
                     "minimumMacOS": ".".join(map(str, target)), "dependencies": dependencies})
plist_path = contents / "Info.plist"
with plist_path.open("rb") as stream:
    info = plistlib.load(stream)
info["LSMinimumSystemVersion"] = ".".join(map(str, minimum))
with plist_path.open("wb") as stream:
    plistlib.dump(info, stream, sort_keys=False)
resources = contents / "Resources"
(resources / "DependencyManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Verified {len(files) - 1} bundled libraries; portable release requires macOS {info['LSMinimumSystemVersion']}+ (arm64).")