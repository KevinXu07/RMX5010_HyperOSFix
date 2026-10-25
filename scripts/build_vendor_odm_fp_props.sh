#!/usr/bin/env bash
# 让 FOD 属性对 system_server / system_app 可读，并在 odm 固化指纹校准标记
# 1) vendor_property_contexts 把 persist.vendor.sys.fp.fod.* 与 persist.vendor.sys.fp.vendor
#    重标为 vendor_frc_prop（system_server/system_app 有 file read；vendor_init 有 set）
# 2) odm build.prop 固化 vendor.fingerprint.cali=1（UFF HAL 校准闸，否则录入报 HW_UNAVAILABLE）
# 用法：
#   VENDOR_STAGE=... VENDOR_CTX=... ODM_STAGE=... ODM_CTX=... \
#   OUT_VENDOR_IMG=... OUT_ODM_IMG=... ./build_vendor_odm_fp_props.sh
set -euo pipefail
VENDOR_STAGE="${VENDOR_STAGE:?}"
VENDOR_CTX="${VENDOR_CTX:?}"
ODM_STAGE="${ODM_STAGE:?}"
ODM_CTX="${ODM_CTX:?}"
OUT_VENDOR_IMG="${OUT_VENDOR_IMG:?}"
OUT_ODM_IMG="${OUT_ODM_IMG:?}"
VCTX="$VENDOR_STAGE/etc/selinux/vendor_property_contexts"

echo "== [1] vendor property contexts =="
grep -q "^persist.vendor.sys.fp.fod\." "$VCTX" || cat >> "$VCTX" <<'EOF'
persist.vendor.sys.fp.fod. u:object_r:vendor_frc_prop:s0
persist.vendor.sys.fp.vendor u:object_r:vendor_frc_prop:s0
EOF
tail -3 "$VCTX"

echo "== [2] 重建 vendor =="
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/vendor \
  --file-contexts="$VENDOR_CTX" "$(dirname "$OUT_VENDOR_IMG")/vendor_tmp.raw.img" "$VENDOR_STAGE" >/dev/null 2>&1
fsck.erofs "$(dirname "$OUT_VENDOR_IMG")/vendor_tmp.raw.img" >/dev/null && echo "  fsck OK"
img2simg "$(dirname "$OUT_VENDOR_IMG")/vendor_tmp.raw.img" "$OUT_VENDOR_IMG" 4096
sha256sum "$OUT_VENDOR_IMG"

echo "== [3] odm 固化 cali =="
for f in "$ODM_STAGE/build.prop" "$ODM_STAGE/etc/build.prop"; do
  [ -f "$f" ] || continue
  grep -q "^vendor.fingerprint.cali=" "$f" || printf '\nvendor.fingerprint.cali=1\n' >> "$f"
  grep -n "vendor.fingerprint.cali" "$f"
done

echo "== [4] 重建 odm =="
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm \
  --file-contexts="$ODM_CTX" "$(dirname "$OUT_ODM_IMG")/odm_tmp.raw.img" "$ODM_STAGE" >/dev/null 2>&1
fsck.erofs "$(dirname "$OUT_ODM_IMG")/odm_tmp.raw.img" >/dev/null && echo "  fsck OK"
img2simg "$(dirname "$OUT_ODM_IMG")/odm_tmp.raw.img" "$OUT_ODM_IMG" 4096
sha256sum "$OUT_ODM_IMG"
echo VENDOR_ODM_FP_PROPS_DONE
