#!/usr/bin/env bash
# 用已刷 system_ext.img 作底，替换补丁版 Settings.apk，重建 system_ext.img
# 用法：
#   SRC_IMG=/path/system_ext.img PATCHED_APK=/path/Settings.patched.apk \
#   CTX=/root/haotian/stage_h19/all_file_contexts OUT_IMG=/path/system_ext_facefix.img \
#   ./build_system_ext_settings_patch.sh
set -euo pipefail

SRC_IMG="${SRC_IMG:?SRC_IMG required}"
PATCHED="${PATCHED_APK:?PATCHED_APK required}"
CTX="${CTX:?CTX required}"
OUT_IMG="${OUT_IMG:?OUT_IMG required}"
W="${WORK:-/root/system_ext_patch}"

rm -rf "$W"; mkdir -p "$W/stage" "$W/mnt" "$W/verify"

echo "== [1] 展开已刷镜像 =="
magic=$(python3 -c "print(open('$SRC_IMG','rb').read(4).hex())")
if [ "$magic" = "3aff26ed" ]; then
  simg2img "$SRC_IMG" "$W/base.raw.img"
else
  cp "$SRC_IMG" "$W/base.raw.img"
fi
mount -o loop,ro "$W/base.raw.img" "$W/mnt"
cp -a "$W/mnt/." "$W/stage/"
umount "$W/mnt"

echo "== [2] 替换 Settings.apk 并删除旧 oat =="
APK="$W/stage/priv-app/Settings/Settings.apk"
echo "  before: $(sha256sum "$APK" | cut -d' ' -f1)"
cp "$PATCHED" "$APK"
chown 0:0 "$APK"; chmod 0644 "$APK"; touch -d '1970-01-01 00:00:00' "$APK"
echo "  after : $(sha256sum "$APK" | cut -d' ' -f1)"
rm -rf "$W/stage/priv-app/Settings/oat"

echo "== [3] 重建 system_ext =="
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/system_ext \
  --file-contexts="$CTX" "$W/new.raw.img" "$W/stage" >/dev/null 2>&1
fsck.erofs "$W/new.raw.img" >/dev/null && echo "  fsck OK"
img2simg "$W/new.raw.img" "$OUT_IMG" 4096
sha256sum "$OUT_IMG"

echo "== [4] 验证 =="
mount -o loop,ro "$W/new.raw.img" "$W/verify"
getfattr -h -n security.selinux --only-values "$W/verify/priv-app/Settings/Settings.apk"; echo
sha256sum "$W/verify/priv-app/Settings/Settings.apk"
[ -d "$W/verify/priv-app/Settings/oat" ] && echo "  !! oat still present" || echo "  oat removed OK"
umount "$W/verify"
echo SYSTEM_EXT_SETTINGS_PATCH_DONE
