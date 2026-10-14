#!/usr/bin/env python3
"""Copy only verified self-contained helpers into a generated app and sign them."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import re

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--identity", default="-")
parser.add_argument("--required", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
helpers = root / ".build/video-helpers"
if not (helpers / "bin/ffmpeg").exists():
    if args.required:
        raise SystemExit("Portable helpers missing: run scripts/build-video-helpers.py")
    print("Portable helpers not built; developer build uses installed video tools.")
    raise SystemExit(0)
destination = args.app / "Contents/MacOS"
destination.mkdir(parents=True, exist_ok=True)
for name in ("ffmpeg", "ffprobe"):
    source = helpers / "bin" / name
    linked = subprocess.check_output(["otool", "-L", str(source)], text=True)
    if any(not line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in linked.splitlines()[1:]):
        raise SystemExit("Nonportable video helper dependency: " + name)
    commands = subprocess.check_output(["otool", "-l", str(source)], text=True)
    versions = re.findall(r"\bminos\s+(\d+(?:\.\d+)*)", commands)
    if not versions or any(tuple(map(int, v.split("."))) > (14, 0, 0) for v in versions):
        raise SystemExit("Video helper exceeds the macOS 14 deployment target: " + name)
    target = destination / name
    shutil.copy2(source, target)
    timestamp = "--timestamp" if args.identity.startswith("Developer ID Application") else "--timestamp=none"
    subprocess.run(["codesign", "--force", "--options", "runtime", timestamp, "--sign", args.identity, str(target)], check=True)
resources = args.app / "Contents/Resources/VideoHelpers"
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(helpers / "sources.json", resources / "sources.json")
licenses = root / ".build/video-sources"
for name, filenames in {
    "ffmpeg": ["COPYING.GPLv3"], "x264": ["COPYING"], "x265": ["COPYING"],
    "vpx": ["LICENSE", "PATENTS"], "aom": ["LICENSE", "PATENTS"], "opus": ["COPYING"]
}.items():
    target = resources / name
    target.mkdir(exist_ok=True)
    for filename in filenames:
        shutil.copy2(licenses / name / filename, target / filename)
print("Bundled self-contained ffmpeg and ffprobe.")
