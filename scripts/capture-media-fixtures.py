#!/usr/bin/env python3
"""Capture read-only Krokiet tool output from the real bundled Czkawka engine."""
import json, pathlib, shutil, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parent.parent
root = pathlib.Path(tempfile.mkdtemp(prefix="tebo-media-fixture-"))
images = root / "photos"; images.mkdir()
videos = root / "videos"; videos.mkdir()
swift = root / "image.swift"
swift.write_text(r'''import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Tebo fixture camera"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"], kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.0, kCGImagePropertyGPSLongitudeRef: "E"]]
CGImageDestinationAddImage(dest, image, properties as CFDictionary)
precondition(CGImageDestinationFinalize(dest))
''')
subprocess.run(["swift", "-module-cache-path", str(root / "modules"), str(swift), str(images / "metadata.jpg")], check=True)
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg: raise SystemExit("ffmpeg is required to capture video fixtures")
subprocess.run([ffmpeg,"-hide_banner","-loglevel","error","-f","lavfi","-i","color=c=red:s=160x100:d=1","-vf","pad=200:140:20:20:black","-c:v","libx264","-pix_fmt","yuv420p",str(videos/"bordered.mp4")],check=True)
inputs = repo / "Tests/Fixtures/media"; inputs.mkdir(exist_ok=True)
shutil.copyfile(images / "metadata.jpg", inputs / "metadata.jpg")
shutil.copyfile(videos / "bordered.mp4", inputs / "bordered.mp4")
out = repo / "Tests/Fixtures/czkawka"
for name, folder, command in [("exif", images, ["exif-remover"]), ("video-transcode",videos,["video-optimizer"]), ("video-crop",videos,["video-optimizer"])]:
    args=[str(repo/"Engines/czkawka_cli"),*command,"-d",str(folder),"-p",str(out/(name+".json")),"-N","-M","-W"]
    if name=="video-transcode": args += ["transcode"]
    if name=="video-crop": args += ["crop", "-z", "1"]
    assert not set(args).intersection(["-F","-D","-y","--overwrite-original","--fix-exif","--fix-videos"])
    result=subprocess.run(args,capture_output=True,text=True,timeout=90)
    (out/(name+".log")).write_text("# Read-only real engine capture\n# command: "+repr(args)+"\n"+result.stdout+result.stderr)
    result.check_returncode()
    data=json.loads((out/(name+".json")).read_text())
    print(name, json.dumps(data)[:3000])
print("FIXTURE_ROOT="+str(root))
