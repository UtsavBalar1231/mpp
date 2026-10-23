#!/bin/bash
# Decodes every stream in in/ with ffmpeg + libdav1d (operating point 0, highest spatial layer only) and writes
# ref/<name>.md5: one md5 per decoded NV12 frame, plus ref/<name>.info with "WxH frames".
set -e
cd "$(dirname "$0")"
mkdir -p ref
for f in in/*.ivf; do
	n=$(basename $f .ivf)
	wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x $f)
	w=${wh%x*}; h=${wh#*x}
	ffmpeg -v error -y -c:v libdav1d -i $f -fps_mode passthrough -f rawvideo -pix_fmt nv12 - |
		python3 -I -c '
import sys, hashlib
w, h = int(sys.argv[1]), int(sys.argv[2]); fs = w * h * 3 // 2
d = sys.stdin.buffer.read()
assert len(d) % fs == 0
for i in range(0, len(d), fs):
    print(hashlib.md5(d[i:i + fs]).hexdigest())
' $w $h > ref/$n.md5
	echo "${w}x${h} $(wc -l < ref/$n.md5)" > ref/$n.info
	echo "$n $(cat ref/$n.info)"
done
# The per-layer-packet files (two or three IVF frames per temporal unit, as svc_encoder_rtc writes them) are not valid
# one-TU-per-frame IVF for ffmpeg; they carry the same OBUs as the *_tu files, so they use the same reference.
for n in l2t1 l2t3 l3t1; do
	cp ref/${n}_tu.md5 ref/$n.md5
	cp ref/${n}_tu.info ref/$n.info
done
