Test streams for the AV1 per-slot CDF/colmv buffer reallocation on frame size growth (VDPU383/VDPU384B HAL).

- `in/`: 60-frame libaom 3.15.2 streams.
  - `mk-svc.sh` makes the `l*` SVC streams with `examples/svc_encoder_rtc`. `l1t*` have no spatial layers. `l2t1`/`l3t1` have an enhancement layer that predicts from the base layer. `l2t3` has an enhancement layer that predicts only from itself after the key unit. The `*_tu` files have one IVF frame per temporal unit (`ivf-tu.py`).
  - `mk-resize.sh` makes the `rs_*` single-layer streams with `aomenc --resize-mode`. In `rs_kfbig` the key frame is larger than the inter frames, in `rs_kfsmall` it is smaller, and `rs_random` changes size per frame.
  - `av1_8_ctrl.ivf` is a 1080p non-scalable control.
- `ref/`: per-frame size and md5 of the libdav1d decode (operating point 0, highest spatial layer, frames at their own size), made with `mk-ref.sh`.
- `board-scale.sh`: runs `mpi_dec_test -t 16777224 -f 0` from one or more MPP builds on every stream, then prints the frames that match `ref/` and the first frame that does not.
