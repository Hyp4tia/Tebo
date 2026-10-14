#!/usr/bin/env python3
"""Sign Sparkle's nested components inside-out, preserving their sandbox entitlements.

Xcode's framework embed step signs only the framework, leaving its upstream
ad-hoc helper signatures. Distribution requires our Developer ID on each one.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--identity", required=True)
args = parser.parse_args()
framework = args.app / "Contents/Frameworks/Sparkle.framework/Versions/Current"
for relative in ("Autoupdate", "Updater.app", "XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "."):
    path = framework / relative
    if not path.exists():
        raise SystemExit("Missing Sparkle component: " + str(path))
    subprocess.run(["codesign", "--force", "--sign", args.identity, "--timestamp", "--options", "runtime",
                    "--preserve-metadata=identifier,entitlements", str(path)], check=True)
