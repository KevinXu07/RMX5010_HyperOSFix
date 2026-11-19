#!/usr/bin/env python3
"""Repack a modified system APK so it keeps the original signing block AND
the original content length.

Why (docs/模块改动入镜像可行性.md §2.2): PMS does not verify content digests of
APKs on system partitions, but when the APK file changed it re-collects the
certificates, and ApkSignatureVerifier then checks the VERITY_CHUNKED_SHA256
(0x0421) content digest's recorded source length against the actual APK size
minus the signing block.  An APK signed with that digest (the ColorOS wallet
set; Settings has only 0x0103) whose length changed fails with
"Failed to collect certificates ... using APK Signature Scheme v3" and the
package silently disappears at boot.

    apk_repack.py <original.apk> <patched.zip> <out.apk>

  - every entry whose CRC and size match the original is copied raw (same
    compressed bytes);
  - changed and new entries come from patched.zip, stored or deflated as the
    patched zip has them (deflate: the smaller of zlib level 9 and 7-Zip);
  - stored entries are aligned like zipalign -p (4, .so to 4096);
  - the content is padded to exactly the original length with central-directory
    extra fields (id 0x5250, ignored by zip readers) and the EOCD comment;
  - the original signing block is spliced back.
With a 0x0421 digest it fails if the patched content is larger than the
original (shrink it first).  Without one there is no length to match: the
content may grow and is not padded; the raw copy still keeps unchanged entries
byte-identical, so the APK only grows by what actually changed.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

PAD_ID = 0x5250
ALIGN_ID = 0xd935


def block_range(d):
    i = d.rfind(b'PK\x05\x06')
    cd = struct.unpack('<I', d[i + 16:i + 20])[0]
    if d[cd - 16:cd] != b'APK Sig Block 42':
        raise SystemExit('original has no APK signing block')
    size = struct.unpack('<Q', d[cd - 24:cd - 16])[0]
    return cd - size - 8, cd


def verity_source_len(d):
    """Source length recorded in the v2/v3 0x0421 digest, or None."""
    a, cd = block_range(d)
    pos, end = a + 8, cd - 24

    def lp(b, o):
        n = struct.unpack('<I', b[o:o + 4])[0]
        return b[o + 4:o + 4 + n], o + 4 + n
    found = set()
    while pos < end:
        ln = struct.unpack('<Q', d[pos:pos + 8])[0]
        pid = struct.unpack('<I', d[pos + 8:pos + 12])[0]
        val = d[pos + 12:pos + 8 + ln]
        pos += 8 + ln
        if pid not in (0x7109871a, 0xf05368c0):
            continue
        signers, _ = lp(val, 0)
        o = 0
        while o < len(signers):
            signer, o = lp(signers, o)
            signed, _ = lp(signer, 0)
            digests, _ = lp(signed, 0)
            p = 0
            while p < len(digests):
                dg, p = lp(digests, p)
                if struct.unpack('<I', dg[:4])[0] == 0x0421:
                    dv, _ = lp(dg, 4)
                    found.add(struct.unpack('<Q', dv[32:40])[0])
    if len(found) > 1:
        raise SystemExit('inconsistent verity source lengths %s' % found)
    return found.pop() if found else None


def deflate_best(data):
    """Raw deflate of data: the smaller of zlib level 9 and 7-Zip's deflate
    (-mx=9 -mfb=258 -mpass=15, usually a few percent smaller) when 7z exists."""
    c = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    best = c.compress(data) + c.flush()
    seven = shutil.which('7z') or shutil.which('7za')
    if not seven:
        return best
    with tempfile.TemporaryDirectory() as t:
        src, arc = os.path.join(t, 'e'), os.path.join(t, 'e.zip')
        open(src, 'wb').write(data)
        subprocess.run([seven, 'a', '-tzip', '-mm=Deflate', '-mx=9', '-mfb=258', '-mpass=15',
                        arc, src], check=True, stdout=subprocess.DEVNULL)
        z = zipfile.ZipFile(arc)
        zi = z.infolist()[0]
        raw = raw_entry(open(arc, 'rb').read(), zi)
        if zi.compress_type == zipfile.ZIP_DEFLATED and zlib.decompress(raw, -15) == data \
                and len(raw) < len(best):
            best = raw
    return best


def dos_time(dt):
    y, mo, da, h, mi, s = dt
    return (h << 11) | (mi << 5) | (s // 2), ((y - 1980) << 9) | (mo << 5) | da


def raw_entry(d, zi):
    n, e = struct.unpack('<HH', d[zi.header_offset + 26:zi.header_offset + 30])
    start = zi.header_offset + 30 + n + e
    return d[start:start + zi.compress_size]


def build(orig_path, patched_path):
    od = open(orig_path, 'rb').read()
    oz = zipfile.ZipFile(orig_path)
    pz = zipfile.ZipFile(patched_path)
    omap = {i.filename: i for i in oz.infolist()}
    pinfos = pz.infolist()
    pnames = {i.filename for i in pinfos}
    removed = [n for n in omap if n not in pnames]
    if removed:
        print('removed:', removed)

    entries = []  # (ZipInfo-like meta, raw bytes, method, crc, usize)
    changed = []
    for pi in pinfos:
        oi = omap.get(pi.filename)
        if oi is not None and oi.CRC == pi.CRC and oi.file_size == pi.file_size:
            entries.append((oi, raw_entry(od, oi), oi.compress_type, oi.CRC, oi.file_size))
            continue
        data = pz.read(pi.filename)
        # The patch script decides how a changed entry is stored.
        method = pi.compress_type
        if method == zipfile.ZIP_DEFLATED:
            raw = deflate_best(data)
        else:
            raw = data
        meta = oi if oi is not None else pi
        entries.append((meta, raw, method, zlib.crc32(data) & 0xffffffff, len(data)))
        changed.append((pi.filename, (oi.compress_size if oi else 0), len(raw)))

    out = bytearray()
    cd = []
    for meta, raw, method, crc, usize in entries:
        name = meta.filename.encode('utf-8')
        flags = meta.flag_bits & 0x0800  # keep UTF-8; no data descriptor
        if any(ord(ch) > 127 for ch in meta.filename):
            flags |= 0x0800
        t, dt = dos_time(meta.date_time)
        version_needed = 20 if method == zipfile.ZIP_DEFLATED else 10
        extra = b''
        if method == zipfile.ZIP_STORED:
            align = 4096 if meta.filename.endswith('.so') else 4
            data_off = len(out) + 30 + len(name)
            pad = (-(data_off + 6)) % align
            extra = struct.pack('<HHH', ALIGN_ID, 2 + pad, align) + b'\0' * pad
        off = len(out)
        out += struct.pack('<IHHHHHIIIHH', 0x04034b50, version_needed, flags, method, t, dt,
                           crc, len(raw), usize, len(name), len(extra))
        out += name + extra + raw
        cd.append([meta, name, version_needed, flags, method, t, dt, crc, len(raw), usize, off,
                   b''])
    return od, out, cd, changed


def finish(out, cd, comment=b''):
    cd_off = len(out)
    body = bytearray()
    for meta, name, vn, flags, method, t, dt, crc, csize, usize, off, extra in cd:
        made = (meta.create_system << 8) | (meta.create_version or 20)
        body += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, made, vn, flags, method, t, dt,
                            crc, csize, usize, len(name), len(extra), 0, 0,
                            meta.internal_attr, meta.external_attr, off)
        body += name + extra
    eocd = struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(cd), len(cd), len(body), cd_off,
                       len(comment)) + comment
    return bytes(out) + bytes(body) + eocd


def main(orig_path, patched_path, out_path):
    od, local, cd, changed = build(orig_path, patched_path)
    a, cdo = block_range(od)
    target = len(od) - (cdo - a)
    vlen = verity_source_len(od)
    if vlen is not None and vlen != target:
        raise SystemExit('original verity length %d != content length %d' % (vlen, target))
    for n, o, c in changed:
        print('  %-28s %10d -> %10d (%+d)' % (n, o, c, c - o))
    plain = len(finish(local, cd))
    if vlen is None:
        # No length-bearing verity digest: no padding, growth is fine.
        target = plain
    delta = target - plain
    print('content: original %d, repacked %d, padding %d' % (target, plain, delta))
    if delta < 0:
        raise SystemExit('repacked content is %d bytes larger than the original' % -delta)
    # Bulk padding in central-directory extras (one 65535-byte field per entry,
    # from the last entry backwards), the rest in the EOCD comment.
    i = len(cd) - 1
    while delta > 65535 and i >= 0:
        cd[i][11] = struct.pack('<HH', PAD_ID, 65531) + b'\0' * 65531
        delta -= 65535
        i -= 1
    data = finish(local, cd, b'\0' * delta)
    if len(data) != target:
        raise SystemExit('padding error: %d != %d' % (len(data), target))
    blk = od[a:cdo]
    i = data.rfind(b'PK\x05\x06')
    cdoff = struct.unpack('<I', data[i + 16:i + 20])[0]
    signed = data[:cdoff] + blk + data[cdoff:]
    j = signed.rfind(b'PK\x05\x06')
    signed = signed[:j + 16] + struct.pack('<I', cdoff + len(blk)) + signed[j + 20:]
    open(out_path, 'wb').write(signed)
    # Self-check: zip readable, content length matches the verity record.
    zipfile.ZipFile(out_path).testzip()
    a2, c2 = block_range(signed)
    if len(signed) - (c2 - a2) != target:
        raise SystemExit('final content length mismatch')
    print('output', out_path, len(signed), '(verity source length %s)' % vlen)


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
