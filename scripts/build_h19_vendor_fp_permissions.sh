#!/usr/bin/env bash
# 在 h19 vendor 镜像里补两项生物识别特性声明，并重建 vendor.img
#
# 关键点：
#   1. 两个文件必须 root:root 0644
#   2. EROFS 的 file_contexts 必须精确到文件（目录规则不会自动覆盖子文件），
#      否则文件无标签或标签错误，PackageManager 会跳过
#   3. 目标标签与同目录其他权限文件一致：u:object_r:vendor_configs_file:s0
#
# 用法：
#   STAGE=/root/vendor_nfc_build/stage_v3 \
#   CTX=/root/vendor_nfc_build/vendor_mkfs_contexts \
#   OUT_RAW=/root/vendor_nfc_build/vendor_v5.raw.img \
#   OUT_IMG=/mnt/e/code/modify/haotian_work/vendor_fp.img \
#   ./build_h19_vendor_fp_permissions.sh
set -euo pipefail

STAGE="${STAGE:-/root/vendor_nfc_build/stage_v3}"
CTX="${CTX:-/root/vendor_nfc_build/vendor_mkfs_contexts}"
OUT_RAW="${OUT_RAW:-/root/vendor_nfc_build/vendor_v5.raw.img}"
OUT_IMG="${OUT_IMG:-/mnt/e/code/modify/haotian_work/vendor_fp.img}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FOD="$HERE/../patches/fingerprint-fod"

echo '=== [1] 放入权限 XML ==='
cp "$FOD/android.hardware.fingerprint.xml" \
   "$FOD/android.hardware.biometrics.face.xml" "$STAGE/etc/permissions/"
chown 0:0 "$STAGE/etc/permissions/android.hardware.fingerprint.xml" \
          "$STAGE/etc/permissions/android.hardware.biometrics.face.xml"
chmod 0644 "$STAGE/etc/permissions/android.hardware.fingerprint.xml" \
           "$STAGE/etc/permissions/android.hardware.biometrics.face.xml"

echo '=== [2] 补精确 file_contexts ==='
grep -q 'android\\.hardware\\.fingerprint\\.xml' "$CTX" || \
  printf '/vendor/etc/permissions/android\\.hardware\\.fingerprint\\.xml u:object_r:vendor_configs_file:s0\n' >> "$CTX"
grep -q 'android\\.hardware\\.biometrics\\.face\\.xml' "$CTX" || \
  printf '/vendor/etc/permissions/android\\.hardware\\.biometrics\\.face\\.xml u:object_r:vendor_configs_file:s0\n' >> "$CTX"
grep -nE 'hardware\\.(fingerprint|biometrics\\.face)' "$CTX"

echo '=== [3] 重建 vendor ==='
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/vendor \
  --file-contexts="$CTX" "$OUT_RAW" "$STAGE" >/dev/null 2>&1
fsck.erofs "$OUT_RAW" >/dev/null && echo '  fsck OK'

echo '=== [4] 验证 ==='
M=/tmp/vendor_fp_verify
umount "$M" 2>/dev/null || true
mkdir -p "$M"; mount -o loop,ro "$OUT_RAW" "$M"
for f in android.hardware.fingerprint.xml android.hardware.biometrics.face.xml; do
  printf '  %s [%s]\n' "$f" "$(getfattr -h -n security.selinux --only-values "$M/etc/permissions/$f" 2>/dev/null | tr -d '\n\0')"
done
echo "  capability 字节: $(find "$M" -type f -exec getfattr -n security.capability --only-values {} \; 2>/dev/null | wc -c) (基线 180)"
umount "$M"

img2simg "$OUT_RAW" "$OUT_IMG" 4096
sha256sum "$OUT_IMG"
echo VENDOR_FP_PERMISSIONS_BUILD_DONE
