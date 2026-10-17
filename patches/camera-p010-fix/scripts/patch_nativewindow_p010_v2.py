"""Preserve all original format branches; add the Realme vendor-format branch."""
import hashlib
import struct
import sys
from pathlib import Path

src, dst = map(Path, sys.argv[1:])
b = bytearray(src.read_bytes())
assert hashlib.sha256(b).hexdigest() == '49320d4379fa926acf72fab24fd0f883285622aa160086c8f705de56a44ed77d'
assert b[0x88d8:0x88e0] == bytes.fromhex('282b8652c806a472')
phoff = struct.unpack_from('<Q', b, 32)[0]
phentsize, phnum = struct.unpack_from('<HH', b, 54)
execph = None
for i in range(phnum):
    off = phoff + i * phentsize
    typ, flags, fileoff, va, pa, filesz, memsz, align = struct.unpack_from('<IIQQQQQQ', b, off)
    if typ == 1 and flags == 5:
        assert fileoff == va == 0x8000 and filesz == memsz == 0x2c78
        execph = off
assert execph is not None
cave = 0xac78
assert b[cave:cave + 28] == bytes(28)

def branch(pc, dest, conditional=False):
    delta = dest - pc
    assert delta % 4 == 0
    if conditional:
        assert -(1 << 20) <= delta < (1 << 20)
        return 0x54000000 | (((delta // 4) & 0x7ffff) << 5)
    assert -(1 << 27) <= delta < (1 << 27)
    return 0x14000000 | ((delta // 4) & 0x3ffffff)

insns = [
    0x52800000 | (0x0c0a << 5) | 8,  # movz w8, #0x0c0a
    0x72a00000 | (0x7fa3 << 5) | 8,  # movk w8, #0x7fa3, lsl #16
    0x6b0802bf,                      # cmp w21, w8
    branch(cave + 12, 0x888c, True), # b.eq existing YCbCr path
    0x52800000 | (0x3159 << 5) | 8,  # original Y16 low half
    0x72a00000 | (0x2036 << 5) | 8,  # original Y16 high half
    branch(cave + 24, 0x88e0),       # original comparison and fallthrough
]
struct.pack_into('<II', b, 0x88d8, branch(0x88d8, cave), 0xd503201f)
struct.pack_into('<7I', b, cave, *insns)
# Extend only the existing executable segment, within its current mapped page.
struct.pack_into('<QQ', b, execph + 32, 0x2c78 + 28, 0x2c78 + 28)
dst.write_bytes(b)
print('output SHA256', hashlib.sha256(b).hexdigest())
print('trampoline:', ' '.join(f'{v:08x}' for v in insns))
