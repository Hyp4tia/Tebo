#!/usr/bin/env python3
"""Build self-contained arm64 ffmpeg/ffprobe for Tebo's macOS 14 target.

All inputs are exact upstream snapshots. Builds stay in .build; no installed
Homebrew libraries are copied into the app. The source companion includes the
exact snapshots, this recipe and manifest for distribution alongside the DMG.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "ffmpeg": {"url": "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz", "sha256": "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"},
    "x264": {"git": "https://code.videolan.org/videolan/x264.git", "commit": "b35605ace3ddf7c1a5d67a2eb553f034aef41d55"},
    "x265": {"url": "https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz", "sha256": "83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121"},
    "vpx": {"url": "https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz", "sha256": "7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c"},
    "aom": {"git": "https://aomedia.googlesource.com/aom", "commit": "af3dc9aadc793c1b00edc003e3fc19a44fdeb574"},
    "opus": {"url": "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz", "sha256": "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"},
}


def run(args, cwd=None, env=None):
    print("Running:", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def obtain(name, spec, base):
    print("Verifying source:", name, flush=True)
    dest = base / name
    if "git" in spec:
        if not (dest / ".git").exists():
            dest.mkdir(parents=True, exist_ok=True)
            run(["git", "init", dest])
            run(["git", "-C", dest, "remote", "add", "origin", spec["git"]])
            run(["git", "-C", dest, "fetch", "--depth", "1", "origin", spec["commit"]])
            run(["git", "-C", dest, "checkout", "--detach", "FETCH_HEAD"])
        actual = subprocess.check_output(["git", "-C", str(dest), "rev-parse", "HEAD"], text=True).strip()
        if actual != spec["commit"]:
            raise RuntimeError("Wrong source revision: " + name)
    else:
        archive = base / (name + "-" + spec["url"].split("/")[-1])
        if not archive.exists():
            with urllib.request.urlopen(spec["url"], timeout=90) as response, archive.open("wb") as out:
                shutil.copyfileobj(response, out)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != spec["sha256"]:
            raise RuntimeError("Source digest mismatch: " + name)
        if not dest.exists():
            unpack = base / (name + "-unpack")
            unpack.mkdir(exist_ok=True)
            with tarfile.open(archive) as tar:
                tar.extractall(unpack, filter="data")
            children = list(unpack.iterdir())
            if len(children) != 1 or not children[0].is_dir():
                raise RuntimeError("Unexpected source archive layout: " + name)
            children[0].rename(dest)
    return dest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    args = parser.parse_args()
    jobs = str(max(1, min(16, args.jobs)))
    base = ROOT / ".build/video-sources"
    work = ROOT / ".build/video-work"
    prefix = ROOT / ".build/video-helpers"
    for p in (base, work, prefix):
        p.mkdir(parents=True, exist_ok=True)
    sources = {n: obtain(n, s, base) for n, s in SOURCES.items()}
    env = os.environ.copy()
    env.update({"MACOSX_DEPLOYMENT_TARGET": "14.0", "CC": "clang", "CXX": "clang++",
                "CFLAGS": "-O2 -mmacosx-version-min=14.0", "CXXFLAGS": "-O2 -mmacosx-version-min=14.0",
                "LDFLAGS": "-mmacosx-version-min=14.0", "PKG_CONFIG_PATH": str(prefix / "lib/pkgconfig"),
                "PKG_CONFIG_LIBDIR": str(prefix / "lib/pkgconfig"), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"})

    def autoconf(name, options):
        build = work / name
        build.mkdir(exist_ok=True)
        stamp = build / ".tebo-built"
        if stamp.exists():
            return
        run([sources[name] / "configure", "--prefix=" + str(prefix)] + options, build, env)
        run(["make", "-j" + jobs], build, env)
        run(["make", "install"], build, env)
        stamp.touch()

    def cmake(name, path, options):
        build = work / name
        stamp = build / ".tebo-built"
        if stamp.exists():
            return
        run(["cmake", "-S", path, "-B", build, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
             "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DCMAKE_OSX_ARCHITECTURES=arm64"] + options, env=env)
        run(["cmake", "--build", build, "--parallel", jobs], env=env)
        run(["cmake", "--install", build], env=env)
        stamp.touch()

    autoconf("x264", ["--enable-static", "--enable-pic", "--disable-cli", "--disable-opencl", "--disable-lsmash", "--disable-swscale", "--disable-ffms"])
    cmake("x265", sources["x265"] / "source", ["-DENABLE_SHARED=OFF", "-DENABLE_CLI=OFF", "-DENABLE_ASSEMBLY=OFF"])
    autoconf("vpx", ["--target=arm64-darwin23-gcc", "--disable-shared", "--enable-static", "--enable-pic",
                       "--disable-examples", "--disable-tools", "--disable-unit-tests", "--enable-vp9-highbitdepth"])
    cmake("aom", sources["aom"], ["-DBUILD_SHARED_LIBS=OFF", "-DENABLE_TESTS=OFF", "-DENABLE_EXAMPLES=OFF", "-DENABLE_TOOLS=OFF", "-DENABLE_DOCS=OFF"])
    autoconf("opus", ["--disable-shared", "--enable-static", "--disable-doc", "--disable-extra-programs"])
    autoconf("ffmpeg", ["--enable-gpl", "--enable-version3", "--disable-shared", "--enable-static", "--disable-autodetect",
                          "--disable-ffplay", "--disable-doc", "--disable-debug", "--disable-network", "--disable-indevs", "--disable-outdevs",
                          "--disable-protocols", "--enable-protocol=file,pipe", "--enable-libx264", "--enable-libx265", "--enable-libvpx",
                          "--enable-libaom", "--enable-libopus", "--enable-videotoolbox", "--enable-audiotoolbox",
                          "--pkg-config-flags=--static", "--extra-libs=-lc++"])
    for name in ("ffmpeg", "ffprobe"):
        executable = prefix / "bin" / name
        linked = subprocess.check_output(["otool", "-L", str(executable)], text=True)
        dependencies = [line.strip().split(" (", 1)[0] for line in linked.splitlines()[1:]]
        if any(not p.startswith(("/usr/lib/", "/System/Library/")) for p in dependencies):
            raise RuntimeError("Non-system dependency in " + name + ": " + linked)
        run([executable, "-version"])
    encoders = subprocess.check_output([str(prefix / "bin/ffmpeg"), "-hide_banner", "-encoders"], text=True, stderr=subprocess.DEVNULL)
    for codec in ("libx264", "libx265", "libaom-av1", "libvpx-vp9", "libopus"):
        if codec not in encoders:
            raise RuntimeError("Missing release encoder: " + codec)
    (prefix / "sources.json").write_text(json.dumps(SOURCES, indent=2) + "\n")
    shutil.copy2(__file__, base / "build-video-helpers.py")
    (base / "sources.json").write_text(json.dumps(SOURCES, indent=2) + "\n")
    with tarfile.open(prefix / "third-party-sources.tar.xz", "w:xz") as tar:
        def source_filter(info):
            return None if "/.git/" in info.name or info.name.endswith("/.git") else info
        for name in SOURCES:
            tar.add(sources[name], arcname=name, filter=source_filter)
        tar.add(base / "build-video-helpers.py", arcname="build-video-helpers.py")
        tar.add(base / "sources.json", arcname="sources.json")
    print("Portable video helpers ready:", prefix, flush=True)


if __name__ == "__main__":
    main()
