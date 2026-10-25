#!/usr/bin/env python3
"""h19 DevicesOverlay arsc patch: island geometry + status bar padding.
Values = the device-verified 12.24/12.25 set (cut_out_center_y=72px,
padding_top=14px, island trio = OS3 dp encodings). In-place byte patch,
original signing block spliced back (TeleService-proven preset-scan path)."""
import zipfile, struct, sys, shutil, hashlib

DONOR = "E:/code/modify/haotian_work/DevicesOverlay_donor.apk"
OS3   = "E:/code/modify/os4/overlay_audit/DevicesOverlay-os3.apk"
OUT   = "E:/code/modify/haotian_work/DevicesOverlay_h19_patched.apk"

NAMES = ["cut_out_center_y", "dynamic_island_expanded_shadow_offset_y",
         "dynamic_island_expanded_shadow_radius", "dynamic_island_radius",
         "status_bar_padding_top"]

def parse_string_pool(data, off):
    strcount, styleCount, flags, stringsStart = struct.unpack_from('<IIII', data, off+8)
    utf8 = bool(flags & 0x100)
    offs = [struct.unpack_from('<I', data, off+28+4*i)[0] for i in range(strcount)]
    base = off + stringsStart
    out = []
    for o in offs:
        p = base + o
        if utf8:
            c1 = data[p]; p += 1
            if c1 & 0x80: c1 = ((c1 & 0x7f) << 8) | data[p]; p += 1
            b1 = data[p]; p += 1
            if b1 & 0x80: b1 = ((b1 & 0x7f) << 8) | data[p]; p += 1
            s = data[p:p+b1].decode('utf-8', errors='replace')
        else:
            l1 = struct.unpack_from('<H', data, p)[0]; p += 2
            if l1 & 0x8000: l1 = ((l1 & 0x7fff) << 16) | struct.unpack_from('<H', data, p)[0]; p += 2
            s = data[p:p+l1*2].decode('utf-16-le', errors='replace')
        out.append(s)
    return out

def locate(arsc, want_names):
    """return {name: [(abs_off_in_arsc, old_raw)]} for dimen entries"""
    t, h, total = struct.unpack_from('<HHI', arsc, 0)
    off = h
    key_pool = type_pool = None
    found = {}
    while off < total - 8:
        ct, ch, cs = struct.unpack_from('<HHI', arsc, off)
        if cs == 0: break
        if ct == 0x0200:
            typeStrings, = struct.unpack_from('<I', arsc, off+268)
            keyStrings, = struct.unpack_from('<I', arsc, off+276)
            key_pool = parse_string_pool(arsc, off+keyStrings)
            type_pool = parse_string_pool(arsc, off+typeStrings)
            p = off + ch
            while p < off + cs - 8:
                ct2, ch2, cs2 = struct.unpack_from('<HHI', arsc, p)
                if cs2 == 0: break
                if ct2 == 0x0201:
                    tid = arsc[p+8]
                    entryCount, entriesStart = struct.unpack_from('<II', arsc, p+12)
                    tname = type_pool[tid-1] if type_pool and tid-1 < len(type_pool) else f'type{tid}'
                    if tname == 'dimen' and entryCount < 5000:
                        eoff_tbl = p + ch2
                        for ei in range(entryCount):
                            e2 = struct.unpack_from('<I', arsc, eoff_tbl + 4*ei)[0]
                            if e2 == 0xFFFFFFFF: continue
                            ea = p + entriesStart + e2
                            if ea + 8 > len(arsc): continue
                            esize, eflags, ekey = struct.unpack_from('<HHI', arsc, ea)
                            if ekey >= len(key_pool): continue
                            k = key_pool[ekey]
                            if k in want_names:
                                raw = struct.unpack_from('<I', arsc, ea+8+4)[0]
                                found.setdefault(k, []).append((ea+8+4, raw))
                p += cs2 if cs2 else 4
        off += cs if cs else 4
    return found

def get_raws(apk, names):
    z = zipfile.ZipFile(apk)
    arsc = z.read('resources.arsc')
    f = locate(arsc, names)
    out = {}
    for n in names:
        if n not in f or not f[n]: raise RuntimeError(f"{n} not in {apk}")
        out[n] = f[n][0][1]   # first config's raw word
    return out

# --- 1. OS3 trio raws ---
os3_raws = get_raws(OS3, ["dynamic_island_expanded_shadow_offset_y",
                          "dynamic_island_expanded_shadow_radius", "dynamic_island_radius"])
print("OS3 trio raws:", {k: hex(v) for k, v in os3_raws.items()})

# --- 2. locate entries in the h19 donor overlay arsc ---
zin = zipfile.ZipFile(DONOR)
arsc = zin.read('resources.arsc')
f = locate(arsc, set(NAMES))
for k, v in sorted(f.items()):
    print(f"  {k}: {len(v)} configs, raws={[hex(r) for _, r in v]}")

# --- 3. patch words ---
NEW = {"cut_out_center_y": 0x4A00,            # 72px (radix0, px)
       "status_bar_padding_top": 0x0E00}      # 14px (radix0, px)
NEW.update(os3_raws)                           # island trio: OS3 dp encodings
patched = bytearray(arsc)
n = 0
for k, offs in f.items():
    for abs_off, old in offs:
        struct.pack_into('<I', patched, abs_off, NEW[k])
        n += 1
print(f"  patched words: {n}")
arsc_new = bytes(patched)

# --- 4. repack preserving order/attrs, then splice original signing block ---
tmp = DONOR + ".tmp"
zo = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
replaced = 0
for zi in zin.infolist():
    if zi.filename == 'resources.arsc':
        zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
        zi2.compress_type = zi.compress_type
        zi2.external_attr = zi.external_attr; zi2.internal_attr = zi.internal_attr
        zi2.create_system = zi.create_system
        zo.writestr(zi2, arsc_new); replaced += 1
    else:
        zo.writestr(zi, zin.read(zi.filename))
zo.close(); zin.close()
print(f"  repacked (replaced {replaced} arsc)")

d = open(tmp, 'rb').read()
i = len(d) - 22
while i >= 0 and d[i:i+4] != b'PK\x05\x06': i -= 1
cd_off = struct.unpack_from('<I', d, i+16)[0]
o = open(DONOR, 'rb').read()
j = o.rfind(b'PK\x05\x06')
o_cd = struct.unpack_from('<I', o, j+16)[0]
assert o[o_cd-16:o_cd] == b'APK Sig Block 42', 'donor has no v2 signing block'
blk_len = struct.unpack_from('<Q', o, o_cd-24)[0]
block = o[o_cd-8-blk_len:o_cd]
pre, cd_eocd = d[:cd_off], d[cd_off:]
eocd = bytearray(cd_eocd[-22:])
new_cd = cd_off + len(block)
eocd[16:20] = struct.pack('<I', new_cd)
open(OUT, 'wb').write(pre + block + cd_eocd[:-22] + bytes(eocd))
print(f"  signing block spliced: {len(block)}B")
print(f"  out: {OUT} {len(open(OUT,'rb').read()):,}B sha256={hashlib.sha256(open(OUT,'rb').read()).hexdigest()[:16]}")
print(ISLAND_PATCH_DONE if (ISLAND_PATCH_DONE := 'OK') else '')
