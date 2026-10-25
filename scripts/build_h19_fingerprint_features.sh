#!/usr/bin/env bash
# 在 h19 product 镜像里固化指纹特性声明 / FOD 属性 / 设备特性开关，并重建 product.img
#
# 用法：
#   STAGE=/root/haotian/stage_h19 OUT_RAW=/root/haotian/product_fp.raw.img \
#   OUT_IMG=/mnt/e/code/modify/haotian_work/product_fp.img \
#   ./build_h19_fingerprint_features.sh
#
# 影响三处（全部可重复执行，幂等）：
#   1. product/etc/permissions/android.hardware.fingerprint.xml（新增）
#      -> pm list features 出现 android.hardware.fingerprint，SystemServer 才会起 FingerprintService
#   2. product/etc/build.prop 追加 7 个属性（坐标按 RMX5010 1264x2780 实测）
#   3. product/etc/device_features/haotian.xml
#      -> front_fingerprint_sensor=true、support_fod=true
set -euo pipefail

STAGE="${STAGE:-/root/haotian/stage_h19}"
P="$STAGE/product"
OUT_RAW="${OUT_RAW:-/root/haotian/product_fp.raw.img}"
OUT_IMG="${OUT_IMG:-/mnt/e/code/modify/haotian_work/product_fp.img}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FOD_DIR="$HERE/../patches/fingerprint-fod"

echo '=== [1] 特性声明 XML ==='
cat > "$P/etc/permissions/android.hardware.fingerprint.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- RMX5010: 声明指纹硬件特性，使 SystemServer 启动 FingerprintService -->
<permissions>
    <feature name="android.hardware.fingerprint" />
</permissions>
EOF
chown 0:0 "$P/etc/permissions/android.hardware.fingerprint.xml"
chmod 0644 "$P/etc/permissions/android.hardware.fingerprint.xml"
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$P/etc/permissions/android.hardware.fingerprint.xml'); print('  XML OK')"

echo '=== [2] product build.prop 属性 ==='
BP="$P/etc/build.prop"
if ! grep -q '^ro.hardware.fp.fod=' "$BP"; then
  printf '\n' >> "$BP"
  cat "$FOD_DIR/product_build.prop.append" >> "$BP"
fi
grep -nE 'fp\.fod|fp\.vendor' "$BP"

echo '=== [3] device_features 开关 ==='
HX="$P/etc/device_features/haotian.xml"
sed -i 's|<bool name="front_fingerprint_sensor">false</bool>|<bool name="front_fingerprint_sensor">true</bool>|' "$HX"
grep -q '<bool name="support_fod">' "$HX" || \
  sed -i 's|\(<bool name="front_fingerprint_sensor">true</bool>\)|\1\n    <!-- FOD 屏下指纹支持（RMX5010） -->\n    <bool name="support_fod">true</bool>|' "$HX"
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$HX'); print('  XML OK')"
grep -nE 'front_fingerprint_sensor|support_fod|fod_solution' "$HX"

echo '=== [4] 重建 product.img ==='
CTXF="$STAGE/all_file_contexts"
cat "$STAGE/system/system/etc/selinux/plat_file_contexts" \
    "$STAGE/system_ext/etc/selinux/system_ext_file_contexts" \
    "$P/etc/selinux/product_file_contexts" > "$CTXF"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/product \
  --file-contexts="$CTXF" "$OUT_RAW" "$P" >/dev/null 2>&1
fsck.erofs "$OUT_RAW" >/dev/null && echo "  fsck OK"
img2simg "$OUT_RAW" "$OUT_IMG" 4096
ls -la "$OUT_IMG" | awk '{print "  img:", $5, $NF}'

echo '=== [5] 镜像内抽查 ==='
M=/tmp/product_fp_verify
umount "$M" 2>/dev/null || true
mkdir -p "$M"; mount -o loop,ro "$OUT_RAW" "$M"
getfattr -h -n security.selinux --only-values \
  "$M/etc/permissions/android.hardware.fingerprint.xml"; echo
grep -nE 'fp\.fod|fp\.vendor' "$M/etc/build.prop" | head -8
grep -nE 'front_fingerprint_sensor|support_fod' "$M/etc/device_features/haotian.xml"
umount "$M"
echo FINGERPRINT_FEATURES_BUILD_DONE
