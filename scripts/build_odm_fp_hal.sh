#!/usr/bin/env bash
# 用新指纹 HAL 替换 odm/bin/hw 并重建 odm.img
# 用法：
#   ODM_STAGE=/root/odm_identity_fix/odm_stage \
#   ODM_CTX=/root/odm_identity_fix/odm_mkfs_contexts \
#   NEW_HAL=patches/fingerprint-fod/bin/vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff \
#   OUT_IMG=/path/odm_facefix.img ./build_odm_fp_hal.sh
set -euo pipefail

ODM_STAGE="${ODM_STAGE:?ODM_STAGE required}"
ODM_CTX="${ODM_CTX:?ODM_CTX required}"
NEW_HAL="${NEW_HAL:?NEW_HAL required}"
OUT_IMG="${OUT_IMG:?OUT_IMG required}"
RAW="${RAW:-$(dirname "$ODM_STAGE")/odm_fp_hal.raw.img}"

H="$ODM_STAGE/bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff"

echo "== [1] 替换 HAL =="
echo "  before: $(sha256sum "$H" | cut -d' ' -f1) size=$(stat -c%s "$H")"
cp "$NEW_HAL" "$H"
chown 0:0 "$H"; chmod 0755 "$H"; touch -d '1970-01-01 00:00:00' "$H"
echo "  after : $(sha256sum "$H" | cut -d' ' -f1) size=$(stat -c%s "$H")"
grep -F "fingerprint@2.1\\-service_uff" "$ODM_CTX" || {
  echo "  contexts 缺条目，追加"; \
  printf '/odm/bin/hw/vendor\\.oplus\\.hardware\\.biometrics\\.fingerprint@2\\.1\\-service_uff u:object_r:hal_fingerprint_oppo_exec:s0\n' >> "$ODM_CTX"; }

echo "== [2] 重建 odm =="
rm -f "$RAW"
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm \
  --file-contexts="$ODM_CTX" "$RAW" "$ODM_STAGE" >/dev/null 2>&1
fsck.erofs "$RAW" >/dev/null && echo "  fsck OK"
img2simg "$RAW" "$OUT_IMG" 4096
sha256sum "$OUT_IMG"

echo "== [3] 验证 =="
M=/tmp/odm_fp_hal_verify
umount "$M" 2>/dev/null || true; mkdir -p "$M"
mount -o loop,ro "$RAW" "$M"
getfattr -h -n security.selinux --only-values "$M/bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff"; echo
sha256sum "$M/bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff"
umount "$M"
echo ODM_FP_HAL_DONE
