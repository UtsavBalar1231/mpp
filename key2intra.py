"""Rewrite selected VP9 profile 2 key frames in an IVF file as hidden intra-only frames
(refresh_frame_flags 0xe0, reset_frame_context 3) followed by a show_existing_frame
of slot 5 in the same superframe. Everything after render_size, the compressed header
and the tile data are copied unchanged.

The other frames are renumbered so that the reference slots 0, 1, 2 become 5, 6, 7:
refresh_frame_flags and ref_frame_idx of the inter frames are patched in place (same bit
widths). The pictures decode unchanged. The point is that the low 5 bits of the intra-only
refresh_frame_flags are 0, which keeps the frame size that a parser without color_config()
misreads small.

usage: key2intra.py in.ivf out.ivf frame_index...
"""
import struct
import sys


class BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def bit(self):
        b = (self.data[self.pos >> 3] >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return b

    def bits(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v


class BitWriter:
    def __init__(self):
        self.bits = []

    def put(self, v, n):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def copy(self, data, start, end):
        for p in range(start, end):
            self.bits.append((data[p >> 3] >> (7 - (p & 7))) & 1)

    def tobytes(self):
        b = self.bits + [0] * (-len(self.bits) % 8)
        return bytes(int("".join(map(str, b[i:i + 8])), 2) for i in range(0, len(b), 8))


def parse_key_header(d):
    """Return dict with bit positions of a profile 2 key frame header."""
    r = BitReader(d)
    assert r.bits(2) == 2
    low, high = r.bit(), r.bit()
    profile = low | (high << 1)
    assert profile == 2, profile
    assert r.bit() == 0  # show_existing_frame
    assert r.bit() == 0  # key frame
    show = r.bit()
    err = r.bit()
    assert r.bits(24) == 0x498342
    cc_start = r.pos
    r.bit()  # ten_or_twelve
    cs = r.bits(3)
    assert cs != 7
    r.bit()  # color_range
    cc_end = r.pos
    size_start = r.pos
    w = r.bits(16) + 1
    h = r.bits(16) + 1
    if r.bit():
        r.bits(32)
    suffix_start = r.pos
    if not err:
        r.bit()
        r.bit()
    r.bits(2)
    # loop_filter_params
    r.bits(6)
    r.bits(3)
    if r.bit():
        if r.bit():
            for _ in range(4):
                if r.bit():
                    r.bits(7)
            for _ in range(2):
                if r.bit():
                    r.bits(7)
    # quantization_params
    r.bits(8)
    for _ in range(3):
        if r.bit():
            r.bits(5)
    # segmentation_params
    if r.bit():
        if r.bit():
            for _ in range(7):
                if r.bit():
                    r.bits(8)
            if r.bit():
                for _ in range(3):
                    if r.bit():
                        r.bits(8)
        if r.bit():
            r.bit()
            for _ in range(8):
                for bits, signed in ((8, 1), (6, 1), (2, 0), (0, 0)):
                    if r.bit():
                        r.bits(bits)
                        if signed:
                            r.bit()
    # tile_info
    sb64 = (((w + 7) >> 3) + 7) >> 3
    mn = 0
    while (64 << mn) < sb64:
        mn += 1
    mx = 1
    while (sb64 >> mx) >= 4:
        mx += 1
    mx -= 1
    t = mn
    while t < mx:
        if r.bit():
            t += 1
        else:
            break
    if r.bit():
        r.bit()
    hdr_size_pos = r.pos
    comp_size = r.bits(16)
    end = r.pos
    ubytes = (end + 7) >> 3
    return dict(err=err, show=show, cc_start=cc_start, cc_end=cc_end, size_start=size_start,
                suffix_start=suffix_start, end=end, ubytes=ubytes, comp_size=comp_size,
                hdr_size_pos=hdr_size_pos, w=w, h=h)


def convert(d):
    p = parse_key_header(d)
    assert p["ubytes"] + p["comp_size"] < len(d)
    bw = BitWriter()
    bw.put(2, 2)
    bw.put(0, 1)
    bw.put(1, 1)  # profile 2: low 0, high 1
    bw.put(0, 1)  # show_existing_frame
    bw.put(1, 1)  # non-key
    bw.put(0, 1)  # show_frame = 0
    bw.put(p["err"], 1)
    bw.put(1, 1)  # intra_only
    if not p["err"]:
        bw.put(3, 2)  # reset_frame_context: reset all
    bw.put(0x498342, 24)
    bw.copy(d, p["cc_start"], p["cc_end"])  # bitdepth, color_space, color_range
    bw.put(0xE0, 8)  # refresh_frame_flags: slots 5-7, the renumbered slots 0-2
    bw.copy(d, p["size_start"], p["end"])  # frame size, render size, rest of header
    out = bw.tobytes() + d[p["ubytes"]:]
    return out, p


def remap_inter(d):
    """Renumber slots 0,1,2 -> 5,6,7 in a non-key, shown, non-error-resilient inter frame."""
    r = BitReader(d)
    assert r.bits(2) == 2
    assert (r.bit() | (r.bit() << 1)) == 2
    assert r.bit() == 0  # show_existing_frame
    if r.bit() == 0:  # key frame
        return d
    assert r.bit() == 1  # show_frame
    assert r.bit() == 0  # error_resilient_mode
    r.bits(2)  # reset_frame_context
    out = bytearray(d)

    def put(pos, v, n):
        for i in range(n):
            bit = (v >> (n - 1 - i)) & 1
            p = pos + i
            out[p >> 3] = (out[p >> 3] & ~(0x80 >> (p & 7))) | (bit << (7 - (p & 7)))

    assert r.pos == 10
    assert r.bits(8) == 0x01
    put(10, 0x20, 8)
    pos = 18
    for _ in range(3):
        idx = BitReader(d)
        idx.pos = pos
        v = idx.bits(3)
        assert v in (0, 1, 2)
        put(pos, v + 5, 3)
        pos += 4
    return bytes(out)


def superframe(frames):
    mag = 4
    idx = bytes([0xC0 | ((mag - 1) << 3) | (len(frames) - 1)])
    idx_full = idx + b"".join(struct.pack("<I", len(f)) for f in frames) + idx
    return b"".join(frames) + idx_full


def main():
    src, dst = sys.argv[1], sys.argv[2]
    targets = {int(x) for x in sys.argv[3:]}
    data = open(src, "rb").read()
    hdr = bytearray(data[:32])
    pos = 32
    out = bytearray()
    n = 0
    while pos < len(data):
        sz, pts = struct.unpack("<IQ", data[pos:pos + 12])
        pkt = data[pos + 12:pos + 12 + sz]
        pos += 12 + sz
        if n in targets:
            conv, p = convert(pkt)
            show_existing = bytes([0b10011101])  # marker 10, profile bits 0 1, show_existing 1, slot 101
            pkt = superframe([conv, show_existing])
            sys.stderr.write("packet %d: key %dx%d -> intra-only + show_existing, %d -> %d bytes\n" % (n, p["w"], p["h"], sz, len(pkt)))
        else:
            pkt = remap_inter(pkt)
        out += struct.pack("<IQ", len(pkt), pts) + pkt
        n += 1
    open(dst, "wb").write(bytes(hdr) + bytes(out))


main()
