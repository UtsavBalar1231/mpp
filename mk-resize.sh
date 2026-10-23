#!/bin/bash
# Single-layer AV1 streams with reference scaling (no SVC), libaom aomenc 3.15.2, 320x240, 60 frames.
set -e
cd "$(dirname "$0")"
S=$(cd .. && pwd)
E=$S/av1op/aom-build/aomenc
SRC=$S/av1op/src/testsrc.y4m
mkdir -p in raw
enc() { # name extra-args...
	local n=$1; shift
	$E --rt --cpu-used=8 --lag-in-frames=0 --kf-max-dist=9999 --end-usage=cbr --target-bitrate=300 \
		--limit=60 --ivf "$@" -o in/$n.ivf $SRC > raw/$n.log 2>&1
}
# key frame at half size, inter frames at full size: the first inter frame is larger than the key frame
enc rs_kfsmall --resize-mode=1 --resize-kf-denominator=16 --resize-denominator=8
# key frame at full size, inter frames at half size: scaled references, no frame larger than the key frame
enc rs_kfbig --resize-mode=1 --resize-kf-denominator=8 --resize-denominator=16
# random size per frame (denominator 8..16)
enc rs_random --resize-mode=2
ls -l in/rs_*.ivf
