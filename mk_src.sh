#!/bin/bash
set -e
cd "$(dirname "$0")"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=328x288:rate=30:duration=1,noise=alls=3:allf=t" -frames:v 30 -pix_fmt yuv420p10le -f rawvideo src_328x288_10le.yuv
# single-layer profile 2, key frame every 10 frames, no hidden frames
ffmpeg -v error -y -f rawvideo -pix_fmt yuv420p10le -s 328x288 -r 30 -i src_328x288_10le.yuv \
  -c:v libvpx-vp9 -profile:v 2 -pix_fmt yuv420p10le -b:v 800k -g 10 -keyint_min 10 \
  -auto-alt-ref 0 -lag-in-frames 0 -deadline good -cpu-used 2 -f ivf orig_p2.ivf
