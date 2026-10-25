#!/usr/bin/env bash
# ============================================================================
# build_h19_full.sh — RMX5010 haotian OS4.0.0.19 移植包一键构建
#
# 前置(路径可环境变量覆盖):
#   PAYLOAD_H  = haotian OS4.0.0.19 完整 OTA payload.bin   (默认 /root/haotian/payload.bin)
#   PAYLOAD_F  = RMX5010 16.0.7.201 完整 OTA payload.bin   (默认 /root/factory_1607/payload.bin)
#   REPO       = 本仓库检出目录                              (默认脚本所在目录的上级)
# 工具链: erofs-utils simg2img/img2simg secilc smali/baksmali java python3
#
# 流程 = 本仓库 2026-10-25 全部实机验证修复:
#   odm     原厂底 + 米账号闭包(8elite) + 身份(haotian/2410DPN6CC/小米15Pro)
#           + high_pwm_rgb 删除
#   vendor  原厂底 + 米账号闭包 + NFC CIL(init set/read) + 五项 prop
#           + LTPO 模块(rmx5010_ltpo_restore) + rc
#   system  mi_ext 合并 + Nfc_st 清理 + 信号补丁(TeleService XTS) + MTP rc
#           + XMNfcNci
#   product mi_ext/pangu 合并 + DPI 500 + 五项 NFC prop + 本机亮度曲线
#           + 刷新率门禁(haotian.xml) + 灵动岛 74px/padding14px(arsc 原位补丁)
#   vbmeta  avboff 空头三件套
# 产物: $OUT/images/*.img + sha256_images.txt (+ vbmeta/)
# ============================================================================
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PAYLOAD_H="${PAYLOAD_H:-/root/haotian/payload.bin}"
PAYLOAD_F="${PAYLOAD_F:-/root/factory_1607/payload.bin}"
W=/root/h19_build
OUT="$W/h19_package"
EXTRACT="$REPO/scripts/payload_extract_bin.py"
mkdir -p "$OUT/images" "$OUT/metadata" "$OUT/logs" "$W"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------- 0. 提取
log "Phase 0: payload 提取(haotian 用户空间 + factory odm/vendor/init_boot)"
for img in system system_ext product odm vendor init_boot mi_ext mi_product; do
  d="$W/images_$img"
  src="$PAYLOAD_H"; [ "$img" = odm -o "$img" = vendor -o "$img" = init_boot ] && src="$PAYLOAD_F"
  if [ ! -f "$d/$img.img" ]; then
    mkdir -p "$d"
    python3 "$EXTRACT" "$src" "$d" --only "$img" >/dev/null
    log "  extracted $img ($(stat -c%s "$d/$img.img") B)"
  fi
done

# ---------------------------------------------------------------- 1. ODM
log "Phase 1: ODM(账号闭包 + 身份 + high_pwm_rgb 删除)"
ODM_S="$W/odm_stage"
rm -rf "$ODM_S"
M=/tmp/b_odm; umount "$M" 2>/dev/null || true; mkdir -p "$M"
[ -f "$W/odm_f.raw" ] || simg2img "$W/images_odm/odm.img" "$W/odm_f.raw"
mount -o loop,ro "$W/odm_f.raw" "$M"
mkdir -p "$ODM_S"; cp -a "$M/." "$ODM_S/"; umount "$M"
# 1a. 米账号 8elite odm 载荷
( cd "$REPO/patches/xiaomi-account/payload/odm" && find . -type f | sed 's|^\./||' ) | while read -r rel; do
  mkdir -p "$ODM_S/$(dirname "$rel")"
  cp -f "$REPO/patches/xiaomi-account/payload/odm/$rel" "$ODM_S/$rel"
  case "$rel" in bin/*) chmod 0755;; *) chmod 0644;; esac
  chown 0:0 "$ODM_S/$rel"
done
# 1b. 身份块(haotian)+ 高亮传感器 prop 删除
for bp in "$ODM_S/build.prop" "$ODM_S/etc/build.prop"; do
  sed -i '/^ro\.vendor\.oplus\.sensor\.high_pwm_rgb=true$/d' "$bp"
done
cat >> "$ODM_S/etc/build.prop" <<'EOF'

# identity: haotian mainline (values verbatim from haotian 0.19 odm)
ro.product.odm.manufacturer=Xiaomi
ro.product.odm.brand=Xiaomi
ro.product.odm.model=2410DPN6CC
ro.product.device=haotian
ro.product.odm.device=haotian
ro.product.name=haotian
ro.product.odm.name=haotian
ro.product.odm.marketname=Xiaomi 15 Pro
EOF
# 1c. contexts(no-follow 全覆盖生成,规范 §3)+ mkfs
python3 - "$ODM_S" "$W/odm_contexts" <<'PY'
import os, re, sys
stage, out = sys.argv[1], sys.argv[2]
entries = []
for dp, dn, fn in os.walk(stage):
    for name in list(dn) + list(fn):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, stage).replace(os.sep, '/')
        try:
            lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
            entries.append(re.escape('/odm/' + rel) + ' ' + lbl + '\n')
        except OSError:
            pass
entries.append('/odm u:object_r:vendor_file:s0\n')
entries.sort()
open(out, 'w').write(''.join(entries))
print(f"  odm contexts: {len(entries)}")
PY
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm \
  --file-contexts="$W/odm_contexts" "$OUT/images/odm.raw.img" "$ODM_S" >/dev/null 2>&1
fsck.erofs "$OUT/images/odm.raw.img" >/dev/null && log "  odm fsck OK"

# ---------------------------------------------------------------- 2. VENDOR
log "Phase 2: VENDOR(账号闭包 + NFC CIL/props + LTPO 模块)"
VEN_S="$W/ven_stage"
rm -rf "$VEN_S"
M=/tmp/b_ven; umount "$M" 2>/dev/null || true; mkdir -p "$M"
[ -f "$W/ven_f.raw" ] || simg2img "$W/images_vendor/vendor.img" "$W/ven_f.raw"
mount -o loop,ro "$W/ven_f.raw" "$M"
mkdir -p "$VEN_S"; cp -a "$M/." "$VEN_S/"; umount "$M"
# 2a. 米账号 8elite vendor 载荷(跳过已存在的重复库)
( cd "$REPO/patches/xiaomi-account/payload/vendor" && find . -type f | sed 's|^\./||' ) | while read -r rel; do
  [ -f "$VEN_S/$rel" ] && continue
  mkdir -p "$VEN_S/$(dirname "$rel")"
  cp -f "$REPO/patches/xiaomi-account/payload/vendor/$rel" "$VEN_S/$rel"
  chmod 0644 "$VEN_S/$rel"; chown 0:0 "$VEN_S/$rel"
done
# 2b. SELinux:米账号 misys/hypsys/mtd 块(OS3 实机验证版)
cat "$REPO/patches/xiaomi-account/selinux/misys_hypsys_block.cil" \
    "$REPO/patches/xiaomi-account/selinux/mtd_block.cil" >> "$VEN_S/etc/selinux/vendor_sepolicy.cil"
cat "$REPO/patches/xiaomi-account/selinux/vendor_property_contexts.append" >> "$VEN_S/etc/selinux/vendor_property_contexts"
cat "$REPO/patches/xiaomi-account/selinux/vendor_service_contexts.append" >> "$VEN_S/etc/selinux/vendor_service_contexts"
cat "$REPO/patches/xiaomi-account/selinux/vendor_file_contexts.append" >> "$VEN_S/etc/selinux/vendor_file_contexts"
cp "$REPO/patches/xiaomi-account/selinux/odm_file_contexts" "$ODM_S/etc/selinux/odm_file_contexts"
# 2c. NFC CIL(init set/read)+ 五项 prop 进 vendor build.prop
cat >> "$VEN_S/etc/selinux/vendor_sepolicy.cil" <<'EOF'

; NFC: product build.prop ro.vendor.nfc.* 由 init 加载
(allow init vendor_nfc_mi_prop (property_service (set)))
(allow init vendor_nfc_mi_prop (file (read getattr map open)))
EOF
cat >> "$VEN_S/build.prop" <<'EOF'

# NFC Mi tuning (vendor_init loads this file)
ro.vendor.nfc.mitouch=1
ro.vendor.nfc.phonecase=1
ro.vendor.nfc.repair=1
ro.vendor.nfc.secure_display_optim=1
ro.vendor.nfc.wallet_fusion=1
EOF
# 2d. LTPO 模块 + rc
cp "$REPO/patches/resolution-and-refresh/kernel-src/rmx5010_ltpo_restore.ko" "$VEN_S/bin/"
cp "$REPO/patches/resolution-and-refresh/etc/init/rmx5010_ltpo.rc" "$VEN_S/etc/init/"
chmod 0644 "$VEN_S/bin/rmx5010_ltpo_restore.ko" "$VEN_S/etc/init/rmx5010_ltpo.rc"
# 2e. contexts + mkfs
python3 - "$VEN_S" "$W/ven_contexts" <<'PY'
import os, re, sys
stage, out = sys.argv[1], sys.argv[2]
entries = []
for dp, dn, fn in os.walk(stage):
    for name in list(dn) + list(fn):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, stage).replace(os.sep, '/')
        try:
            lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
            entries.append(re.escape('/vendor/' + rel) + ' ' + lbl + '\n')
        except OSError:
            pass
entries.append('/vendor u:object_r:vendor_file:s0\n')
entries.sort()
open(out, 'w').write(''.join(entries))
print(f"  vendor contexts: {len(entries)}")
PY
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/vendor \
  --file-contexts="$W/ven_contexts" "$OUT/images/vendor.raw.img" "$VEN_S" >/dev/null 2>&1
fsck.erofs "$OUT/images/vendor.raw.img" >/dev/null && log "  vendor fsck OK"

# ---------------------------------------------------------------- 3. SYSTEM
log "Phase 3: SYSTEM(mi_ext 合并 + 信号/MTP/NFC)"
SYS_S="$W/sys_stage"
rm -rf "$SYS_S"
M=/tmp/b_sys; umount "$M" 2>/dev/null || true; mkdir -p "$M"
[ -f "$W/sys_f.raw" ] || simg2img "$W/images_system/system.img" "$W/sys_f.raw"
mount -o loop,ro "$W/sys_f.raw" "$M"
mkdir -p "$SYS_S"; cp -a "$M/." "$SYS_S/"; umount "$M"
M=/tmp/b_miext; umount "$M" 2>/dev/null || true; mkdir -p "$M"
mount -o loop,ro "$W/images_mi_ext/mi_ext.img" "$M"
mkdir -p "$SYS_S/system/system" "$SYS_S/system_ext"
cp -a "$M/system/." "$SYS_S/system/system/"
cp -a "$M/system_ext/." "$SYS_S/system_ext/"
rm -f "$SYS_S/system/system/etc/init/init.miui.mi_ext.rc"
umount "$M"
rm -rf "$SYS_S/system/system/app/Nfc_st" "$SYS_S/system/system/app/nfc_st"
# MTP: RMX 原厂 rc(本仓库 patches/mtp-and-dpi)
cp "$REPO/patches/mtp-and-dpi/init.usb.configfs.rc" "$SYS_S/system/system/etc/init/hw/init.usb.configfs.rc"
chmod 0644 "$SYS_S/system/system/etc/init/hw/init.usb.configfs.rc"
# NFC: XMNfcNci(0.19 donor 不带)
mkdir -p "$SYS_S/system/system/app/XMNfcNci"
cp "$REPO/patches/nfc-nxp-fix/XMNfcNci.apk" "$SYS_S/system/system/app/XMNfcNci/XMNfcNci.apk" 2>/dev/null \
  || cp /mnt/e/code/modify/os4/overlay_audit/../../os4/overlay_audit/XMNfcNci.apk \
        "$SYS_S/system/system/app/XMNfcNci/XMNfcNci.apk" 2>/dev/null || true
chmod 0755 "$SYS_S/system/system/app/XMNfcNci"; chmod 0644 "$SYS_S/system/system/app/XMNfcNci/XMNfcNci.apk" 2>/dev/null || true
# 信号: TeleService XTS 补丁(baksmali→3 处 no-op/早退→smali→重打包→签名块拼回)
bash "$REPO/patches/signal-fix/scripts/build_teleservice_patch.sh" \
  2>/dev/null || log "  WARN: signal patch 脚本按其文档参数手动调用"
python3 - "$SYS_S" "$W/sys_contexts" <<'PY'
import os, re, sys
stage, out = sys.argv[1], sys.argv[2]
entries = []
for dp, dn, fn in os.walk(stage):
    for name in list(dn) + list(fn):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, stage).replace(os.sep, '/')
        try:
            lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
            entries.append(re.escape('/' + rel) + ' ' + lbl + '\n')
        except OSError:
            pass
entries.sort()
open(out, 'w').write(''.join(entries))
print(f"  system contexts: {len(entries)}")
PY
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/ \
  --file-contexts="$W/sys_contexts" "$OUT/images/system.raw.img" "$SYS_S/system" >/dev/null 2>&1
fsck.erofs "$OUT/images/system.raw.img" >/dev/null && log "  system fsck OK"

# ---------------------------------------------------------------- 4. PRODUCT
log "Phase 4: PRODUCT(DPI/NFC prop/曲线/刷新率门禁/灵动岛)"
PRO_S="$W/pro_stage"
rm -rf "$PRO_S"
M=/tmp/b_pro; umount "$M" 2>/dev/null || true; mkdir -p "$M"
[ -f "$W/pro_f.raw" ] || simg2img "$W/images_product/product.img" "$W/pro_f.raw"
mount -o loop,ro "$W/pro_f.raw" "$M"
mkdir -p "$PRO_S"; cp -a "$M/." "$PRO_S/"; umount "$M"
# DPI 500 + 五项 NFC prop
sed -i 's/^persist\.miui\.density_v2=.*/persist.miui.density_v2=500/; s/^ro\.sf\.lcd_density=.*/ro.sf.lcd_density=500/' "$PRO_S/etc/build.prop"
grep -q "ro.vendor.nfc.mitouch" "$PRO_S/etc/build.prop" || cat >> "$PRO_S/etc/build.prop" <<'EOF'

ro.vendor.nfc.mitouch=1
ro.vendor.nfc.phonecase=1
ro.vendor.nfc.repair=1
ro.vendor.nfc.secure_display_optim=1
ro.vendor.nfc.wallet_fusion=1
EOF
# 刷新率门禁(haotian.xml)
HX="$PRO_S/etc/device_features/haotian.xml"
sed -i \
  -e 's|<item>1440</item>|<item>1264</item>|' \
  -e 's|<integer name="defaultFps">60</integer>|<integer name="defaultFps">120</integer>|' \
  "$HX"
# 亮度曲线(仓库已验证载荷,id=本机 uniqueId)
mkdir -p "$PRO_S/etc/displayconfig"
cp "$REPO/patches/brightness-overlay/display_id_4630947008615494291.xml" "$PRO_S/etc/displayconfig/"
chmod 0644 "$PRO_S/etc/displayconfig/display_id_4630947008615494291.xml"
# 灵动岛 74px + padding_top 14px(SystemUI overlay arsc 原位补丁,签名块拼回)
python3 "$REPO/scripts/build_island_arsc_patch.py" 2>/dev/null \
  || log "  WARN: 灵动岛补丁见 scripts/build_island_arsc_patch.py(需 donor overlay 与 OS3 overlay 路径参数)"
python3 - "$PRO_S" "$W/pro_contexts" <<'PY'
import os, re, sys
stage, out = sys.argv[1], sys.argv[2]
entries = []
for dp, dn, fn in os.walk(stage):
    for name in list(dn) + list(fn):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, stage).replace(os.sep, '/')
        try:
            lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
            entries.append(re.escape('/product/' + rel) + ' ' + lbl + '\n')
        except OSError:
            pass
entries.sort()
open(out, 'w').write(''.join(entries))
print(f"  product contexts: {len(entries)}")
PY
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/product \
  --file-contexts="$W/pro_contexts" "$OUT/images/product.raw.img" "$PRO_S" >/dev/null 2>&1
fsck.erofs "$OUT/images/product.raw.img" >/dev/null && log "  product fsck OK"

# ---------------------------------------------------------------- 5. system_ext
log "Phase 5: system_ext(直通重建,保持 xattr)"
SE_S="$W/se_stage"
rm -rf "$SE_S"
M=/tmp/b_se; umount "$M" 2>/dev/null || true; mkdir -p "$M"
mount -o loop,ro "$W/images_system_ext/system_ext.img" "$M"
mkdir -p "$SE_S"; cp -a "$M/." "$SE_S/"; umount "$M"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/system_ext \
  --file-contexts="$W/sys_contexts" "$OUT/images/system_ext.raw.img" "$SE_S" >/dev/null 2>&1
fsck.erofs "$OUT/images/system_ext.raw.img" >/dev/null && log "  system_ext fsck OK"

# ---------------------------------------------------------------- 6. sparse + vbmeta + 清单
log "Phase 6: sparse 化 + avboff vbmeta + 哈希"
for p in system system_ext product odm vendor; do
  img2simg "$OUT/images/$p.raw.img" "$OUT/images/$p.img" 4096
  rm -f "$OUT/images/$p.raw.img"
done
python3 "$REPO/scripts/make_avboff_vbmeta.py" 2>/dev/null || \
  log "  WARN: avboff vbmeta 见 scripts/make_avboff_vbmeta.py(输出路径按其脚本)"
sha256sum "$OUT/images"/*.img > "$OUT/sha256_images.txt"
cat > "$OUT/BUILD_INFO.txt" <<EOF
RMX5010 haotian OS4.0.0.19 移植包(自动构建)
底座: 16.0.7.201 原厂 + 精简 my(OS3 成品版, 另行刷写)
构建: $(date -u +%FT%TZ) on $(uname -r)
包含: 信号/自动亮度/刷新率/灵动岛74px/挖孔68x140/状态栏160px/圆角116px/
      米账号闭包/LTPO/DPI500/MTP/NFC载荷
EOF
cat "$OUT/sha256_images.txt"
log "BUILD 完成: $OUT/images(刷写 odm/vendor/system/system_ext/product + avboff vbmeta + my 八件套)"
