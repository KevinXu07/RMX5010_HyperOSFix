#!/usr/bin/env bash
# Build the "lite" KSU module for images that already carry the module's
# static fixes and the patched ColorOS wallet suite (ro.rmx5010.image_merge=1).
#
# Drops the payloads that the merged image already has (camera port, system
# libs, display overlays, audio patch libs, wallet APKs) and limits the Sense
# scopes to the packages whose hooks are not in the image yet: the wallet,
# NFC, SE, Mi TSM and eID processes are patched in the image, so Sense no
# longer hooks them.
#
# usage: scripts/build_lite_module.sh [out.zip]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/kernel-src/ksu-module"
BASE="$ROOT/out/rmx5010_fod_bridge-1.7.28-full.zip"
VER=1.8.2-lite
VCODE=68
OUT=${1:-"$ROOT/out/rmx5010_fod_bridge-$VER.zip"}
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -a "$SRC/." "$STAGE/"
rm -rf "$STAGE/camera" "$STAGE/system" "$STAGE/system_ext" "$STAGE/overlay" \
       "$STAGE/audio" "$STAGE/installer/wallet"

# module.prop
sed -i -e "s/^version=.*/version=$VER/" -e "s/^versionCode=.*/versionCode=$VCODE/" \
  -e 's/^description=.*/description=RMX5010 HyperOS 移植修复精简模块（仅用于已合入模块的 OS4.0.4.0 整包，ro.rmx5010.image_merge=1）：屏下指纹\/锁屏、抬手亮屏、AOD、充电动画、相机细节、蓝牙 LHDC、双卡数据切换等 Sense 修复，触控报点率与推送运行时设置。自带安装器，自动部署 ZygiskNext、LSPosed 与 Sense。/' \
  "$STAGE/module.prop"

# install.sh: the camera payload check becomes an image check.
python3 - "$STAGE/install.sh" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
start = s.index("# 载荷完整性检查：相机 APK")
end = s.index('log "模块载荷校验通过')
end = s.index("\n", end) + 1
s = s[:start] + '''# 精简版不带相机/系统库/钱包载荷，只能装在已合入模块的整包上。
[ "$(getprop ro.rmx5010.image_merge)" = 1 ] || fail "精简版模块只用于已合入模块的整包（ro.rmx5010.image_merge=1），其他系统请用 full 版"
[ -f "$MODDIR/service.sh" ] || fail "模块载荷不完整：缺少 service.sh"
log "镜像已合入模块静态部分，精简版载荷校验通过"
''' + s[end:]
open(p, "w", encoding="utf-8", newline="\n").write(s)
PY

# Sense scopes without the processes patched in the image.
DROP='com.android.nfc com.android.se com.finshell.wallet com.heytap.tas com.unionpay.tsmservice com.oplus.eid com.miui.tsmclient'
# Only touch the two scope lists; the wallet appops/install lines stay intact
# (wallet_install skips the missing APKs, the appops grant is a no-op on a
# preinstalled wallet).
python3 - "$STAGE" $DROP <<'PY'
import sys, re
stage, drop = sys.argv[1], sys.argv[2:]
def strip(text):
    for p in drop:
        text = re.sub(r" " + re.escape(p) + r"(?=[ \"\n\\]|$)", "", text)
    return text
p = stage + "/install.sh"
s = open(p, encoding="utf-8").read()
s2 = re.sub(r'^SENSE_SCOPES="[^"]*"', lambda m: strip(m.group(0)), s, count=1, flags=re.M)
assert s2 != s
open(p, "w", encoding="utf-8", newline="\n").write(s2)
p = stage + "/service.sh"
s = open(p, encoding="utf-8").read()
m = re.search(r'LspdModule "\$db" com\.zephiel\.sense "\$apk" \\\n.*?\) >> "\$LOG"', s, re.S)
blk = strip(m.group(0))
blk = re.sub(r"\n +\\\n", "\n", blk)
s2 = s[:m.start()] + blk + s[m.end():]
assert s2 != s
open(p, "w", encoding="utf-8", newline="\n").write(s2)
for f in ("install.sh", "service.sh"):
    t = open(stage + "/" + f, encoding="utf-8").read()
    line = re.search(r'SENSE_SCOPES="[^"]*"', t) if f == "install.sh" else re.search(r'LspdModule.*?\) >>', t, re.S)
    for p in drop:
        assert not re.search(" " + re.escape(p) + r"(?=[ \"\n\\]|$)", line.group(0)), (f, p)
PY

python3 "$ROOT/scripts/pack_ksu_module.py" "$STAGE" "$BASE" "$OUT"
sha256sum "$OUT"
stat -c '%s bytes' "$OUT"
