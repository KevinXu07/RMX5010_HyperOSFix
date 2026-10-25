#!/usr/bin/env python3
"""Regenerate the OS3-style empty AVB-off vbmeta trio (flags=3, no descriptors).

Recipe from OS3 v5 交接文档: 空头三件套 12K+4K+4K flags3 descriptors0.
Header per AvbVBMetaImageHeader (all fields big-endian per AVB spec).
"""
import struct, pathlib, sys

OUT = pathlib.Path("E:/code/modify/haotian_port_h19/vbmeta/avboff")
OUT.mkdir(parents=True, exist_ok=True)

def make_vbmeta(flags=3, release=b"haotian_port_h19 avboff", pad=4096):
    assert len(release) < 47
    h = bytearray(256)
    h[0:4]   = b"AVB0"
    struct.pack_into(">I", h, 4, 1)            # version_major
    struct.pack_into(">I", h, 8, 0)            # version_minor
    struct.pack_into(">Q", h, 12, 0)           # authentication_data_block_size
    struct.pack_into(">Q", h, 20, 0)           # auxiliary_data_block_size
    struct.pack_into(">I", h, 28, 0)           # algorithm_type = NONE
    # all offsets/sizes stay 0 (hash/signature/pubkey/descriptors)
    struct.pack_into(">Q", h, 112, 0)          # rollback_index
    struct.pack_into(">I", h, 120, flags)      # flags: 1=HASHTREE_DISABLED 2=VERIFICATION_DISABLED
    struct.pack_into(">I", h, 124, 0)          # rollback_index_location
    h[128:128+len(release)] = release          # release_string (47 bytes)
    # reserved 175..255 stay zero
    img = bytes(h)
    if len(img) % pad:
        img += b"\x00" * (pad - len(img) % pad)
    return img

sizes = {"vbmeta.img": 12288, "vbmeta_system.img": 4096, "vbmeta_vendor.img": 4096}
for name, total in sizes.items():
    img = make_vbmeta(pad=total)
    assert len(img) == total, (name, len(img))
    (OUT / name).write_bytes(img)
    # self-check
    d = (OUT / name).read_bytes()
    assert d[:4] == b"AVB0"
    be = lambda o, n=4: int.from_bytes(d[o:o+n], "big")
    assert be(120) == 3 and be(28) == 0 and be(12) == 0 and be(20) == 0
    print(f"{name}: {len(img)} bytes  magic=AVB0  flags={be(120)} (BE)  alg=NONE  descriptors=0")
print("AVBOFF_TRIO_DONE ->", OUT)
