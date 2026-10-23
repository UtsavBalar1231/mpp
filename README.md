Test streams for the AV1 `current_operating_point` index fix in `av1d_parser2_syntax()`.

- `in/`: 320x240, 60-frame streams made with libaom 3.15.2 `examples/svc_encoder_rtc` (`mk-svc.sh`), plus a 1080p non-scalable control (`av1_8_ctrl.ivf`).
  - `l1t1`: no layers. `l1t2`, `l1t3`: temporal layers. `l2t1`, `l2t3`, `l3t1`: spatial layers.
  - The `l2*`/`l3*` files have one IVF frame per layer frame, as `svc_encoder_rtc` writes them. The `*_tu` files have one IVF frame per temporal unit (`ivf-tu.py`).
- `ref/`: libdav1d decode of each stream (operating point 0, highest spatial layer), one md5 per NV12 frame, made with `mk-ref.sh`.
- `board.sh`: runs `mpi_dec_test -t 16777224 -f 0` from two MPP builds on every stream and compares the output with `ref/` frame by frame.
- `av1d_parse_host.c`: host-only harness that feeds an IVF to `mpp_parser_prepare()`/`mpp_parser_parse()` without hardware, for AddressSanitizer runs.
