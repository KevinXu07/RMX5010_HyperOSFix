#!/usr/bin/env bash
# h19 signal fix: apply the device-verified RMX5010 XtsApp patch to the 0.19 TeleService,
# repack keeping the ORIGINAL signing block (preinstalled scan path), rebuild system.img.
set -euo pipefail

R=/root/haotian
W=$R/work_signal
STAGE=$R/stage_h19
OUT=/mnt/e/code/modify/haotian_port_h19
APK=$STAGE/system/system/priv-app/TeleService/TeleService.apk
XTS=$W/ts_split/com/android/phone/XtsApp.smali

cd "$W"

echo '=== [1] apply smali patch (3 sites) ==='
python3 - "$XTS" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
orig = s

def noop_method(src, decl):
    i = src.find(decl)
    if i < 0: return src, False
    j = src.find('.end method', i)
    head_end = src.find('\n', i)
    body = src[head_end:j]
    anns = []
    for m in re.finditer(r'\n(    \.annotation[\s\S]*?\.end annotation)', body):
        anns.append(m.group(1))
    regs = '    .registers 1'
    for line in body.splitlines():
        t = line.strip()
        if t.startswith('.registers') or t.startswith('.locals'):
            regs = '    ' + t
            break
    new = src[:head_end] + '\n' + regs + '\n\n    # RMX5010: skip Xiaomi OEM modem version queries (Oplus modem does not answer\n    # them; the query blocks the phone main thread and produced SIM/STK ANRs)\n    return-void\n' \
          + ''.join('\n' + a for a in anns) + '\n' + src[j:]
    return new, True

s, ok1 = noop_method(s, '.method private onInitVerInfo()V')
s, ok2 = noop_method(s, '.method private onInitVerInfo(Lcom/xiaomi/modem/OemHookAgent;)V')

marker = """:try_end_1d
    .catchall {:try_start_17 .. :try_end_1d} :catchall_48
"""
ins = marker + """
    # RMX5010: stop before XTS ver-info / service start; ModemUtils OEM RIL queries block
    # the phone main thread on this Oplus modem (device-verified fix, see repo docs)
    return-void
"""
ok3 = marker in s
if ok3: s = s.replace(marker, ins, 1)

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(f'  onInitVerInfo() no-op: {ok1}')
print(f'  onInitVerInfo(hook) no-op: {ok2}')
print(f'  onHookDone early return: {ok3}')
assert ok1 and ok2 and ok3, 'patch site missing — do not ship'
print(f'  size {len(orig)} -> {len(s)}')
PY

echo '=== [2] reassemble classes.dex (api 28) ==='
smali a ts_split -o ts_new_classes.dex -a 28
ls -la ts_new_classes.dex

echo '=== [3] roundtrip check: only XtsApp may differ ==='
rm -rf ts_rt && baksmali d ts_new_classes.dex -o ts_rt
diff -rq ts_split ts_rt > ts_rt_diff.txt || true
echo "  differing files: $(grep -c '^Files' ts_rt_diff.txt || true)"
grep '^Files' ts_rt_diff.txt | sed 's/^/    /' | head -5

echo '=== [4] repack keeping original signing block ==='
python3 - <<'PY'
import struct, zipfile, os, hashlib
src = '/root/haotian/work_signal/TeleService.apk'
tmp = '/root/haotian/work_signal/TeleService.repacked.apk'
newdex = '/root/haotian/work_signal/ts_new_classes.dex'
out = '/root/haotian/work_signal/TeleService.patched.apk'

zin = zipfile.ZipFile(src); zout = zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED)
replaced = 0
for zi in zin.infolist():
    if zi.filename == 'classes.dex':
        data = open(newdex, 'rb').read()
        zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
        zi2.compress_type = zi.compress_type
        zi2.external_attr = zi.external_attr; zi2.internal_attr = zi.internal_attr
        zi2.create_system = zi.create_system
        zout.writestr(zi2, data); replaced += 1
    else:
        zout.writestr(zi, zin.read(zi.filename))
zout.close(); zin.close()
print(f'  repacked: replaced {replaced} entry, size={os.path.getsize(tmp):,}')

d = open(tmp, 'rb').read()
i = len(d) - 22
while i >= 0 and d[i:i+4] != b'PK\x05\x06': i -= 1
cd_off = struct.unpack('<I', d[i+16:i+20])[0]
o = open(src, 'rb').read()
j = o.rfind(b'PK\x05\x06')
o_cd_off = struct.unpack('<I', o[j+16:j+20])[0]
assert o[o_cd_off-16:o_cd_off] == b'APK Sig Block 42', 'original has no signing block?'
blk_len = struct.unpack('<Q', o[o_cd_off-24:o_cd_off-16])[0]
block = o[o_cd_off-8-blk_len:o_cd_off]
pre, cd_and_eocd = d[:cd_off], d[cd_off:]
eocd = bytearray(cd_and_eocd[-22:])
new_cd_off = cd_off + len(block)
eocd[16:20] = struct.pack('<I', new_cd_off)
open(out, 'wb').write(pre + block + cd_and_eocd[:-22] + bytes(eocd))
print(f'  spliced signing block: {len(block)} bytes, cd_off {cd_off} -> {new_cd_off}')
print(f'  output {os.path.getsize(out):,} bytes  sha256={hashlib.sha256(open(out,"rb").read()).hexdigest()}')
PY

echo '=== [5] structural verify: sig block ids identical, only classes.dex changed ==='
python3 - <<'PY'
import struct, zipfile, hashlib
src = '/root/haotian/work_signal/TeleService.apk'
out = '/root/haotian/work_signal/TeleService.patched.apk'
def blk(p):
    d = open(p,'rb').read(); i = d.rfind(b'PK\x05\x06')
    cd = struct.unpack('<I', d[i+16:i+20])[0]
    r = {'size': len(d), 'sig': d[cd-16:cd] == b'APK Sig Block 42'}
    b = struct.unpack('<Q', d[cd-24:cd-16])[0]
    pos = cd - 8 - b + 8; ids = []
    while pos < cd - 16:
        ln = struct.unpack('<Q', d[pos:pos+8])[0]; ids.append(d[pos+8:pos+12].hex()); pos += 8 + ln
    r['ids'] = ids
    return r
a, b = zipfile.ZipFile(src), zipfile.ZipFile(out)
ra, rb = blk(src), blk(out)
print('  orig sig block :', ra['sig'], ra['ids'])
print('  patched sig blk:', rb['sig'], rb['ids'])
assert ra['ids'] == rb['ids'], 'signing block ids changed!'
print('  zip integrity:', 'OK' if b.testzip() is None else 'BAD')
diff = []
for n in a.namelist():
    if n == 'classes.dex': continue
    if n not in b.namelist(): diff.append('MISSING ' + n); continue
    if hashlib.sha256(a.read(n)).hexdigest() != hashlib.sha256(b.read(n)).hexdigest():
        diff.append('CHANGED ' + n)
print(f'  entries: {len(a.namelist())} -> {len(b.namelist())}; non-dex differences: {len(diff)}')
for x in diff[:8]: print('   ', x)
assert not diff, 'unexpected non-dex changes'
PY

echo '=== [6] confirm patch inside new dex ==='
rm -rf ts_rt2 && baksmali d ts_new_classes.dex -o ts_rt2
grep -c "RMX5010: skip Xiaomi OEM modem" ts_rt2/com/android/phone/XtsApp.smali

echo '=== [7] install into stage, rebuild system.img ==='
cp -f "$W/TeleService.patched.apk" "$APK"
chmod 0644 "$APK"
stat -c '%a %s' "$APK"

cat "$STAGE/system/system/etc/selinux/plat_file_contexts" \
    "$STAGE/system_ext/etc/selinux/system_ext_file_contexts" \
    "$STAGE/product/etc/selinux/product_file_contexts" > "$STAGE/all_file_contexts"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/ \
  --file-contexts="$STAGE/all_file_contexts" \
  "$OUT/images/system.raw.img" "$STAGE/system" > "$OUT/logs/mkfs_system.log" 2>&1
fsck.erofs "$OUT/images/system.raw.img" > "$OUT/logs/fsck_system.log" 2>&1
img2simg "$OUT/images/system.raw.img" "$OUT/images/system.img"
rm -f "$OUT/images/system.raw.img"

sha256sum "$OUT/images"/*.img > "$OUT/metadata/sha256_images.txt"
echo '=== done ==='
cat "$OUT/metadata/sha256_images.txt"
echo H19_SIGNALFIX_DONE
