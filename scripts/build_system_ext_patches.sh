#!/usr/bin/env bash
# 在已刷 system_ext.img 上叠加两个小米组件补丁并重建：
#   1) Settings.apk 人脸录入动画死锁修复（可选）
#   2) miui-services.jar 指纹硬件检测桩修复（设置指纹入口）
# 用法：
#   SRC_IMG=... SYSTEM_EXT_CTX=... OUT_IMG=... \
#   [SETTINGS_APK=...] [MIUI_SERVICES_JAR=...] ./build_system_ext_patches.sh
set -euo pipefail
SRC_IMG="${SRC_IMG:?SRC_IMG required}"
CTX="${SYSTEM_EXT_CTX:?SYSTEM_EXT_CTX required}"
OUT_IMG="${OUT_IMG:?OUT_IMG required}"
SETTINGS_APK="${SETTINGS_APK:-}"
MIUI_SERVICES_JAR="${MIUI_SERVICES_JAR:-}"
W="${WORK:-/root/system_ext_patches}"

rm -rf "$W"; mkdir -p "$W/stage" "$W/mnt" "$W/verify"
if [ "$(python3 -c "print(open('$SRC_IMG','rb').read(4).hex())")" = "3aff26ed" ]; then
  simg2img "$SRC_IMG" "$W/base.raw.img"
else
  cp "$SRC_IMG" "$W/base.raw.img"
fi
mount -o loop,ro "$W/base.raw.img" "$W/mnt"
cp -a "$W/mnt/." "$W/stage/"
umount "$W/mnt"

if [ -n "$SETTINGS_APK" ]; then
  echo "== Settings.apk =="
  A="$W/stage/priv-app/Settings/Settings.apk"
  echo "  before $(sha256sum "$A" | cut -d' ' -f1)"
  cp "$SETTINGS_APK" "$A"
  chown 0:0 "$A"; chmod 0644 "$A"; touch -d '1970-01-01 00:00:00' "$A"
  rm -rf "$W/stage/priv-app/Settings/oat"
  echo "  after  $(sha256sum "$A" | cut -d' ' -f1)  (oat removed)"
fi

if [ -n "$MIUI_SERVICES_JAR" ]; then
  echo "== miui-services.jar =="
  J="$W/stage/framework/miui-services.jar"
  echo "  before $(sha256sum "$J" | cut -d' ' -f1)"
  cp "$MIUI_SERVICES_JAR" "$J"
  chown 0:0 "$J"; chmod 0644 "$J"; touch -d '1970-01-01 00:00:00' "$J"
  rm -f "$W/stage/framework/oat/arm64/miui-services."{odex,vdex,art}
  rm -f "$W/stage/framework/oat/arm64/miui-services."*.fsv_meta
  rm -f "$W/stage/framework/miui-services.jar.fsv_meta"
  echo "  after  $(sha256sum "$J" | cut -d' ' -f1)  (oat/fsv_meta removed)"
fi

mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/system_ext \
  --file-contexts="$CTX" "$W/new.raw.img" "$W/stage" >/dev/null 2>&1
fsck.erofs "$W/new.raw.img" >/dev/null && echo "  fsck OK"
img2simg "$W/new.raw.img" "$OUT_IMG" 4096
sha256sum "$OUT_IMG"

mount -o loop,ro "$W/new.raw.img" "$W/verify"
getfattr -h -n security.selinux --only-values "$W/verify/priv-app/Settings/Settings.apk"; echo
getfattr -h -n security.selinux --only-values "$W/verify/framework/miui-services.jar"; echo
umount "$W/verify"
echo SYSTEM_EXT_PATCHES_DONE
