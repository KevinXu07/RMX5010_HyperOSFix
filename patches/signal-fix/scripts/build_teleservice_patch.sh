#!/usr/bin/env bash
# build_teleservice_patch.sh — RMX5010 signal fix: cut the Xiaomi OEM XTS version queries
# in TeleService/XtsApp, repack keeping the ORIGINAL signing block (preinstalled path).
set -euo pipefail
R=/home/ubuntu/rom/os4
W=$R/work_signal
J=$R/work_fdnotz/jars
O=$W/ts_build.txt
: > $O
say() { echo "$@" | tee -a $O; }

SRC=$R/stage_nezha_v1/system/system/priv-app/TeleService
APK=$SRC/TeleService.apk
say "=== [1] 源 APK ==="
say "  $APK  ($(stat -c%s $APK) bytes)"
say "  sha256(orig) = $(sha256sum $APK | cut -d' ' -f1)"
say "  预编译目录: $(ls $SRC | tr '\n' ' ')"

XTS=$W/ts_split/classes/com/android/phone/XtsApp.smali
[ -f "$W/ts_dex/classes.dex" ] || { say "  缺少 ts_dex/classes.dex"; exit 2; }
say "  --- 重置反编译树（干净基线）:"
rm -rf $W/ts_split/classes && mkdir -p $W/ts_split/classes
java -jar $J/baksmali-2.5.2-fat.jar d $W/ts_dex/classes.dex -o $W/ts_split/classes >/dev/null 2>&1
[ -f "$XTS" ] || { say "  解包失败"; exit 2; }

say ""
say "=== [2] 应用 smali 补丁（3 处） ==="
python3 - "$XTS" <<'PY' | tee -a $O
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
orig = s

def noop_method(src, decl):
    """replace a method body with an immediate return-void, keeping annotations"""
    i = src.find(decl)
    if i < 0: return src, False
    j = src.find('.end method', i)
    head_end = src.find('\n', i)
    # keep the signature line, drop body, keep .registers/.locals + trailing annotations
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

# onHookDone: early return after the registrant notification (mirrors the device-verified OS3 patch)
marker = """:try_end_1d
    .catchall {:try_start_17 .. :try_end_1d} :catchall_48
"""
ins = marker + """
    # RMX5010: stop before XTS ver-info / service start; ModemUtils OEM RIL queries block
    # the phone main thread on this Oplus modem (device-verified fix, see repo docs)
    return-void
"""
if marker in s:
    s = s.replace(marker, ins, 1); ok3 = True
else:
    ok3 = False

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(f'  onInitVerInfo() no-op: {ok1}')
print(f'  onInitVerInfo(hook) no-op: {ok2}')
print(f'  onHookDone early return: {ok3}')
print(f'  file size {len(orig)} -> {len(s)}')
PY

say ""
say "=== [3] 重新编译 classes.dex（XtsApp 在 classes.dex） ==="
mkdir -p $W/ts_new
java -jar $J/smali-2.5.2-fat.jar a $W/ts_split/classes -o $W/ts_new/classes.dex -a 28 2>&1 | head -5
say "  new classes.dex: $(stat -c%s $W/ts_new/classes.dex) bytes, version=$(xxd -s 4 -l 3 -p $W/ts_new/classes.dex)"

say ""
say "=== [4] 往返校验（只有 XtsApp 应实质变化） ==="
rm -rf $W/ts_rt; mkdir -p $W/ts_rt
java -jar $J/baksmali-2.5.2-fat.jar d $W/ts_new/classes.dex -o $W/ts_rt >/dev/null 2>&1
diff -rq $W/ts_split/classes $W/ts_rt > $W/ts_rt_diff.txt 2>&1 || true
say "  差异文件数: $(grep -c '^Files' $W/ts_rt_diff.txt || true)"
grep '^Files' $W/ts_rt_diff.txt | sed 's/.*classes\///; s/ and .*//' | sed 's/^/    /' | head -12 | tee -a $O

say ""
say "=== [5] 重打包（保留原条目顺序/压缩/签名块） ==="
python3 - <<'PY' | tee -a $O
import struct, zipfile, os, hashlib
src = '/home/ubuntu/rom/os4/stage_nezha_v1/system/system/priv-app/TeleService/TeleService.apk'
tmp = '/home/ubuntu/rom/os4/work_signal/TeleService.repacked.apk'
newdex = '/home/ubuntu/rom/os4/work_signal/ts_new/classes.dex'
out = '/home/ubuntu/rom/os4/work_signal/TeleService.patched.apk'

# 1) repack, replacing classes.dex only
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

# 2) splice the ORIGINAL APK Signing Block back, before the central directory
d = open(tmp, 'rb').read()
i = len(d) - 22
while i >= 0 and d[i:i+4] != b'PK\x05\x06': i -= 1
assert i >= 0, 'EOCD not found in repacked'
cd_off = struct.unpack('<I', d[i+16:i+20])[0]
o = open(src, 'rb').read()
j = o.rfind(b'PK\x05\x06')
o_cd_off = struct.unpack('<I', o[j+16:j+20])[0]
assert o[o_cd_off-16:o_cd_off] == b'APK Sig Block 42', 'original has no signing block?'
blk_len = struct.unpack('<Q', o[o_cd_off-24:o_cd_off-16])[0]
block = o[o_cd_off-8-blk_len:o_cd_off]          # [size][pairs][size][magic]
pre, cd_and_eocd = d[:cd_off], d[cd_off:]
eocd = bytearray(cd_and_eocd[-22:])
new_cd_off = cd_off + len(block)
eocd[16:20] = struct.pack('<I', new_cd_off)
open(out, 'wb').write(pre + block + cd_and_eocd[:-22] + bytes(eocd))
print(f'  spliced signing block: {len(block)} bytes, cd_off {cd_off} -> {new_cd_off}')
print(f'  output {os.path.getsize(out):,} bytes  sha256={hashlib.sha256(open(out,"rb").read()).hexdigest()}')
PY

say ""
say "=== [6] 结构校验 ==="
python3 - <<'PY' | tee -a $O
import struct, zipfile, hashlib, os
src = '/home/ubuntu/rom/os4/stage_nezha_v1/system/system/priv-app/TeleService/TeleService.apk'
out = '/home/ubuntu/rom/os4/work_signal/TeleService.patched.apk'
def blk(p):
    d = open(p,'rb').read(); i = d.rfind(b'PK\x05\x06')
    cd = struct.unpack('<I', d[i+16:i+20])[0]
    r = {'file': os.path.basename(p), 'size': len(d), 'sig': d[cd-16:cd] == b'APK Sig Block 42'}
    if r['sig']:
        b = struct.unpack('<Q', d[cd-24:cd-16])[0]
        pos = cd - 8 - b + 8; ids = []
        while pos < cd - 16:
            ln = struct.unpack('<Q', d[pos:pos+8])[0]; ids.append(d[pos+8:pos+12].hex()); pos += 8 + ln
        r['ids'] = ids
    return r
a, b = zipfile.ZipFile(src), zipfile.ZipFile(out)
print('  orig :', blk(src))
print('  patch:', blk(out))
print('  zip integrity:', 'OK' if b.testzip() is None else 'BAD')
diff = []
for n in a.namelist():
    if n == 'classes.dex': continue
    if n not in b.namelist(): diff.append('MISSING ' + n); continue
    if hashlib.sha256(a.read(n)).hexdigest() != hashlib.sha256(b.read(n)).hexdigest():
        diff.append('CHANGED ' + n)
print(f'  entries: {len(a.namelist())} -> {len(b.namelist())}; non-dex differences: {len(diff)}')
for x in diff[:8]: print('   ', x)
PY
say ""
say "=== [7] 校验补丁确实在 dex 里（反编译片段） ==="
java -jar $J/baksmali-2.5.2-fat.jar d $W/ts_new/classes.dex -o $W/ts_rt >/dev/null 2>&1
grep -n -A3 "RMX5010: skip Xiaomi OEM modem" $W/ts_rt/com/android/phone/XtsApp.smali | head -20 | sed 's/^/  /' | tee -a $O
grep -c "return-void" $W/ts_rt/com/android/phone/XtsApp.smali | sed 's/^/  return-void 总数: /' | tee -a $O
say "TS_BUILD_DONE"
