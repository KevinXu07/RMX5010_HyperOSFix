"""APK signing-block helpers for APKs baked into system images.

PMS does not verify content digests of APKs on system partitions, but it still
reads the certificates from the v2/v3 signing block and refuses targetSdk>=30
APKs whose resources.arsc is not stored uncompressed on a 4-byte boundary
(docs/模块改动入镜像可行性.md).  A modified APK therefore has to be repacked as:

    apk_sigblock.py strip  modified.apk  unsigned.zip
    zipalign -p -f 4 unsigned.zip aligned.zip
    apk_sigblock.py splice aligned.zip original.apk  out.apk
    apk_sigblock.py check  out.apk

  strip  <in.apk> <out.zip>             drop the signing block (fixes the CD offset)
  splice <zip> <block-src.apk> <out>    insert block-src's signing block before the CD
  check  <apk>...                       signing block ids + resources.arsc alignment;
                                        exits 1 if a block is missing or arsc is misaligned
"""
import struct
import sys
import zipfile

IDS = {0x7109871a: 'v2', 0xf05368c0: 'v3', 0x1b93ad61: 'v3.1', 0x42726577: 'verity-pad'}


def eocd(d):
    i = d.rfind(b'PK\x05\x06')
    return i, struct.unpack('<I', d[i + 16:i + 20])[0]


def block_range(d):
    _, cd = eocd(d)
    if d[cd - 16:cd] != b'APK Sig Block 42':
        return None
    size = struct.unpack('<Q', d[cd - 24:cd - 16])[0]
    return cd - size - 8, cd


def set_cd(d, new_cd):
    i, _ = eocd(d)
    return d[:i + 16] + struct.pack('<I', new_cd) + d[i + 20:]


def strip(d):
    r = block_range(d)
    if not r:
        return d
    a, cd = r
    return set_cd(d[:a] + d[cd:], a)


def splice(z, src):
    r = block_range(src)
    if not r:
        raise SystemExit('block source has no APK signing block')
    blk = src[r[0]:r[1]]
    z = strip(z)
    _, cd = eocd(z)
    return set_cd(z[:cd] + blk + z[cd:], cd + len(blk))


def block_ids(d):
    r = block_range(d)
    if not r:
        return []
    pos, end, out = r[0] + 8, r[1] - 24, []
    while pos < end:
        ln = struct.unpack('<Q', d[pos:pos + 8])[0]
        out.append(IDS.get(struct.unpack('<I', d[pos + 8:pos + 12])[0], 'other'))
        pos += 8 + ln
    return out


def check(path):
    d = open(path, 'rb').read()
    z = zipfile.ZipFile(path)
    ids = block_ids(d)
    ok = 'v2' in ids or 'v3' in ids
    arsc = 'none'
    try:
        zi = z.getinfo('resources.arsc')
        h = zi.header_offset
        n, e = struct.unpack('<HH', d[h + 26:h + 30])
        off = h + 30 + n + e
        aligned = zi.compress_type == 0 and off % 4 == 0
        arsc = 'aligned' if aligned else 'MISALIGNED/compressed'
        ok = ok and aligned
    except KeyError:
        pass
    print(f'{"OK  " if ok else "BAD "} {path}: block={ids or "NONE"} arsc={arsc}')
    return ok


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'strip':
        open(args[1], 'wb').write(strip(open(args[0], 'rb').read()))
    elif cmd == 'splice':
        open(args[2], 'wb').write(splice(open(args[0], 'rb').read(), open(args[1], 'rb').read()))
    elif cmd == 'check':
        sys.exit(0 if all([check(p) for p in args]) else 1)
    else:
        raise SystemExit(__doc__)
