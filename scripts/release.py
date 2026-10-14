#!/usr/bin/env python3
"""Prepare a Developer ID release, then notarize and create a signed update feed.

Never publishes publicly, exports signing keys, or removes earlier artifacts.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "Hyp4tia/Tebo"
TEAM = "RY4LJM4BM2"
ACCOUNT = "com.tebo.updates"
FEED = f"https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml"
TOOLS = ROOT / ".build/vendor/Sparkle-2.10.0/bin"
SPARKLE_SHA = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def run(args, **kwargs):
    print("Running:", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def output(args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT).strip()


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def tools():
    if not TOOLS.exists():
        base = TOOLS.parent
        base.mkdir(parents=True, exist_ok=True)
        archive = base.parent / "Sparkle-2.10.0.tar.xz"
        if not archive.exists():
            url = "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz"
            with urllib.request.urlopen(url, timeout=90) as response, archive.open("wb") as f:
                shutil.copyfileobj(response, f)
        if digest(archive) != SPARKLE_SHA:
            raise RuntimeError("Sparkle tools archive digest mismatch")
        with tarfile.open(archive) as tar:
            tar.extractall(base, filter="data")
    return TOOLS


def key_matches(app_info):
    public = output([tools() / "generate_keys", "--account", ACCOUNT, "-p"])
    if public != app_info.get("SUPublicEDKey"):
        raise RuntimeError("The local update key does not match the app's public key")


def validate_bundle(app):
    data = info(app)
    if data["CFBundleIdentifier"] != "com.tebo.app" or data.get("SUFeedURL") != FEED:
        raise RuntimeError("Incorrect bundle/update configuration")
    if not data.get("SURequireSignedFeed") or not data.get("SUVerifyUpdateBeforeExtraction"):
        raise RuntimeError("Signed feed and pre-extraction archive validation are required")
    key_matches(data)
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    signed = output(["codesign", "-dv", "--verbose=4", app])
    if "Authority=Developer ID Application:" not in signed or f"TeamIdentifier={TEAM}" not in signed or "Timestamp=" not in signed:
        raise RuntimeError("A timestamped Developer ID signature from the configured team is required")
    entitlements = output(["codesign", "-d", "--entitlements", "-", app])
    for forbidden in ("get-task-allow", "disable-library-validation", "allow-unsigned-executable-memory"):
        if forbidden in entitlements:
            raise RuntimeError("Forbidden release entitlement: " + forbidden)
    for name in ("Tebo.icns", "TeboBackdrop.png", "NOTICE.md", "LICENSE", "Sparkle-LICENSE.txt", "VideoHelpers/sources.json"):
        if not (app / "Contents/Resources" / name).is_file():
            raise RuntimeError("Missing resource: " + name)
    for name in ("czkawka_cli", "ffmpeg", "ffprobe"):
        binary = app / "Contents/MacOS" / name
        if not os.access(binary, os.X_OK):
            raise RuntimeError("Missing executable: " + name)
        signature = output(["codesign", "-dv", "--verbose=4", binary])
        if f"TeamIdentifier={TEAM}" not in signature or "Timestamp=" not in signature:
            raise RuntimeError("Helper is not timestamped and signed by the app's team: " + name)
        linked = output(["otool", "-L", binary]).splitlines()[1:]
        if any(not line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in linked):
            raise RuntimeError("Non-system helper dependency: " + name)
        # Only the minimum OS from LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX matters.
        commands = output(["otool", "-l", binary])
        minimums = re.findall(r"LC_BUILD_VERSION[\s\S]*?minos\s+(\d+(?:\.\d+)*)|LC_VERSION_MIN_MACOSX[\s\S]*?version\s+(\d+(?:\.\d+)*)", commands)
        if not minimums or any(tuple(map(int, (a or b).split("."))) > (14, 0, 0) for a, b in minimums):
            raise RuntimeError("Helper exceeds the macOS 14 minimum: " + name)
    env = os.environ | {"PATH": "/usr/bin:/bin", "SUPERCLEAN_FFMPEG": "/nonexistent"}
    run([app / "Contents/MacOS/Tebo", "--selftest"], env=env)
    framework = app / "Contents/Frameworks/Sparkle.framework/Versions/Current"
    for nested in ("Autoupdate", "Updater.app", "XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "."):
        signature = output(["codesign", "-dv", "--verbose=4", framework / nested])
        if f"TeamIdentifier={TEAM}" not in signature or "Timestamp=" not in signature:
            raise RuntimeError("Sparkle component lacks our Developer ID and secure timestamp: " + nested)
    return data


def create_image(app, path, identity, work):
    work.mkdir()
    run(["ditto", app, work / "Tebo.app"])
    (work / "Applications").symlink_to("/Applications")
    shutil.copy2(ROOT / "Resources/FIRST-LAUNCH.txt", work / "First Launch.txt")
    run(["hdiutil", "create", "-volname", "Tebo", "-srcfolder", work, "-fs", "APFS", "-format", "ULFO", path])
    run(["codesign", "--force", "--sign", identity, "--timestamp", path])


def build(args):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", args.version) or args.build < 1:
        raise RuntimeError("Use a numeric version and positive, increasing build number")
    identities = output(["security", "find-identity", "-v", "-p", "codesigning"])
    matches = re.findall(r'"(Developer ID Application:[^"\n]+\(' + TEAM + r'\))"', identities)
    identity = os.environ.get("SIGN_IDENTITY") or (matches[0] if matches else None)
    if not identity or f'"{identity}"' not in identities or not identity.startswith("Developer ID Application:"):
        raise RuntimeError("No valid Developer ID Application identity for team " + TEAM)
    key_matches(plistlib.loads((ROOT / "Resources/Info.plist").read_bytes()))
    expected = re.search(r'^EXPECTED_SHA256="([a-f0-9]+)"', (ROOT / "scripts/fetch-engine.sh").read_text(), re.M)[1]
    if digest(ROOT / "Engines/czkawka_cli") != expected:
        raise RuntimeError("Czkawka engine does not match the upstream pin")
    helpers = ROOT / ".build/video-helpers"
    if not (helpers / "third-party-sources.tar.xz").is_file():
        raise RuntimeError("Build portable helpers and their source companion first")
    try:
        with urllib.request.urlopen(FEED, timeout=30) as response:
            previous = ET.fromstring(response.read())
        versions = [int(node.text) for node in previous.findall(".//sparkle:version", NS)]
        if versions and args.build <= max(versions):
            raise RuntimeError("Build number must exceed the last published update")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    if not args.skip_verify:
        run([ROOT / "scripts/verify.sh"], cwd=ROOT)
    run(["xcodegen", "generate"], cwd=ROOT)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = ROOT / "dist" / f"{args.version}-{args.build}-{stamp}"
    destination.mkdir(parents=True)
    derived = ROOT / ".build" / ("release-" + stamp)
    log = destination / "build.log"
    with log.open("w") as f:
        run(["xcodebuild", "-project", "Tebo.xcodeproj", "-scheme", "Tebo", "-configuration", "Release", "-derivedDataPath", derived,
             f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}", "CODE_SIGN_STYLE=Manual",
             f"DEVELOPMENT_TEAM={TEAM}", f"CODE_SIGN_IDENTITY={identity}", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
             "ENABLE_HARDENED_RUNTIME=YES", "OTHER_CODE_SIGN_FLAGS=--timestamp", "build"], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    app = destination / "Tebo.app"
    run(["ditto", derived / "Build/Products/Release/Tebo.app", app])
    # Resources added by the packaging step are sealed before validation.
    shutil.copy2(ROOT / "LICENSE", app / "Contents/Resources/LICENSE")
    shutil.copy2(TOOLS.parent / "LICENSE", app / "Contents/Resources/Sparkle-LICENSE.txt")
    run(["python3", ROOT / "scripts/sign-sparkle.py", app, "--identity", identity])
    run(["codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements", ROOT / "Resources/Tebo.entitlements", "--sign", identity, app])
    validate_bundle(app)
    shutil.copy2(helpers / "third-party-sources.tar.xz", destination / f"Tebo-{args.version}-video-sources.tar.xz")
    # Archive the exact current source snapshot, including authorized uncommitted edits.
    files = output(["git", "ls-files", "--cached", "--others", "--exclude-standard"]).splitlines()
    with tarfile.open(destination / f"Tebo-{args.version}-source.tar.xz", "w:xz") as tar:
        for name in files:
            path = ROOT / name
            if path.is_file() or path.is_symlink():
                tar.add(path, arcname="Tebo/" + name, recursive=False)
    metadata = {"version": args.version, "build": args.build, "identity": identity, "team": TEAM,
                "source_commit": output(["git", "rev-parse", "HEAD"]), "source_has_changes": bool(output(["git", "status", "--porcelain"])),
                "ready": False, "created_utc": stamp}
    (destination / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    create_image(app, destination / f"Tebo-{args.version}-signed.dmg", identity, derived / "signed-image-stage")
    print("SIGNED PREPARATION ONLY. Notarization required:", destination, flush=True)
    print("Next: scripts/notarize.sh", destination, flush=True)


def submit(path, profile, log):
    result = output(["xcrun", "notarytool", "submit", path, "--keychain-profile", profile, "--wait", "--timeout", "30m", "--output-format", "json"])
    log.write_text(result + "\n")
    if json.loads(result).get("status") != "Accepted":
        raise RuntimeError("Apple did not accept notarization. See " + str(log))


def finalize(args):
    directory = args.directory.resolve()
    data = json.loads((directory / "release.json").read_text())
    app = directory / "Tebo.app"
    validate_bundle(app)
    run(["xcrun", "notarytool", "history", "--keychain-profile", args.profile], stdout=subprocess.DEVNULL)
    ready = directory / "ready"
    if ready.exists():
        raise RuntimeError("Ready output already exists. Preserve it and review that release first.")
    ready.mkdir()
    upload = directory / "Tebo-notary.zip"
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, upload])
    submit(upload, args.profile, directory / "app-notary.json")
    run(["xcrun", "stapler", "staple", app])
    run(["xcrun", "stapler", "validate", app])
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", app])
    dmg = ready / f"Tebo-{data['version']}.dmg"
    create_image(app, dmg, data["identity"], directory / "notarized-image-stage")
    submit(dmg, args.profile, directory / "dmg-notary.json")
    run(["xcrun", "stapler", "staple", dmg])
    run(["xcrun", "stapler", "validate", dmg])
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg])
    notes = f"<h2>Tebo {data['version']}</h2><p>File cleanup and Media cleanup, live background blur, native signed updates, and bundled video tools.</p><p>macOS 14 or newer, Apple Silicon. Older builds without an updater require one manual installation.</p>"
    dmg.with_suffix(".html").write_text(notes)
    run([tools() / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0", "--embed-release-notes",
         "--download-url-prefix", f"https://github.com/{REPOSITORY}/releases/download/v{data['version']}/", "--link", f"https://github.com/{REPOSITORY}", ready])
    run([tools() / "sign_update", "--account", ACCOUNT, "--verify", ready / "appcast.xml"])
    feed = ET.parse(ready / "appcast.xml")
    enclosure = feed.find(".//enclosure")
    signature = enclosure.attrib["{" + NS["sparkle"] + "}edSignature"]
    run([tools() / "sign_update", "--account", ACCOUNT, "--verify", dmg, signature])
    if enclosure.attrib["length"] != str(dmg.stat().st_size):
        raise RuntimeError("Update archive length mismatch")
    for path in directory.glob("Tebo-*-source*.tar.xz"):
        shutil.copy2(path, ready / path.name)
    for path in directory.glob("Tebo-*-video-sources.tar.xz"):
        shutil.copy2(path, ready / path.name)
    (ready / "release-notes.md").write_text(f"Tebo {data['version']} for macOS 14+ on Apple Silicon.\n\nNative File cleanup and Media cleanup, adjustable live background blur, bundled video helpers and signed in-app updates. Removals go to the Trash and Preview is on by default.\n\nDownload the DMG and drag Tebo to Applications. Existing pre-updater builds need one manual installation. Source companions and checksums are included.\n")
    assets = [dmg, ready / "appcast.xml", *ready.glob("*.tar.xz")]
    data.update(ready=True, assets={p.name: digest(p) for p in assets})
    (ready / "release.json").write_text(json.dumps(data, indent=2) + "\n")
    (ready / "SHA256SUMS.txt").write_text("".join(f"{digest(p)}  {p.name}\n" for p in assets))
    print("NOTARIZED, STAPLED AND UPDATE-SIGNED. Review-ready:", ready, flush=True)


def draft(args):
    directory = args.directory.resolve()
    data = json.loads((directory / "release.json").read_text())
    if not data.get("ready"):
        raise RuntimeError("Only a notarized, update-signed release can be drafted")
    for name, expected in data["assets"].items():
        if Path(name).name != name or digest(directory / name) != expected:
            raise RuntimeError("Release artifact changed: " + name)
    for companion in (f"Tebo-{data['version']}-source.tar.xz", f"Tebo-{data['version']}-video-sources.tar.xz"):
        if companion not in data["assets"]:
            raise RuntimeError("Missing corresponding source companion: " + companion)
    run([tools() / "sign_update", "--account", ACCOUNT, "--verify", directory / "appcast.xml"])
    feed = ET.parse(directory / "appcast.xml")
    enclosure = feed.find(".//enclosure")
    dmg = directory / f"Tebo-{data['version']}.dmg"
    if enclosure is None or enclosure.attrib.get("url") != f"https://github.com/{REPOSITORY}/releases/download/v{data['version']}/{dmg.name}":
        raise RuntimeError("Update enclosure does not match this GitHub release")
    if feed.findtext(".//sparkle:version", namespaces=NS) != str(data["build"]) or enclosure.attrib.get("length") != str(dmg.stat().st_size):
        raise RuntimeError("Feed build or archive length mismatch")
    run([tools() / "sign_update", "--account", ACCOUNT, "--verify", dmg, enclosure.attrib["{" + NS["sparkle"] + "}edSignature"]])
    run(["xcrun", "stapler", "validate", dmg])
    run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmg])
    run(["gh", "release", "create", "v" + data["version"], "--repo", REPOSITORY, "--target", args.commit,
         "--draft", "--title", "Tebo " + data["version"], "--notes-file", directory / "release-notes.md",
         *[directory / name for name in data["assets"]], directory / "SHA256SUMS.txt"], cwd=ROOT)
    print("Draft created. Review and publish only after release approval.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build"); b.add_argument("--version", required=True); b.add_argument("--build", type=int, required=True)
    b.add_argument("--skip-verify", action="store_true", help="Use only immediately after the full verification gate passed")
    n = sub.add_parser("notarize"); n.add_argument("directory", type=Path); n.add_argument("--profile", default=os.environ.get("NOTARY_PROFILE", "tebo-notary"))
    d = sub.add_parser("draft"); d.add_argument("directory", type=Path); d.add_argument("--commit", required=True)
    args = parser.parse_args()
    {"build": build, "notarize": finalize, "draft": draft}[args.command](args)


if __name__ == "__main__":
    main()
