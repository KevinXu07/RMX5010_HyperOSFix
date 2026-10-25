#!/usr/bin/env bash
set -euo pipefail

echo '=== [1] odm: 删双处 high_pwm_rgb ==='
O=/root/odm_identity_fix
sed -i '/^ro\.vendor\.opus\.sensor\.high_pwm_rgb=true$/d' \
  "$O/odm_stage/build.prop" "$O/odm_stage/etc/build.prop"
grep -c "high_pwm_rgb" "$O/odm_stage/build.prop" "$O/odm_stage/etc/build.prop" | sed 's/^/  残留(应为0): /' || true
OUTF=/root/odm_identity_fix/odm_als.raw.img
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm \
  --file-contexts="$O/odm_mkfs_contexts" "$OUTF" "$O/odm_stage" >/dev/null 2>&1
fsck.erofs "$OUTF" >/dev/null && echo "  odm fsck OK"

echo '=== [2] product: 放入本机曲线(仓库已验证载荷) ==='
P=/root/haotian/stage_h19
DC="$P/product/etc/displayconfig"
cp /mnt/e/code/modify/RMX5010_HyperOSFix/patches/brightness-overlay/display_id_4630947008615494291.xml "$DC/"
chown 0:0 "$DC/display_id_4630947008615494291.xml"
chmod 0644 "$DC/display_id_4630947008615494291.xml"
ls -la "$DC" | sed 's/^/  /'
CTXF="$P/all_file_contexts"
cat "$P/system/system/etc/selinux/plat_file_contexts" \
    "$P/system_ext/etc/selinux/system_ext_file_contexts" \
    "$P/product/etc/selinux/product_file_contexts" > "$CTXF"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/product \
  --file-contexts="$CTXF" /root/haotian/product_als.raw.img "$P/product" >/dev/null 2>&1
fsck.erofs /root/haotian/product_als.raw.img >/dev/null && echo "  product fsck OK"

echo '=== [3] sparse 化 ==='
img2simg "$OUTF" /mnt/e/code/modify/haotian_work/odm_als.img 4096
img2simg /root/haotian/product_als.raw.img /mnt/e/code/modify/haotian_work/product_als.img 4096
ls -la /mnt/e/code/modify/haotian_work/odm_als.img /mnt/e/code/modify/haotian_work/product_als.img | awk '{print "  ", $5, $NF}'
echo ALS_BUILD_DONE
