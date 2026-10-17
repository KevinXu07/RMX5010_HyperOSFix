#!/usr/bin/env bash
set -euo pipefail

STAGE="/home/ubuntu/rom/os4/work_camera_odm/stage"
WORK="/home/ubuntu/rom/os4/work_camera_odm"
CONFIG_SRC="/mnt/e/code/modify/os4/camera_patch/camera_unit_config"
FINAL_CTX="$WORK/clean_odm_contexts"
RAW="$WORK/odm.raw.img"
SPARSE="$WORK/odm.img"

echo "[1/5] Injecting 14-way camera_unit_config..."
test -f "$CONFIG_SRC"
test -d "$STAGE/etc/camera/config"
cp -f "$CONFIG_SRC" "$STAGE/etc/camera/config/camera_unit_config"
chmod 644 "$STAGE/etc/camera/config/camera_unit_config"
GOT_HASH=$(sha256sum "$STAGE/etc/camera/config/camera_unit_config" | cut -d' ' -f1)
test "$GOT_HASH" = "c2fc5ae64eea41016b50cb46f0a0d4e7172f99785b03e57911100acc0b1c23c1"
echo "camera_unit_config hash verified: $GOT_HASH"

echo "[2/5] Verifying fake camera extension jar and declaration removed..."
rm -f "$STAGE/framework/androidx.camera.extensions.impl.fake.jar"
rm -f "$STAGE/etc/permissions/fake_camera_extensions.xml"
test ! -e "$STAGE/framework/androidx.camera.extensions.impl.fake.jar"
test ! -e "$STAGE/etc/permissions/fake_camera_extensions.xml"
echo "fake jar confirmed absent"

echo "[3/5] Regenerating clean file_contexts (2738 entries)..."
python3 /mnt/e/code/modify/os4/tools/gen_odm_contexts.py

echo "[4/5] Building raw EROFS odm image with exact file contexts..."
rm -f "$RAW" "$SPARSE"
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm --file-contexts="$FINAL_CTX" "$RAW" "$STAGE"

echo "[5/5] Verifying raw image with fsck.erofs..."
fsck.erofs "$RAW" > "$WORK/fsck_raw.log" 2>&1
echo "fsck raw OK"

img2simg "$RAW" "$SPARSE"
simg2img "$SPARSE" "$WORK/odm.verify.raw.img"
fsck.erofs "$WORK/odm.verify.raw.img" > "$WORK/fsck_roundtrip.log" 2>&1
rm -f "$WORK/odm.verify.raw.img"
echo "Roundtrip fsck OK"

sha256sum "$SPARSE" > "$WORK/odm_sha256.txt"
cat "$WORK/odm_sha256.txt"
echo "CLEAN_ODM_14WAY_SUCCESS"
