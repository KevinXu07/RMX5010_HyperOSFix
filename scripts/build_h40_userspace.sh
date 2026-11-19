#!/usr/bin/env bash
# build_h40_userspace.sh — rebuild system / system_ext / product for a new
# haotian donor build (first used for OS4.0.4.0.XOBCNXM, 2026-11-17).
#
# Every other partition of the 54-partition package (odm, vendor, my_*,
# vbmeta x3, firmware, boot set) is donor-independent and is carried over
# byte-for-byte from the previous package.
#
#   PAYLOAD=/mnt/e/.../payload.bin \
#   REF=/root/h40/ref \            # previous package's system/system_ext/product
#                                  # mounted (or extracted) as $REF/{system,system_ext,product}
#   W=/root/h40 ./build_h40_userspace.sh
#
# Output: $W/out/{system,system_ext,product}.raw.img (raw EROFS, fsck-checked).
# Needs: python3, mkfs.erofs/fsck.erofs, smali/baksmali, getfattr, loop mounts.
#
# Files that are carried over verbatim come from $REF (the shipped package):
# the product build.prop RMX block, the panel brightness curve, the
# fingerprint feature XML, the three OplusCamera permission XMLs, the
# OplusCamera directory and XMNfcNci.apk.  Compare the result with
# $REF afterwards: file lists, build.prop keys, haotian.xml and SELinux labels.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
PAYLOAD="${PAYLOAD:?PAYLOAD (donor payload.bin) required}"
REF="${REF:?REF (previous package system/system_ext/product roots) required}"
W="${W:-/root/h40}"
IMG="$W/images"; M="$W/mnt"; ST="$W/stage"; OUT="$W/out"
mkdir -p "$IMG" "$M" "$OUT"
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "extract donor partitions"
for p in system system_ext product mi_ext mi_product; do
  [ -f "$IMG/$p.img" ] || python3 "$REPO/scripts/payload_extract_bin.py" "$PAYLOAD" "$IMG" --only "$p"
done
for p in system system_ext product mi_ext mi_product; do
  mkdir -p "$M/new_$p"
  mountpoint -q "$M/new_$p" || mount -o loop,ro "$IMG/$p.img" "$M/new_$p"
done

log "base stage (build_haotian_h19_boot.sh recipe)"
rm -rf "$ST"; mkdir -p "$ST"
cp -a "$M/new_system/." "$ST/system/"
cp -a "$M/new_system_ext/." "$ST/system_ext/"
cp -a "$M/new_product/." "$ST/product/"
cp -a "$M/new_mi_ext/system/." "$ST/system/system/"
cp -a "$M/new_mi_ext/system_ext/." "$ST/system_ext/"
cp -a "$M/new_mi_ext/product/." "$ST/product/"
[ -d "$M/new_product/pangu/system" ] && cp -a "$M/new_product/pangu/system/." "$ST/system/system/"
rm -rf "$ST/product/pangu" \
       "$ST/system/system/app/Nfc_st" "$ST/system/system/app/nfc_st" \
       "$ST/product/app/Nfc_st" "$ST/product/app/nfc_st" "$ST/product/app/Updater"
python3 - "$ST/product/etc/build.prop" "$M/new_mi_ext/etc/build.prop" <<'PY'
import sys
dst, src = sys.argv[1:]
lines = open(dst, encoding='utf-8', errors='replace').read().splitlines()
keys = {x.split('=', 1)[0] for x in lines if '=' in x and not x.lstrip().startswith('#')}
extra = []
for line in open(src, encoding='utf-8', errors='replace').read().splitlines():
    if not line or line.lstrip().startswith('#') or '=' not in line:
        continue
    k = line.split('=', 1)[0]
    if k not in keys:
        extra.append(line); keys.add(k)
if extra:
    lines += ['', '# merged from mi_ext/build.prop (OS4 RMX5010 port h19)', *extra]
open(dst, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines) + '\n')
print(f"  mi_ext props merged: {len(extra)}")
PY
rm -f "$ST/system/system/etc/init/init.miui.mi_ext.rc" \
      "$ST/system/system/etc/build.prop" "$ST/system/system/etc/NOTICE.xml.gz"

log "system: TeleService XtsApp patch"
SW="$W/work_signal"; rm -rf "$SW"; mkdir -p "$SW"
TS="$ST/system/system/priv-app/TeleService/TeleService.apk"
cp "$TS" "$SW/TeleService.apk"
( cd "$SW" && unzip -q -o TeleService.apk classes.dex -d dex && baksmali d dex/classes.dex -o split_classes )
# Same smali edits, repack and signing-block splice as build_h19_signal_fix.sh
# steps [1]-[5] (asserts all three patch sites exist; only classes.dex changes).
{ echo 'set -euo pipefail'
  echo "cd '$SW'; XTS='$SW/split_classes/com/android/phone/XtsApp.smali'"
  sed -n '/^echo .=== \[1\]/,/^echo .=== \[6\]/p' "$REPO/scripts/build_h19_signal_fix.sh" | sed '$d' \
    | sed -e 's#smali a ts_split -o#smali a split_classes -o#' \
          -e 's#diff -rq ts_split ts_rt#diff -rq split_classes ts_rt#' \
          -e "s#/root/haotian/work_signal#$SW#g"
} > "$SW/patch.sh"
bash "$SW/patch.sh"
cp -f "$SW/TeleService.patched.apk" "$TS"; chown 0:0 "$TS"; chmod 0644 "$TS"

log "system: RMX MTP rc + XMNfcNci"
RC="$ST/system/system/etc/init/hw/init.usb.configfs.rc"
cp -f "$REPO/patches/mtp-and-dpi/init.usb.configfs.rc" "$RC"; chown 0:0 "$RC"; chmod 0644 "$RC"
mkdir -p "$ST/system/system/app/XMNfcNci"
cp -a "$REF/system/system/app/XMNfcNci/XMNfcNci.apk" "$ST/system/system/app/XMNfcNci/"
setfattr -n security.selinux -v u:object_r:system_file:s0 "$ST/system/system/app/XMNfcNci"
echo "f680e8fafa51fc5d4ff76ab17deed0fbbecea331dc9c1343accf910bbba308bf  $ST/system/system/app/XMNfcNci/XMNfcNci.apk" | sha256sum -c -

log "system_ext: miui-services fingerprint stub"
J="$ST/system_ext/framework/miui-services.jar"
python3 "$REPO/scripts/patch_miui_services_fp_stub.py" "$J" "$W/miui-services.jar"
cp -f "$W/miui-services.jar" "$J"; chown 0:0 "$J"; chmod 0644 "$J"; touch -d '1970-01-01 00:00:00' "$J"
rm -f "$ST/system_ext/framework/oat/arm64/miui-services."{odex,vdex,art} \
      "$ST/system_ext/framework/oat/arm64/miui-services."*.fsv_meta \
      "$ST/system_ext/framework/miui-services.jar.fsv_meta"

log "product: DPI, RMX prop block, haotian.xml, carried files, camera"
P="$ST/product"; BP="$P/etc/build.prop"
sed -i 's/^persist\.miui\.density_v2=.*/persist.miui.density_v2=500/; s/^ro\.sf\.lcd_density=.*/ro.sf.lcd_density=500/' "$BP"
grep -q '^ro.vendor.nfc.mitouch=' "$BP" || \
  sed -n '/^# NFC: RMX5010 verified five-prop set/,$p' "$REF/product/etc/build.prop" | sed '1i\\' >> "$BP"
HX="$P/etc/device_features/haotian.xml"
sed -i -e 's|<item>1440</item>|<item>1264</item>|' \
  -e 's|<integer name="defaultFps">60</integer>|<integer name="defaultFps">120</integer>|' \
  -e 's|<float name="paper_eyecare_default_value">[0-9.]*</float>|<float name="paper_eyecare_default_value">0.0</float>|' \
  -e 's|<bool name="is_compatible_paper_and_screen_effect">true</bool>|<bool name="is_compatible_paper_and_screen_effect">false</bool>|' \
  -e 's|<bool name="front_fingerprint_sensor">false</bool>|<bool name="front_fingerprint_sensor">true</bool>|' "$HX"
grep -q '<bool name="support_fod">' "$HX" || \
  sed -i 's|\(<bool name="front_fingerprint_sensor">true</bool>\)|\1\n    <!-- FOD 屏下指纹支持（RMX5010） -->\n    <bool name="support_fod">true</bool>|' "$HX"
python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$HX"
for f in etc/displayconfig/display_id_4630947008615494291.xml \
         etc/permissions/android.hardware.fingerprint.xml \
         etc/default-permissions/default-permissions-com.oplus.camera.xml \
         etc/permissions/privapp-permissions-com.oplus.camera.xml \
         etc/sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml; do
  cp -a "$REF/product/$f" "$P/$f"
done
rm -rf "$P/priv-app/MiuiCamera"
cp -a "$REF/product/priv-app/OplusCamera" "$P/priv-app/"

log "mkfs + fsck"
cat "$ST/system/system/etc/selinux/plat_file_contexts" \
    "$ST/system_ext/etc/selinux/system_ext_file_contexts" \
    "$ST/product/etc/selinux/product_file_contexts" > "$ST/all_file_contexts"
for p in system system_ext product; do
  mp=/$p; [ "$p" = system ] && mp=/
  mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point="$mp" \
    --file-contexts="$ST/all_file_contexts" "$OUT/$p.raw.img" "$ST/$p"
  fsck.erofs "$OUT/$p.raw.img" >/dev/null
  log "  $p OK $(stat -c%s "$OUT/$p.raw.img") $(sha256sum "$OUT/$p.raw.img" | cut -c1-16)"
done
log "done — now diff against \$REF (file lists, build.prop keys, haotian.xml, labels)"
