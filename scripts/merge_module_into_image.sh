#!/usr/bin/env bash
# merge_module_into_image.sh — bake the static part of the rmx5010_fod_bridge
# KSU module into the haotian userspace images ("可以直接做进镜像" in
# docs/模块改动入镜像可行性.md).  First used for OS4.0.4.0, 2026-11-17.
#
#   W=/root/h40 RB=/mnt/e/code/modify/h40_work/readback ./merge_module_into_image.sh
#
# Input:  $W/stage/{system,system_ext,product}  stage left by build_h40_userspace.sh
#         $RB/{odm,vendor}.img                   the stock RMX5010 odm / vendor images
#                                                the package ships unchanged
#         kernel-src/ksu-module                  the module tree (source of every file)
# Output: $W/out_merged/{system,system_ext,product,odm,vendor}.raw.img
#
# The stage is modified in place and every step is idempotent.  odm and vendor
# are rebuilt from a copy of the stock image that keeps every original owner,
# mode, capability and SELinux xattr (no file_contexts pass); new files there
# get an explicit label.  system / system_ext / product are labelled from the
# concatenated file_contexts exactly like build_h40_userspace.sh.
#
# Product build.prop gets ro.rmx5010.image_merge=1; module 1.7.27+ skips the
# parts that this script bakes in when it sees that property.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
K="$REPO/kernel-src/ksu-module"
W="${W:-/root/h40}"
RB="${RB:?RB (directory with the stock odm.img / vendor.img) required}"
ST="$W/stage"; OUT="$W/out_merged"; M="$W/mnt"; T="$W/merge_tmp"
SO="$W/stage_odm"; SV="$W/stage_vendor"
SYS="$ST/system/system"; SE="$ST/system_ext"; PR="$ST/product"
mkdir -p "$OUT" "$M" "$T"
log() { echo "[$(date +%H:%M:%S)] $*"; }
need() { for f; do [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }; done; }
need "$SYS/build.prop" "$SE/etc/build.prop" "$PR/etc/build.prop" "$RB/odm.img" "$RB/vendor.img"

# Overwrite an existing file's content (keeps its owner, mode and xattrs) or
# create a new root-owned file with the given mode.
put() {
  src=$1; dst=$2; mode=$3
  need "$src"
  if [ -f "$dst" ]; then
    cp -f "$src" "$dst"
  else
    install -D -m "$mode" -o 0 -g 0 "$src" "$dst"
  fi
}
# set_prop FILE KEY VALUE: replace KEY in place, or append it to the RMX block.
set_prop() {
  f=$1; k=$2; v=$3
  if grep -q "^$k=" "$f"; then
    sed -i "s|^$k=.*|$k=$v|" "$f"
  else
    grep -q '^# RMX5010 module merge' "$f" || printf '\n# RMX5010 module merge: values the rmx5010_fod_bridge module used to set at boot\n' >> "$f"
    echo "$k=$v" >> "$f"
  fi
}

# cosw_patched NAME SRC.apk PATCH_SCRIPT [BRIDGE.dex] -> prints the patched APK
# path.  Runs PATCH_SCRIPT (SRC [BRIDGE] out.zip) and scripts/apk_repack.py
# (original signing block, original length if the block records one).  smali
# reassembly is not byte-reproducible, so the result is cached per input hash
# in $W/cos-wallet/ (seeded with the APKs tested on the device) to keep the
# image stable across runs.  Logs go to stderr.
cosw_patched() {
  name=$1; src=$2; script=$3; dex=${4:-}
  need "$src" "$script" ${dex:+"$dex"}
  key=$(cat "$script" "$REPO/scripts/apk_repack.py" ${dex:+"$dex"} "$src" | sha256sum | cut -c1-12)
  out="$W/cos-wallet/$name.patched.$key.apk"
  if [ ! -f "$out" ]; then
    mkdir -p "$W/cos-wallet"
    python3 -I "$script" "$src" ${dex:+"$dex"} "$T/$name.unsigned.zip" | grep -v '^+' >&2
    python3 -I "$REPO/scripts/apk_repack.py" "$src" "$T/$name.unsigned.zip" "$T/$name.repacked.apk" >&2
    mv "$T/$name.repacked.apk" "$out"
  fi
  echo "  $name: $(basename "$out")" >&2
  echo "$out"
}

# ---------------------------------------------------------------- product
log "product: Devices overlays (zipalign, original signing block)"
for n in DevicesOverlay DevicesAndroidOverlay; do
  python3 -I "$REPO/scripts/apk_sigblock.py" strip "$K/overlay/$n.apk" "$T/$n.unsigned.zip"
  zipalign -p -f 4 "$T/$n.unsigned.zip" "$T/$n.aligned.zip"
  # The stage copy is the donor original (or an earlier run's output, which
  # carries the same block).
  python3 -I "$REPO/scripts/apk_sigblock.py" splice "$T/$n.aligned.zip" "$PR/overlay/$n.apk" "$T/$n.apk"
  python3 -I "$REPO/scripts/apk_sigblock.py" check "$T/$n.apk"
  put "$T/$n.apk" "$PR/overlay/$n.apk" 0644
done

log "product: screen colour modes overlay (ColorOS render intents 301/303/307)"
# RmxScreenColorBridge (in miui-services, see system_ext below) writes these
# intents to display_color_mode; ColorDisplayService only accepts modes listed
# in config_availableColorModes.  Built by scripts/build_miui_services_bridges.sh.
put "$REPO/patches/screen-color/RMX5010ColorModes.apk" "$PR/overlay/RMX5010ColorModes.apk" 0644
python3 -I "$REPO/scripts/apk_sigblock.py" check "$PR/overlay/RMX5010ColorModes.apk"

log "product: brightness curve"
put "$K/overlay/display_id_4630947008615494291.xml" \
    "$PR/etc/displayconfig/display_id_4630947008615494291.xml" 0644

log "product: OplusCamera 6.070.45 + private libs, provider / gallery stubs"
CAM="$K/camera"
put "$CAM/priv-app/MiuiCamera/OplusCamera.apk" "$PR/priv-app/OplusCamera/OplusCamera.apk" 0644
rm -rf "$PR/priv-app/OplusCamera/oat"
mkdir -p "$PR/priv-app/OplusCamera/lib/arm64"
for f in "$CAM/priv-app/MiuiCamera/lib/arm64/"*.so; do
  put "$f" "$PR/priv-app/OplusCamera/lib/arm64/$(basename "$f")" 0644
done
put "$CAM/priv-app/MiuiCamera/MiuiCameraProviderStub.apk" \
    "$PR/priv-app/MiuiCameraProviderStub/MiuiCameraProviderStub.apk" 0644
put "$CAM/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk" \
    "$PR/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk" 0644
chmod 0755 "$PR/priv-app/OplusCamera/lib" "$PR/priv-app/OplusCamera/lib/arm64" \
           "$PR/priv-app/MiuiCameraProviderStub" "$PR/priv-app/ColorOSGalleryStub"
python3 -I "$REPO/scripts/apk_sigblock.py" check "$PR/priv-app/OplusCamera/OplusCamera.apk" \
  "$PR/priv-app/MiuiCameraProviderStub/MiuiCameraProviderStub.apk" \
  "$PR/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk"
for f in permissions/privapp-permissions-com.oplus.camera.xml \
         default-permissions/default-permissions-com.oplus.camera.xml \
         sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml; do
  put "$CAM/etc/$f" "$PR/etc/$f" 0644
done

log "product: ColorOS wallet set preinstalled in app/ (was pm install by the module)"
# Unmodified release APKs (signing block and arsc alignment checked).  System
# apps do not get their compressed JNI libs extracted, so put the arm64 ones in
# lib/arm64; HTMS stores its libs page-aligned (extractNativeLibs=false) and
# loads them from the APK.
# The donor has its own app/UPTsmService (com.unionpay.tsmservice.mi) and
# app/EidService (com.rongcard.eid); the wallet set's packages differ
# (com.unionpay.tsmservice, com.oplus.eid), so keep the donor dirs as they are
# and use CosWallet<name> dirs.  Restore the donor copies in case an earlier
# run of this script overwrote them.
mkdir -p "$M/new_product"
mountpoint -q "$M/new_product" || mount -o loop,ro "$W/images/product.img" "$M/new_product"
rm -rf "$PR/app/FinShellWallet" "$PR/app/TasWallet" "$PR/app/HeytapHTMS"
for n in UPTsmService EidService; do
  if [ -d "$M/new_product/app/$n" ]; then
    rm -rf "$PR/app/$n"; cp -a "$M/new_product/app/$n" "$PR/app/"
  fi
done
WAL="$K/installer/wallet"
# FinShell / TAS / UnionPay TSM / eID carry the image version of the module's
# wallet-process hooks (scripts/patch_cos_wallet.py + patches/cos-wallet/
# RmxWalletShim.java; scripts/patch_eid_service.py), HTMS stays stock.  Their
# v2/v3 blocks carry a VERITY_CHUNKED_SHA256 digest that records the content
# length, so scripts/apk_repack.py pads the patched APK back to the exact
# original length before splicing the original block (otherwise PMS fails to
# collect the certificates at boot and silently drops the package).
for n in FinShellWallet TasWallet HeytapHTMS UPTsmService EidService; do
  d="$PR/app/CosWallet$n"
  rm -rf "$d"; mkdir -p "$d"; chmod 0755 "$d"
  case $n in
    HeytapHTMS) src="$WAL/$n.apk" ;;
    EidService) src=$(cosw_patched "$n" "$WAL/$n.apk" "$REPO/scripts/patch_eid_service.py") ;;
    *) src=$(cosw_patched "$n" "$WAL/$n.apk" "$REPO/scripts/patch_cos_wallet.py" \
                 "$REPO/patches/cos-wallet/rmx-wallet-shim.dex") ;;
  esac
  put "$src" "$d/$n.apk" 0644
  python3 -I "$REPO/scripts/apk_sigblock.py" check "$d/$n.apk"
  python3 -I - "$d/$n.apk" "$d/lib/arm64" <<'PY'
import os, sys, zipfile
apk, out = sys.argv[1:]
z = zipfile.ZipFile(apk)
libs = [i for i in z.infolist()
        if i.filename.startswith('lib/arm64-v8a/') and i.filename.endswith('.so')]
if libs and all(i.compress_type == 0 for i in libs):
    print('  %s: %d stored arm64 libs, loaded from the APK' % (os.path.basename(apk), len(libs)))
elif libs:
    os.makedirs(out, exist_ok=True)
    for i in libs:
        p = os.path.join(out, os.path.basename(i.filename))
        open(p, 'wb').write(z.read(i))
        os.chmod(p, 0o644)
    for d in (os.path.dirname(out), out):
        os.chmod(d, 0o755)
    print('  %s: %d arm64 libs extracted' % (os.path.basename(apk), len(libs)))
PY
done
# FinShell / TAS request oplus.permission.OPLUS_COMPONENT_SAFE; the NFC wallet
# bridge (system/app/XMNfcNci, below) only takes card-selection broadcasts from
# holders.  The module defined it in its own manifest.
put "$REPO/patches/cos-wallet/rmx5010-cos-wallet.xml" "$PR/etc/permissions/rmx5010-cos-wallet.xml" 0644

log "product: Mi TSM keeps out of the foreground while FinShell is the payment default"
# scripts/patch_tsmclient.py: NfcEventMonitorService's automatic RF/HCI launch
# of DoubleClickActivity is dropped, DoubleClickActivity (transit shortcut)
# opens FinShell's card package (was COS-WALLET-FIX in com.miui.tsmclient).
TA="$PR/app/MITSMClient/MITSMClient.apk"
[ -f "$W/MITSMClient.orig.apk" ] || cp "$TA" "$W/MITSMClient.orig.apk"
put "$(cosw_patched MITSMClient "$W/MITSMClient.orig.apk" "$REPO/scripts/patch_tsmclient.py" \
        "$REPO/patches/cos-wallet/rmx-tsm-bridge.dex")" "$TA" 0644
rm -rf "$PR/app/MITSMClient/oat"

log "product: touchpanel keylayout (double-tap KEY_F4 -> WAKEUP)"
# The RMX5010 HBP firmware reports one KEY_F4 per recognised double tap (the
# Xiaomi panels report KEY_WAKEUP).  Generic.kl keeps F4 a plain key, so
# HyperOS ignored it and the Sense F4 hook had to wake the device.  The input
# device is "touchpanel" with vendor id 0, so the name-based layout applies;
# keep its only other key (KEY_SLEEP) as in Generic.kl.
mkdir -p "$PR/usr/keylayout"; chmod 0755 "$PR/usr" "$PR/usr/keylayout"
printf '%s\n' '# RMX5010: the panel reports one KEY_F4 per double-tap gesture' \
  'key 62    WAKEUP' 'key 142   SLEEP' > "$T/touchpanel.kl"
put "$T/touchpanel.kl" "$PR/usr/keylayout/touchpanel.kl" 0644

log "product: camera seapp mapping (com.oplus.camera -> traceur_app, as the module)"
SEAPP="$PR/etc/selinux/product_seapp_contexts"
sed -i '/name=com.oplus.camera/d' "$SEAPP"
sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=traceur_app type=privapp_data_file levelFrom=user' "$SEAPP"

log "product: SELinux rules the module patched in at runtime"
CIL="$PR/etc/selinux/product_sepolicy.cil"
if ! grep -q '^; RMX5010 module merge' "$CIL"; then
  cat >> "$CIL" <<'EOF'
; RMX5010 module merge: rules the rmx5010_fod_bridge module patched in at boot.
; OplusCamera runs as traceur_app (see product_seapp_contexts); the offline
; camera session needs hal_camera_default -> app binder calls.
(typepermissive traceur_app)
(typepermissive hal_camera_default)
; IFAA (org.ifaa.aidl.manager, targetSdk 35 -> platform_app_36) talks to the
; Oplus IFingerprintPay HAL, which only accepts hal_fingerprintpay_client.
(typeattributeset hal_fingerprintpay_client (platform_app_36))
EOF
fi

log "product: build.prop"
BP="$PR/etc/build.prop"
set_prop "$BP" ro.colorpick_adjust true
set_prop "$BP" ro.all_modes.colorpick_adjust true
set_prop "$BP" ro.oplus.camera.defercap.support 1
set_prop "$BP" ro.oplus.camera.defercap.all.quick.visible.support 1
set_prop "$BP" ro.product.camera_maker realme
set_prop "$BP" persist.sys.display.density 560
set_prop "$BP" ro.rmx5010.image_merge 1

# ---------------------------------------------------------------- system_ext
log "system_ext: camera libs / jars / permissions, audio appname patch"
n=0
for f in "$K/system/system_ext/lib64/"*; do
  [ -e "$SE/lib64/$(basename "$f")" ] && log "  replaces stock $(basename "$f")"
  put "$f" "$SE/lib64/$(basename "$f")" 0644; n=$((n+1))
done
log "  lib64: $n files"
for f in "$K/system/system_ext/framework/"*; do put "$f" "$SE/framework/$(basename "$f")" 0644; done
for f in "$K/system/system_ext/etc/permissions/"*; do put "$f" "$SE/etc/permissions/$(basename "$f")" 0644; done
for lib in libaudiopolicymanagerimpl.so libmiaudiopolicymanager.so; do
  h=$(sha256sum "$SE/lib64/$lib" | cut -c1-16)
  if [ -f "$K/audio/$lib.$h" ]; then
    put "$K/audio/$lib.$h" "$SE/lib64/$lib" 0644; log "  $lib patched (stock $h)"
  elif sha256sum "$K/audio/$lib".* | cut -c1-64 | grep -qx "$(sha256sum "$SE/lib64/$lib" | cut -c1-64)"; then
    log "  $lib already patched"
  else
    echo "no audio patch for $lib (stock $h)" >&2; exit 1
  fi
done
set_prop "$SE/etc/build.prop" persist.sys.qseelogd false

log "system_ext: Xiaomi haptic mappings, linear motor, slider gain rc"
# 38 sys.haptic.* effect mappings from the untrimmed haotian donor odm (OS3
# docs/haptic_system_final); without them HyperOS does not treat the motor as
# linear and the Settings haptic page, slider ticks and many UI haptics stay
# silent.  sys.haptic.motor is set after boot completion, as in OS3.
# RmxHapticBridge (miui-services) publishes the Settings strength slider as
# sys.rmx5010.haptic_fifo / _direct; init (allowed to write sysfs_leds) copies
# them to the qcom-haptics gain nodes (stock 8200 / 1280 = slider maximum).
while IFS='=' read -r k v; do
  [ -n "$k" ] && set_prop "$SE/etc/build.prop" "$k" "$v"
done < "$REPO/patches/haptic/sys_haptic.prop"
cat > "$T/rmx5010_haptic.rc" <<'EOF'
# RMX5010 HyperOS port: haptics (see scripts/merge_module_into_image.sh).
on property:sys.boot_completed=1
    setprop sys.haptic.motor linear

on property:sys.rmx5010.haptic_fifo=*
    write /sys/class/qcom-haptics/vmax ${sys.rmx5010.haptic_direct}
    write /sys/class/qcom-haptics/cl_vmax ${sys.rmx5010.haptic_direct}
    write /sys/class/qcom-haptics/fifo_vmax ${sys.rmx5010.haptic_fifo}
EOF
put "$T/rmx5010_haptic.rc" "$SE/etc/init/rmx5010_haptic.rc" 0644

log "system_ext: miui-services Greeze defaults, double-tap switch property, screen colour, haptics, ColorOS wallet"
# Patch from the fingerprint-stub-only jar so a rerun does not patch twice;
# the first run saves it before touching the stage copy.  smali output is not
# byte-for-byte reproducible, so the patched jar is cached per patch-script
# version ($W/miui-services.patched.<sha>.jar), keeping system_ext stable across
# runs.  The patch also mirrors the double-tap switch into sys.rmx5010.dt2w.
J="$SE/framework/miui-services.jar"
[ -f "$W/miui-services.fp.jar" ] || cp "$J" "$W/miui-services.fp.jar"
BRIDGE_DEX="$REPO/patches/miui-services-bridges.dex"
need "$BRIDGE_DEX"
PJ="$W/miui-services.patched.$(cat "$REPO/scripts/patch_miui_services_greeze.py" "$BRIDGE_DEX" | sha256sum | cut -c1-12).jar"
if [ ! -f "$PJ" ]; then
  python3 -I "$REPO/scripts/patch_miui_services_greeze.py" "$W/miui-services.fp.jar" "$T/miui-services.jar" \
    "$BRIDGE_DEX" | grep -v '^+'
  cp "$T/miui-services.jar" "$PJ"
fi
put "$PJ" "$J" 0644

log "system_ext: Settings (haptic page, My device specs, face enrollment circle 0)"
# scripts/patch_settings.py on the stock Settings.apk (kept in
# $W/Settings.orig.apk on the first run), then zipalign and the original
# signing block spliced back; cached per patch-script version like
# miui-services.  The stale odex/vdex are removed (ART would reject them).
SA="$SE/priv-app/Settings/Settings.apk"
[ -f "$W/Settings.orig.apk" ] || cp "$SA" "$W/Settings.orig.apk"
PS="$W/Settings.patched.$(sha256sum "$REPO/scripts/patch_settings.py" | cut -c1-12).apk"
if [ ! -f "$PS" ]; then
  python3 -I "$REPO/scripts/patch_settings.py" "$W/Settings.orig.apk" "$T/Settings.zip" | grep -v '^+'
  zipalign -p -f 4 "$T/Settings.zip" "$T/Settings.aligned.zip"
  python3 -I "$REPO/scripts/apk_sigblock.py" splice "$T/Settings.aligned.zip" "$W/Settings.orig.apk" "$PS"
fi
python3 -I "$REPO/scripts/apk_sigblock.py" check "$PS"
put "$PS" "$SA" 0644
rm -rf "$SE/priv-app/Settings/oat"
[ ! -e "$SE/framework/oat/arm64/miui-services.odex" ]

# ---------------------------------------------------------------- system
log "system: ColorOS wallet NFC service bridge and SecureElement access fallback"
# XMNfcNci: scripts/patch_xm_nfc.py + patches/cos-wallet/RmxWalletNfc.java,
# the NFC-service part of COS-WALLET-FIX (eSE route 0x01 -> 0xC0, default
# wallet policy, selected-card dynamic AID, access-card RF, reader-field
# forwarding, TECH chooser).  SecureElement: scripts/patch_secure_element.py,
# privileged eSE channel for the original FinShell / TAS signers.
for a in XMNfcNci:patch_xm_nfc.py:rmx-nfc-bridge.dex \
         SecureElement:patch_secure_element.py:rmx-se-bridge.dex; do
  n=${a%%:*}; rest=${a#*:}; script=${rest%%:*}; dex=${rest#*:}
  SA="$SYS/app/$n/$n.apk"
  [ -f "$W/$n.orig.apk" ] || cp "$SA" "$W/$n.orig.apk"
  put "$(cosw_patched "$n" "$W/$n.orig.apk" "$REPO/scripts/$script" \
          "$REPO/patches/cos-wallet/$dex")" "$SA" 0644
  rm -rf "$SYS/app/$n/oat"
done

log "system: camera libs, P010 libnativewindow, cameraserver, /mi_ext links"
for f in "$K/system/lib64/"*; do put "$f" "$SYS/lib64/$(basename "$f")" 0644; done
put "$CAM/libnativewindow.so" "$SYS/lib64/libnativewindow.so" 0644
put "$CAM/cameraserver" "$SYS/bin/cameraserver" 0755
MX="$ST/system/mi_ext/product"
mkdir -p "$MX/ai" "$MX/etc" "$MX/opcust"
chmod 0755 "$ST/system/mi_ext" "$MX" "$MX/ai" "$MX/etc" "$MX/opcust"
ln -sfn /product/ai/taiyi "$MX/ai/taiyi"
ln -sfn /product/etc/cust_features "$MX/etc/cust_features"

# ---------------------------------------------------------------- odm
log "odm: copy stock image with xattrs"
for p in odm vendor; do
  mkdir -p "$M/rb_$p"; mountpoint -q "$M/rb_$p" || mount -o loop,ro "$RB/$p.img" "$M/rb_$p"
done
rm -rf "$SO" "$SV"; mkdir -p "$SO" "$SV"
cp -a "$M/rb_odm/." "$SO/"
log "odm: camera libs, camera_unit_config, WeChat fake CameraX declaration"
for f in "$CAM/odm/lib64/"*; do
  b=$(basename "$f")
  if [ -f "$SO/lib64/$b" ]; then
    put "$f" "$SO/lib64/$b" 0644
  else
    put "$f" "$SO/lib64/$b" 0644
    setfattr -n security.selinux -v u:object_r:same_process_hal_file:s0 "$SO/lib64/$b"
  fi
done
put "$CAM/etc/camera_unit_config" "$SO/etc/camera/config/camera_unit_config" 0644
# Touch report-rate: stock config + the two report-rate flags, version
# 2025070901 -> 2025070999 so touchDaemon prefers it over an older
# /data/vendor/touchconfig copy (was touch_config.sh).
put "$K/touch/sys_touch_function_feature_config.xml" \
    "$SO/firmware/tp/24600/sys_touch_function_feature_config.xml" 0644
put "$K/wechat/fake_camera_extensions.xml" "$SO/etc/permissions/fake_camera_extensions.xml" 0644

log "odm: haptic effect 192 (Settings haptic demo video)"
# Settings plays Xiaomi rtp effect 0xc0 with the billiards video.  The Oplus
# HAL plays any effect listed in vibrator_effect.json (verified 2026-11-17:
# Prebaked=192 finished, 20033 ms) and RmxHapticBridge advertises 192, so no
# HAL binary patch is needed.  effect_192.bin: haotian
# 192_HapticsVideo_RTP.bin, 48 kHz -> 24 kHz signed 8-bit (OS3
# docs/haptic_video_final).
VJ="$SO/etc/vibrator/vibrator_effect.json"
need "$VJ"
put "$REPO/patches/haptic/effect_192.bin" "$SO/etc/vibrator/809/def/effect_192.bin" 0644
setfattr -n security.selinux -v u:object_r:vendor_configs_file:s0 "$SO/etc/vibrator/809/def/effect_192.bin"
python3 -I - "$VJ" "$T/vibrator_effect.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
style = j["809"]["def_style"]
if not any(e["effect_id"] == 192 for e in style):
    style.insert(0, {"effect_file": "/odm/etc/vibrator/809/def/effect_192.bin",
                     "effect_id": 192, "play_rate_hz": 24000})
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(
    json.dumps(j, indent=3, ensure_ascii=False) + "\n")
PY
# Rewrite in place: keeps the copied security.selinux xattr.
cat "$T/vibrator_effect.json" > "$VJ"

log "odm: double tap to wake (touchDaemon-domain helper + rc)"
# HyperOS never programs the Oplus touch gesture mode, so the panel never
# reports the double tap (was service.sh `service call IOplusTouch`).  Writes
# have to go through the touch HAL (the touchHidlTest socket path `ws` is
# ignored by touchDaemon); the only vendor domain init can start that may
# find and call the HAL is touchDaemon's own, oplus_touch_daemon.  A copy of
# touchHidlTest labelled oplus_touch_daemon_exec runs there through the
# existing init -> oplus_touch_daemon type transition; no policy change.
# Verified 2026-11-17 with runcon on the device: node 1 reads back 1.
need "$SO/bin/touchHidlTest" "$SO/etc/init/init.touchDaemon.rc"
install -m 0755 -o 0 -g 2000 "$SO/bin/touchHidlTest" "$SO/bin/rmx5010_touchctl"
setfattr -n security.selinux -v u:object_r:oplus_touch_daemon_exec:s0 "$SO/bin/rmx5010_touchctl"
cat > "$T/rmx5010_touch.rc" <<'EOF'
# RMX5010 HyperOS port: double tap to wake, following the HyperOS switch
# (Settings.System gesture_wakeup).
#   node 1  double_tap_enable = 1 / 0
#   node 21 gesture_type mask = 2 (kernel gesture_type bit0, double tap)
# sys.rmx5010.dt2w mirrors the switch: miui-services TouchWakeUpFeatureManager
# .onGestureWakeupSettingsChanged sets it at boot and on every change
# (scripts/patch_miui_services_greeze.py).  touchDaemon keeps the state
# in-process and re-sends it on every suspend, so re-apply it whenever
# touchDaemon (re)starts (it sets vendor.touchdaemon.pid once it is up) and on
# every screen-off as a safety net.  The panel then reports KEY_F4, which
# /product/usr/keylayout/touchpanel.kl maps to WAKEUP.
service rmx5010_dt2w_type /odm/bin/rmx5010_touchctl -c wo 0 21 2
    user root
    group root system input
    disabled
    oneshot

service rmx5010_dt2w_on /odm/bin/rmx5010_touchctl -c wo 0 1 1
    user root
    group root system input
    disabled
    oneshot

service rmx5010_dt2w_off /odm/bin/rmx5010_touchctl -c wo 0 1 0
    user root
    group root system input
    disabled
    oneshot

# Both writes from the same action: a chained
# "on property:init.svc.rmx5010_dt2w_type=stopped" trigger never fired on the
# device (2026-11-17), and touchDaemon accepts the two nodes in either order.
on property:sys.rmx5010.dt2w=1 && property:vendor.touchdaemon.pid=*
    start rmx5010_dt2w_type
    start rmx5010_dt2w_on

on property:sys.rmx5010.dt2w=1 && property:debug.tracing.screen_state=1
    start rmx5010_dt2w_type
    start rmx5010_dt2w_on

on property:sys.rmx5010.dt2w=0 && property:vendor.touchdaemon.pid=*
    start rmx5010_dt2w_off
EOF
put "$T/rmx5010_touch.rc" "$SO/etc/init/rmx5010_touch.rc" 0644
setfattr -n security.selinux \
  -v "$(getfattr --only-values -n security.selinux "$SO/etc/init/init.touchDaemon.rc" | tr -d '\0')" \
  "$SO/etc/init/rmx5010_touch.rc"

# ---------------------------------------------------------------- vendor
log "vendor: copy stock image with xattrs"
cp -a "$M/rb_vendor/." "$SV/"
log "vendor: QESDK seccomp lseek, SF touch timer, kernel modules + rc"
for p in qesdksec.policy qsap_qapeservice.policy syshealthmon.policy; do
  f="$SV/etc/seccomp_policy/$p"; need "$f"
  grep -q '^lseek:' "$f" || printf '\nlseek: 1\n' >> "$f"
done
grep -q '^ro.surface_flinger.set_touch_timer_ms=' "$SV/build.prop"
# Rewrite in place: sed -i would replace the inode and drop the copied
# security.selinux xattr (odm / vendor get no file_contexts pass).
sed 's/^ro\.surface_flinger\.set_touch_timer_ms=.*/ro.surface_flinger.set_touch_timer_ms=2000/' \
  "$SV/build.prop" > "$T/vendor_build.prop"
cat "$T/vendor_build.prop" > "$SV/build.prop"
KO="$SV/lib64/rmx5010_modules"
mkdir -p "$KO"; chmod 0755 "$KO"
setfattr -n security.selinux -v u:object_r:vendor_file:s0 "$KO"
for m in millet_core binder_gki millet_pkg millet_hs millet_binder millet_sig millet_oem_cgroup; do
  put "$K/millet/$m.ko" "$KO/$m.ko" 0644
done
put "$K/rmx5010_fod_bridge.ko" "$KO/rmx5010_fod_bridge.ko" 0644
for f in "$KO"/*.ko; do setfattr -n security.selinux -v u:object_r:vendor_file:s0 "$f"; done
RC="$SV/etc/init/rmx5010_drivers.rc"
cat > "$T/rmx5010_drivers.rc" <<'EOF'
# RMX5010 HyperOS port: kernel modules the rmx5010_fod_bridge KSU module used
# to insmod (vendor_init may load vendor_file modules, as rmx5010_ltpo.rc does).

# Xiaomi millet (Greeze thaw on packet / binder / signal): before system_server
# and millet_monitor.  Dependency order from the donor modules.dep.
on post-fs-data
    insmod /vendor/lib64/rmx5010_modules/millet_core.ko
    insmod /vendor/lib64/rmx5010_modules/binder_gki.ko
    insmod /vendor/lib64/rmx5010_modules/millet_pkg.ko
    insmod /vendor/lib64/rmx5010_modules/millet_hs.ko
    insmod /vendor/lib64/rmx5010_modules/millet_binder.ko
    insmod /vendor/lib64/rmx5010_modules/millet_sig.ko
    insmod /vendor/lib64/rmx5010_modules/millet_oem_cgroup.ko

# FOD touch bridge: after the Oplus touch stack (vendor_dlkm, loaded in the
# background by vendor.modprobe) is in.
on property:vendor.all.modules.ready=1
    insmod /vendor/lib64/rmx5010_modules/rmx5010_fod_bridge.ko
EOF
put "$T/rmx5010_drivers.rc" "$RC" 0644
setfattr -n security.selinux -v u:object_r:vendor_configs_file:s0 "$RC"

# ---------------------------------------------------------------- images
log "mkfs + fsck"
cat "$SYS/etc/selinux/plat_file_contexts" "$SE/etc/selinux/system_ext_file_contexts" \
    "$PR/etc/selinux/product_file_contexts" > "$ST/all_file_contexts"
for p in system system_ext product odm vendor; do
  # Parameters per docs/SELinux闭包与EROFS重建规范.md §5.  odm / vendor take
  # their labels from the copied xattrs, so no file_contexts pass there.
  case $p in
    system)     src="$ST/system";     args=(-zlz4hc --mount-point=/ --file-contexts="$ST/all_file_contexts") ;;
    system_ext) src="$ST/system_ext"; args=(-zlz4hc --mount-point=/system_ext --file-contexts="$ST/all_file_contexts") ;;
    product)    src="$ST/product";    args=(-zlz4hc --mount-point=/product --file-contexts="$ST/all_file_contexts") ;;
    odm)        src="$SO";            args=(-zlz4 -C262144 --mount-point=/odm) ;;
    vendor)     src="$SV";            args=(-zlz4 -C262144 --mount-point=/vendor) ;;
  esac
  rm -f "$OUT/$p.raw.img"
  mkfs.erofs --quiet -b4096 -T0 "${args[@]}" "$OUT/$p.raw.img" "$src"
  fsck.erofs "$OUT/$p.raw.img" >/dev/null
  log "  $p OK $(stat -c%s "$OUT/$p.raw.img") $(sha256sum "$OUT/$p.raw.img" | cut -c1-16)"
done
log "done — verify odm/vendor metadata against the stock images before shipping"
