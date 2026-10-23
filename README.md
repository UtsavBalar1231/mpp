Test data for the VP9 intra-only colour config issue in rockchip-linux/mpp.

- `p2_ctrl.ivf`: 30 frames of 328x288 VP9 profile 2 (10-bit 4:2:0) from libvpx, key frame every 10 frames.
- `p2_intra.ivf`: the same stream with the key frames at packets 10 and 20 rewritten by `key2intra.py` as hidden intra-only frames followed by `show_existing_frame`, with the reference slots renumbered. It decodes to the same frames as `p2_ctrl.ivf` in libavcodec and libvpx.
- `p2.framemd5`: libavcodec reference, `ffmpeg -c:v vp9 -i p2_intra.ivf -pix_fmt yuv420p10le -f framemd5`.
- `mk_src.sh`: makes the source stream and runs the rewrite.
