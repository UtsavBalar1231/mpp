#!/usr/bin/env python3
"""Merge IVF frames into temporal units: a frame that does not start with a temporal delimiter OBU is appended to the previous one.
Usage: ivf-tu.py in.ivf out.ivf"""
import struct, sys
d = open(sys.argv[1], 'rb').read()
hl = struct.unpack_from('<H', d, 6)[0]
pos = hl; tus = []
while pos + 12 <= len(d):
    n = struct.unpack_from('<I', d, pos)[0]; fr = d[pos + 12:pos + 12 + n]; pos += 12 + n
    if tus and ((fr[0] >> 3) & 15) != 2:
        tus[-1] += fr
    else:
        tus.append(bytearray(fr))
h = bytearray(d[:hl]); struct.pack_into('<I', h, 24, len(tus))
with open(sys.argv[2], 'wb') as f:
    f.write(h)
    for i, t in enumerate(tus):
        f.write(struct.pack('<IQ', len(t), i)); f.write(t)
print(sys.argv[2], len(tus), 'TUs')
