#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/rom/os4"
WORK="$ROOT/work_camera_product"
BASE_STAGE="$ROOT/work_fdnotz/product_stage_refresh"
STAGE="$WORK/stage"
RAW="$WORK/product.raw.img"
PAD="$WORK/product.pad.img"
SPARSE="$WORK/product.img"
VERIFY="$WORK/product.verify.raw.img"
BASE_CTX="$ROOT/work_fdnotz/product_mkfs_contexts_restore"
FINAL_CTX="$WORK/clean_product_contexts"
OUT_RAW=1262930      # 1262930 * 4096 = 5172961280 bytes
BLK=4096

echo "[1/8] Setting up fresh stage..."
rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$BASE_STAGE" "$STAGE"
echo "Stage copied from product_stage_refresh."

echo "[2/8] Replacing MiuiCamera with OplusCamera and MiuiCameraProvider stub..."
rm -rf "$STAGE/priv-app/MiuiCamera"
mkdir -p "$STAGE/priv-app/OplusCamera" "$STAGE/priv-app/MiuiCameraProvider"
cp -f /mnt/e/code/modify/os4/camera_patch/OplusCamera_fullsave_pagealigned.apk "$STAGE/priv-app/OplusCamera/OplusCamera.apk"
chmod 644 "$STAGE/priv-app/OplusCamera/OplusCamera.apk"
chown 0:0 "$STAGE/priv-app/OplusCamera/OplusCamera.apk" 2>/dev/null || true

cp -f /mnt/e/code/modify/os4/camera_patch/MiuiCameraProviderStub_signed_aligned_v3.apk "$STAGE/priv-app/MiuiCameraProvider/MiuiCameraProvider.apk"
chmod 644 "$STAGE/priv-app/MiuiCameraProvider/MiuiCameraProvider.apk"
chown 0:0 "$STAGE/priv-app/MiuiCameraProvider/MiuiCameraProvider.apk" 2>/dev/null || true

echo "[3/8] Installing OplusCamera permission and whitelist XMLs..."
mkdir -p "$STAGE/etc/permissions" "$STAGE/etc/default-permissions" "$STAGE/etc/sysconfig"
cp -f /home/ubuntu/rom/os3_product_extract/etc/permissions/privapp-permissions-com.oplus.camera.xml "$STAGE/etc/permissions/"
cp -f /home/ubuntu/rom/os3_product_extract/etc/default-permissions/default-permissions-com.oplus.camera.xml "$STAGE/etc/default-permissions/"
cp -f /home/ubuntu/rom/os3_product_extract/etc/sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml "$STAGE/etc/sysconfig/"
chmod 644 "$STAGE/etc/permissions/privapp-permissions-com.oplus.camera.xml" \
          "$STAGE/etc/default-permissions/default-permissions-com.oplus.camera.xml" \
          "$STAGE/etc/sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml"
chown 0:0 "$STAGE/etc/permissions/privapp-permissions-com.oplus.camera.xml" \
          "$STAGE/etc/default-permissions/default-permissions-com.oplus.camera.xml" \
          "$STAGE/etc/sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml" 2>/dev/null || true

echo "[4/8] Installing missing camera native libraries into product/lib64..."
mkdir -p "$STAGE/lib64"
cp -n /home/ubuntu/rom/os3_product_extract/lib64/*.so "$STAGE/lib64/" 2>/dev/null || true
chmod 644 "$STAGE/lib64"/*.so
chown 0:0 "$STAGE/lib64"/*.so 2>/dev/null || true

echo "[5/8] Injecting OplusCamera properties and SELinux configurations..."
# build.prop
if ! grep -q '^ro.oplus.camera.defercap.support=' "$STAGE/etc/build.prop"; then
  cat >> "$STAGE/etc/build.prop" << 'PROPS'
ro.oplus.camera.defercap.support=1
ro.oplus.camera.defercap.all.quick.visible.support=1
PROPS
fi

# product_property_contexts
if ! grep -q 'ro.oplus.camera.defercap.support' "$STAGE/etc/selinux/product_property_contexts"; then
  echo 'ro.oplus.camera.defercap.support u:object_r:exported_default_prop:s0 exact int' >> "$STAGE/etc/selinux/product_property_contexts"
fi

# product_seapp_contexts
if ! grep -q 'name=com.oplus.camera' "$STAGE/etc/selinux/product_seapp_contexts"; then
  sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=opluscamera_app type=privapp_data_file levelFrom=user' "$STAGE/etc/selinux/product_seapp_contexts"
fi

# product_sepolicy.cil
if ! grep -q 'opluscamera_app' "$STAGE/etc/selinux/product_sepolicy.cil"; then
  cat >> "$STAGE/etc/selinux/product_sepolicy.cil" << 'CIL'

;; RMX5010 OplusCamera dedicated domain and retained HAL/data access.
(typeattributeset domain (opluscamera_app))
(typeattributeset appdomain (opluscamera_app))
(typeattributeset priv_app_all (opluscamera_app))
(typeattributeset opluscamera_app_202404 (opluscamera_app))
(typetransition opluscamera_app tmpfs file appdomain_tmpfs)
(allow opluscamera_app appdomain_tmpfs (file (read write getattr map execute)))
(allow opluscamera_app appdomain (memfd_file (read write getattr map execute)))
(typeattributeset halclientdomain (opluscamera_app))
(typeattributeset hal_camera_client (opluscamera_app))
(typeattributeset hal_graphics_allocator_client (opluscamera_app))
(allow opluscamera_app vendor_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
(allow opluscamera_app vendor_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
(allow opluscamera_app app_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
(allow opluscamera_app app_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
(allow opluscamera_app privapp_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
(allow opluscamera_app privapp_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
(allow opluscamera_app privapp_data_file (lnk_file (read getattr open)))
CIL
fi

echo "[6/8] Generating clean product file contexts..."
python3 - "$BASE_CTX" "$STAGE" "$FINAL_CTX" << 'PY'
import sys, os, re
base_ctx, stage, out_ctx = sys.argv[1:4]

# Read existing contexts
known = {}
for line in open(base_ctx, encoding="utf-8"):
    parts = line.strip().split()
    if not parts: continue
    pattern, label = parts[0], parts[1]
    clean_path = pattern.replace(r"\.", ".").replace(r"\-", "-").replace(r"\_", "_").replace(r"\+", "+")
    known[clean_path] = (pattern, label)

# Scan actual files in stage
new_entries = []
for root, dirs, files in os.walk(stage):
    for name in dirs + files:
        full_path = os.path.join(root, name)
        rel = os.path.relpath(full_path, stage).replace("\\", "/")
        product_path = "/product/" + rel
        if product_path in known:
            new_entries.append(f"{known[product_path][0]} {known[product_path][1]}\n")
        else:
            # New file / directory, assign system_file:s0 unless specific
            escaped = re.escape(product_path)
            new_entries.append(f"{escaped} u:object_r:system_file:s0\n")

# Root /product
if "/product" in known:
    new_entries.append(f"{known['/product'][0]} {known['/product'][1]}\n")
else:
    new_entries.append("/product u:object_r:system_file:s0\n")

new_entries.sort()
open(out_ctx, "w", encoding="utf-8").write("".join(new_entries))
print(f"Generated clean product contexts with {len(new_entries)} entries.")
PY

echo "[6b/8] Normalizing timestamps and bumping APK mtime..."
find "$STAGE" -exec touch -h -d @0 {} + 2>/dev/null || true
touch "$STAGE/priv-app/OplusCamera/OplusCamera.apk"

echo "[7/8] Packaging raw EROFS product image..."
mkfs.erofs -zlz4hc -C262144 -b4096 --mount-point=/product \
  --file-contexts="$FINAL_CTX" \
  "$RAW" "$STAGE"

TARGET=$((OUT_RAW * BLK))
SZ=$(stat -c%s "$RAW")
echo "Raw size: $SZ bytes, Target size: $TARGET bytes"
if [ "$SZ" -gt "$TARGET" ]; then
  echo "ERROR: raw product ($SZ) exceeds target ($TARGET)" >&2
  exit 1
fi
cp "$RAW" "$PAD"
truncate -s "$TARGET" "$PAD"

echo "[8/8] Verifying image and converting to sparse..."
fsck.erofs "$PAD" > "$WORK/fsck_pad.log" 2>&1
echo "fsck pad OK"

img2simg "$PAD" "$SPARSE" "$BLK"
simg2img "$SPARSE" "$VERIFY"
fsck.erofs "$VERIFY" > "$WORK/fsck_roundtrip.log" 2>&1
rm -f "$VERIFY"
echo "Roundtrip verification OK"

sha256sum "$SPARSE" > "$WORK/product_sha256.txt"
cat "$WORK/product_sha256.txt"
echo "CAMERA_PRODUCT_BUILD_SUCCESS"
