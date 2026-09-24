#!/bin/bash
# build-fixture-tree.sh — build a deterministic fixture tree for czkawka tool captures.
# Usage: ./scripts/build-fixture-tree.sh [output-dir]
# Default output dir: ${TMPDIR:-/tmp}/superclean-fixture-tree  (recreated on every run)
# Prints "FIXTURE_TREE=<dir>" as its final line so callers can parse the path.
#
# The tree exercises every czkawka tool we ship:
#   dup           exact dup pair (>8KB), dup trio, same-size-different-content pair
#   empty-folders empty directory
#   empty-files   0-byte file (+ 1-byte control)
#   big           all of the above; biggest first
#   temp          *.tmp / *.bak / *.part files
#   symlinks      broken symlink
#   broken        truncated (corrupt) PDF
#   ext           JPEG bytes named .txt ; text bytes named .JPG
#   bad-names     leading/trailing spaces + uppercase extension
#   image         same image at 2 sizes + brightness variant
#   music         two mp3s sharing title/artist tags (+ byte copy)
#   video         short testsrc mp4 + byte copy
#
# Media is generated with ffmpeg/sips; the PDF is written by a tiny embedded python3
# generator with correct xref offsets. Everything is deterministic.

set -euo pipefail
cd "$(dirname "$0")/.."

TREE="${1:-${TMPDIR:-/tmp}/superclean-fixture-tree}"
case "$TREE" in
  */superclean-fixture-tree) ;;
  *) echo "build-fixture-tree: refusing path that is not a superclean-fixture-tree dir: $TREE" >&2; exit 2 ;;
esac

# Clean/recreate ONLY our own fixture dir. find -delete handles the symlink safely.
if [[ -e "$TREE" ]]; then
  find "$TREE" -mindepth 1 -delete
else
  mkdir -p "$TREE"
fi

die() { echo "build-fixture-tree ERROR: $1" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found"
command -v sips >/dev/null 2>&1 || die "sips not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# make_pattern <path> <size-bytes> <seed-text>: deterministic filler file of exact size.
# Uses python3 instead of `yes | head` because the latter trips `set -o pipefail`
# (head exits first, yes dies with SIGPIPE -> pipeline status 141 -> abort).
make_pattern() {
  local path="$1" size="$2" seed="$3"
  python3 - "$path" "$size" "$seed" <<'PYEOF'
import sys
path, size, seed = sys.argv[1], int(sys.argv[2]), sys.argv[3]
line = (seed + "\n").encode()
out = bytearray()
while len(out) < size:
    out += line[: size - len(out)]
with open(path, "wb") as f:
    f.write(out)
PYEOF
}

mkdir -p "$TREE/docs" "$TREE/photos" "$TREE/dup" "$TREE/misc" "$TREE/media" "$TREE/emptydir" "$TREE/deep/nested_emptydir"

# --- docs: valid PDF + corrupt PDF ------------------------------------------------
python3 - "$TREE/docs/report.pdf" <<'PYEOF'
import sys
def build():
    objects = []
    def add(num, body):
        objects.append((num, body))
    add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
    add(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    add(3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>")
    stream = b"BT /F1 24 Tf 100 700 Td (SuperClean fixture PDF) Tj ET"
    add(4, b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream")
    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for num, body in objects:
        offsets[num] = len(out)
        out += str(num).encode() + b" 0 obj\n" + body + b"\nendobj\n"
    xref_pos = len(out)
    n = len(objects) + 1
    out += b"xref\n0 %d\n" % n
    out += b"0000000000 65535 f \n"
    for num, _ in objects:
        out += b"%010d 00000 n \n" % offsets[num]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (n, xref_pos)
    return bytes(out)
with open(sys.argv[1], "wb") as f:
    f.write(build())
print("wrote", sys.argv[1])
PYEOF
pdf_size="$(stat -f%z "$TREE/docs/report.pdf")"
head -c $((pdf_size * 3 / 5)) "$TREE/docs/report.pdf" > "$TREE/docs/broken.pdf"   # truncated -> unparseable
make_pattern "$TREE/docs/notes.txt" 2000 "SuperClean docs notes line"

# --- photos: same image at two sizes + brightness variant --------------------------
# NOTE: czkawka image tool default minimal-file-size is 16384 bytes (checked in
# czkawka_cli/src/commands.rs, SimilarImagesArgs) — all three must exceed it or the
# tool silently skips them (captured as an empty [] group, which is why an earlier
# smaller fixture produced no image matches).
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "gradients=s=1280x960:c0=navy:c1=orange:x0=0:y0=0:x1=1280:y1=960" -frames:v 1 -q:v 2 "$TREE/photos/sunset.jpg" || die "ffmpeg jpeg"
# Downscale with ffmpeg (not sips): sips -Z 640 re-encodes at a quality whose file
# size lands under czkawka's 16384-byte image-tool minimum. 960x720 at -q:v 1 is
# usually above it but mjpeg sizes are nondeterministic across ffmpeg builds, so we
# also embed a 9KB COM comment segment (padding bytes, zero effect on pixels/hash)
# to keep the file deterministically > 16KB.
PAD="$(python3 -c "print('x'*9216)")"
ffmpeg -hide_banner -loglevel error -y -i "$TREE/photos/sunset.jpg" -vf "scale=960:720" -q:v 1 \
  -metadata comment="$PAD" "$TREE/photos/sunset_small.jpg" || die "ffmpeg downscale"
ffmpeg -hide_banner -loglevel error -y -i "$TREE/photos/sunset.jpg" -vf "eq=brightness=0.1" "$TREE/photos/sunset_bright.jpg" || die "ffmpeg brighten"

# --- dup: exact pairs and trios (all > 8KB), same-size-different-content -----------
make_pattern "$TREE/dup/pair_a.bin"      16384 "SuperClean pair A duplicate payload line 0123456789"
cp "$TREE/dup/pair_a.bin" "$TREE/dup/pair_a_copy.bin"
make_pattern "$TREE/dup/trio_1.bin"      12288 "SuperClean trio payload line 9876543210"
cp "$TREE/dup/trio_1.bin" "$TREE/dup/trio_2.bin"
cp "$TREE/dup/trio_1.bin" "$TREE/dup/trio_3.bin"
make_pattern "$TREE/dup/samesize_a.txt"  10000 "AAAAAA alpha content that differs from B"
make_pattern "$TREE/dup/samesize_b.txt"  10000 "BBBBBB beta content that differs from A"

# --- misc: empty file, 1-byte control, temp files, bad-extension files, bad name ---
: > "$TREE/misc/empty.dat"                       # 0 bytes
printf '\n' > "$TREE/misc/blank.txt"             # 1 byte (not zero-byte-empty)
make_pattern "$TREE/misc/notes.tmp"   512 "SuperClean temp file"
make_pattern "$TREE/misc/backup.bak"  512 "SuperClean backup file"
make_pattern "$TREE/misc/draft.part"  512 "SuperClean partial download"
make_pattern "$TREE/misc/editor.save" 512 "SuperClean editor buffer"

cp "$TREE/photos/sunset.jpg" "$TREE/misc/fake_image.txt"   # JPEG bytes, .txt extension
make_pattern "$TREE/misc/ bad name .JPG" 300 "SuperClean text bytes wearing a JPG extension"   # spaces + uppercase ext

# --- symlink: broken link -----------------------------------------------------------
ln -s "$TREE/missing-target.txt" "$TREE/broken-link"

# --- media: short mp4 + copy, tagged mp3s + copy ------------------------------------
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=15 -pix_fmt yuv420p "$TREE/media/clip.mp4" || die "ffmpeg mp4"
cp "$TREE/media/clip.mp4" "$TREE/media/clip_copy.mp4"

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=2" -c:a libmp3lame -b:a 128k \
  -metadata title="Fixtune Alpha" -metadata artist="Fixture Artist" "$TREE/media/song_a.mp3" || die "ffmpeg mp3 a"
cp "$TREE/media/song_a.mp3" "$TREE/media/song_a_copy.mp3"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=880:duration=2" -c:a libmp3lame -b:a 128k \
  -metadata title="Fixtune Alpha" -metadata artist="Fixture Artist" "$TREE/media/song_b.mp3" || die "ffmpeg mp3 b"

echo "FIXTURE_TREE=$TREE"
