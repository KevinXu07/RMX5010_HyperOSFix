#!/usr/bin/env bash
# Step 74: CNE guard patch with ORIGINAL signing block preserved (shared-UID safe)
set -euo pipefail
R=/home/ubuntu/rom/os4
W=$R/work_signal
J=$R/work_fdnotz/jars
O=$W/cne_build.txt
: > $O
say() { echo "$@" | tee -a $O; }

say "=== [1] smali 补丁：destroyNetworkRequest 加 try/catch ==="
TR=$W/cne_split/classes/com/qualcomm/qti/cne/datacall/DataCallAgent\$Tracker.smali
python3 - "$TR" <<'PY' | tee -a $O
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='replace').read()
i = s.find('.method public destroyNetworkRequest()V'); j = s.find('.end method', i)
old = s[i:j+11]
new = '''.method public destroyNetworkRequest()V
    .registers 3

    .line 410
    :try_start_0
    iget-object v0, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mConnectivityManager:Landroid/net/ConnectivityManager;

    iget-object v1, p0, Lcom/qualcomm/qti/cne/datacall/DataCallAgent$Tracker;->mNetworkCallback:Landroid/net/ConnectivityManager$NetworkCallback;

    invoke-virtual {v0, v1}, Landroid/net/ConnectivityManager;->unregisterNetworkCallback(Landroid/net/ConnectivityManager$NetworkCallback;)V
    :try_end_0
    .catch Ljava/lang/IllegalArgumentException; {:try_start_0 .. :try_end_0} :catch_0

    .line 411
    return-void

    :catch_0
    move-exception v0

    const-string v0, "CneDataCallGuard"

    const-string v1, "unregisterNetworkCallback: callback not registered (RMX5010 guard)"

    invoke-static {v0, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void
.end method'''
s = s[:i] + new + s[j+11:]
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(f'  已替换方法（{old.count(chr(10))} -> {new.count(chr(10))} 行）')
PY

say ""
say "=== [2] 重编译 + 往返校验 ==="
mkdir -p $W/cne_new
java -jar $J/smali-2.5.2-fat.jar a $W/cne_split/classes -o $W/cne_new/classes.dex -a 28 2>&1 | head -5
say "  new classes.dex: $(stat -c%s $W/cne_new/classes.dex) bytes version=$(xxd -s 4 -l 3 -p $W/cne_new/classes.dex)"
rm -rf $W/cne_rt; mkdir -p $W/cne_rt
java -jar $J/baksmali-2.5.2-fat.jar d $W/cne_new/classes.dex -o $W/cne_rt >/dev/null 2>&1
diff -rq $W/cne_split/classes $W/cne_rt > $W/cne_rt_diff.txt 2>&1 || true
say "  差异文件: $(grep -c '^Files' $W/cne_rt_diff.txt || true) -> $(grep '^Files' $W/cne_rt_diff.txt | sed 's/.*classes\///; s/ and .*//' | tr '\n' ' ')"

say ""
say "=== [3] 重打包 + 拼接原签名块 ==="
python3 - <<'PY' | tee -a $O
import struct, zipfile, os, hashlib
src='/home/ubuntu/rom/os4/work_signal/CneApp.apk'
tmp='/home/ubuntu/rom/os4/work_signal/CneApp.repacked.apk'
newdex='/home/ubuntu/rom/os4/work_signal/cne_new/classes.dex'
out='/home/ubuntu/rom/os4/work_signal/CneApp.patched.apk'
zin=zipfile.ZipFile(src); zout=zipfile.ZipFile(tmp,'w',zipfile.ZIP_DEFLATED)
rep=0
for zi in zin.infolist():
    if zi.filename=='classes.dex':
        data=open(newdex,'rb').read()
        zi2=zipfile.ZipInfo(zi.filename, zi.date_time); zi2.compress_type=zi.compress_type
        zi2.external_attr=zi.external_attr; zi2.internal_attr=zi.internal_attr; zi2.create_system=zi.create_system
        zout.writestr(zi2,data); rep+=1
    else:
        zout.writestr(zi, zin.read(zi.filename))
zout.close(); zin.close()
print(f'  repacked: replaced {rep}, size={os.path.getsize(tmp):,}')

d=open(tmp,'rb').read(); i=d.rfind(b'PK\x05\x06')
cd=struct.unpack('<I', d[i+16:i+20])[0]
o=open(src,'rb').read(); j=o.rfind(b'PK\x05\x06')
ocd=struct.unpack('<I', o[j+16:j+20])[0]
assert o[ocd-16:ocd]==b'APK Sig Block 42'
blk_len=struct.unpack('<Q', o[ocd-24:ocd-16])[0]
block=o[ocd-8-blk_len:ocd]
pre, rest = d[:cd], d[cd:]
eocd=bytearray(rest[-22:]); new_cd=cd+len(block)
eocd[16:20]=struct.pack('<I', new_cd)
open(out,'wb').write(pre+block+rest[:-22]+bytes(eocd))
print(f'  signing block {len(block)} bytes spliced; cd {cd} -> {new_cd}')
print(f'  out {os.path.getsize(out):,} bytes sha256={hashlib.sha256(open(out,"rb").read()).hexdigest()}')
PY

say ""
say "=== [4] 结构 + 内容校验 ==="
python3 - <<'PY' | tee -a $O
import struct, zipfile, hashlib, os, re
src='/home/ubuntu/rom/os4/work_signal/CneApp.apk'
out='/home/ubuntu/rom/os4/work_signal/CneApp.patched.apk'
a=zipfile.ZipFile(src); b=zipfile.ZipFile(out)
print('  zip integrity:', 'OK' if b.testzip() is None else 'BAD')
print(f'  entries: {len(a.namelist())} -> {len(b.namelist())}')
diff=[]
for n in a.namelist():
    if n=='classes.dex': continue
    if n not in b.namelist(): diff.append('MISSING '+n); continue
    if hashlib.sha256(a.read(n)).hexdigest()!=hashlib.sha256(b.read(n)).hexdigest(): diff.append('CHANGED '+n)
print(f'  非 dex 差异: {len(diff)} {diff[:5]}')
def sig(p):
    d=open(p,'rb').read(); i=d.rfind(b'PK\x05\x06'); cd=struct.unpack('<I', d[i+16:i+20])[0]
    return d[cd-16:cd]==b'APK Sig Block 42'
print(f'  signing block: orig={sig(src)} patched={sig(out)}')
PY
echo "  --- 方法行为（反编译确认）:"
python3 - <<'PY' | tee -a $O
import re
s=open('/home/ubuntu/rom/os4/work_signal/cne_rt/com/qualcomm/qti/cne/datacall/DataCallAgent$Tracker.smali', encoding='utf-8', errors='replace').read()
m=re.search(r'\.method public destroyNetworkRequest\(\)V.*?\.end method', s, re.S)
body=m.group(0)
print('  try/catch IAE present:', '.catch Ljava/lang/IllegalArgumentException' in body)
print('  Log.w present:', 'Landroid/util/Log;->w' in body)
print('  unregister call still inside try:', body.find('try_start_0') < body.find('unregisterNetworkCallback') < body.find('try_end_0'))
PY
say "CNE_PATCH_DONE"
