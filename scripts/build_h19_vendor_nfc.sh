#!/usr/bin/env bash
set -euo pipefail
W=/root/vendor_nfc_build
IMG_E=/mnt/e/code/modify/haotian_port_h19/account_fix/vendor.img
cd "$W"

echo '=== [1] 抽树(从当前已刷的 v2 镜像,含上轮 CIL) ==='
M=/tmp/ven_ro
umount "$M" 2>/dev/null || true
rm -f vendor_v2.raw.img
simg2img "$IMG_E" vendor_v2.raw.img
mkdir -p "$M"
mount -o loop,ro vendor_v2.raw.img "$M"
STAGE=$W/stage_v3
rm -rf "$STAGE"
cp -a "$M/." "$STAGE/"
umount "$M"

echo '=== [2] 五项 prop 追加到 vendor build.prop ==='
BP="$STAGE/build.prop"
grep -q "ro.vendor.nfc.mitouch" "$BP" && sed -i '/^ro\.vendor\.nfc\./d' "$BP"
cat >> "$BP" <<'EOF'

# 2026-10-25 NFC: 五项 Mi 调优(vendor build.prop 由 vendor_init 加载,
# 该域对 vendor_nfc_mi_prop 有 set 权限;product build.prop 的同名项被 init 域拒绝)
ro.vendor.nfc.mitouch=1
ro.vendor.nfc.phonecase=1
ro.vendor.nfc.repair=1
ro.vendor.nfc.secure_display_optim=1
ro.vendor.nfc.wallet_fusion=1
EOF
tail -7 "$BP"

echo '=== [3] contexts 复用上轮生成的(树内容未变) ==='
CTX="$W/vendor_mkfs_contexts"
[ -f "$CTX" ] || { echo "FAIL contexts missing"; exit 1; }

echo '=== [4] mkfs ==='
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/vendor \
  --file-contexts="$CTX" "$W/vendor_v3.raw.img" "$STAGE" >/dev/null 2>&1
fsck.erofs "$W/vendor_v3.raw.img" >/dev/null && echo "  fsck OK"

echo '=== [5] 验证 ==='
M=/tmp/ven_verify
umount "$M" 2>/dev/null || true
mkdir -p "$M"
mount -o loop,ro "$W/vendor_v3.raw.img" "$M"
grep -E "^ro\.vendor\.nfc\.(mitouch|phonecase)" "$M/build.prop" || echo "  FAIL prop missing"
grep -c "allow init vendor_nfc_mi_prop" "$M/etc/selinux/vendor_sepolicy.cil" | sed 's/^/  CIL 新规则: /'
python3 - <<'PY'
import os
m = "/tmp/ven_verify"
dirs = labs = files = flabs = 0
for dp, dn, fn in os.walk(m):
    dirs += 1
    try: os.getxattr(dp, 'security.selinux', follow_symlinks=False); labs += 1
    except OSError: pass
    for f in fn:
        files += 1
        try: os.getxattr(os.path.join(dp, f), 'security.selinux', follow_symlinks=False); flabs += 1
        except OSError: pass
print(f"  dirs={dirs} labeled={labs} | files={files} labeled={flabs}")
PY
CAPNEW=$(find "$M" -type f -exec getfattr -n security.capability --only-values {} \; 2>/dev/null | wc -c)
echo "  capability 字节: $CAPNEW (基线 180)"
umount "$M"

echo '=== [6] sparse + 替换 + 哈希 ==='
img2simg "$W/vendor_v3.raw.img" "$W/vendor_v3.img" 4096
cp -f "$W/vendor_v3.img" "$IMG_E"
{
  sha256sum /mnt/e/code/modify/haotian_port_h19/account_fix/odm.img
  sha256sum "$IMG_E"
} > /mnt/e/code/modify/haotian_port_h19/account_fix/sha256_images.txt
cat /mnt/e/code/modify/haotian_port_h19/account_fix/sha256_images.txt
echo VENDOR_NFC_V3_DONE
