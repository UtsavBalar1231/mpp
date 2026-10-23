#!/bin/bash
# libdav1d reference for every stream in in/: decodes with ffmpeg -c:v libdav1d (operating point 0, highest spatial
# layer only, frames at their own size) and writes ref/<name>.frames with one "W H md5" line per frame. The md5 is
# taken over the frame in the layout mpi_dec_test -o writes for NV12: W x H luma, then H/2 rows of W bytes of CbCr.
set -e
cd "$(dirname "$0")"
mkdir -p ref raw
for f in in/*.ivf; do
	n=$(basename $f .ivf)
	case $n in l2t1|l2t3|l3t1) continue ;; esac
	ffprobe -v error -c:v libdav1d -select_streams v:0 -show_entries frame=width,height -of csv=p=0:s=x $f > raw/$n.sizes
	ffmpeg -v error -y -c:v libdav1d -i $f -noautoscale -fps_mode passthrough -f rawvideo -pix_fmt yuv420p - |
		python3 -I -c '
import sys, hashlib
sizes = [tuple(map(int, l.split("x"))) for l in open(sys.argv[1]) if l.strip()]
d = sys.stdin.buffer.read()
off = 0
for w, h in sizes:
    cw, ch = (w + 1) // 2, (h + 1) // 2
    y = d[off:off + w * h]; off += w * h
    u = d[off:off + cw * ch]; off += cw * ch
    v = d[off:off + cw * ch]; off += cw * ch
    c = bytearray()
    for r in range(h // 2):
        row = bytearray(2 * cw)
        row[0::2] = u[r * cw:(r + 1) * cw]
        row[1::2] = v[r * cw:(r + 1) * cw]
        c += row[:w]
    print(w, h, hashlib.md5(y + bytes(c)).hexdigest())
assert off == len(d), (off, len(d))
' raw/$n.sizes > ref/$n.frames
	echo "$n $(wc -l < ref/$n.frames) frames, sizes: $(awk '{print $1"x"$2}' ref/$n.frames | sort -u | tr '\n' ' ')"
done
# The per-layer-packet files (two or three IVF frames per temporal unit, as svc_encoder_rtc writes them) carry the
# same OBUs as the *_tu files, so they use the same reference.
for n in l2t1 l2t3 l3t1; do
	cp ref/${n}_tu.frames ref/$n.frames
done
