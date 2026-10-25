#!/usr/bin/env bash
# haotian OS4.0.0.19 RMX5010 boot set — v3 recipe ported to 0.19, minimal-change boot build.
# Donor user space: system/system_ext/product (+mi_ext merged, pangu merged).
# Hardware base: whatever is already flashed on the device (boot/vendor/odm/vbmeta untouched).
set -euo pipefail

ROOT=/root/haotian
MOUNT="$ROOT/mounts"
STAGE="$ROOT/stage_h19"
OUT=/mnt/e/code/modify/haotian_port_h19

echo '[0/7] mount donor partitions'
for p in system system_ext product mi_ext mi_product; do
  m="$MOUNT/donor_$p"
  mkdir -p "$m"
  mountpoint -q "$m" || mount -o loop,ro "$ROOT/images/$p.img" "$m"
done
mount | grep "$MOUNT/donor_" || true
test -d "$MOUNT/donor_system/system" || { echo 'donor mounts are not active' >&2; exit 2; }

echo '-- mi_product tree (0.19 new partition, inspection only):'
find "$MOUNT/donor_mi_product" -maxdepth 3 | head -30 || true

rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT/images" "$OUT/metadata" "$OUT/logs"

echo '[1/6] copy donor partition roots with xattrs'
cp -a "$MOUNT/donor_system/." "$STAGE/system/"
cp -a "$MOUNT/donor_system_ext/." "$STAGE/system_ext/"
cp -a "$MOUNT/donor_product/." "$STAGE/product/"

echo '[2/6] merge mi_ext payloads into system-as-root'
mkdir -p "$STAGE/system/system" "$STAGE/system_ext" "$STAGE/product"
cp -a "$MOUNT/donor_mi_ext/system/." "$STAGE/system/system/"
cp -a "$MOUNT/donor_mi_ext/system_ext/." "$STAGE/system_ext/"
cp -a "$MOUNT/donor_mi_ext/product/." "$STAGE/product/"
test -d "$MOUNT/donor_product/pangu/system" && \
  cp -a "$MOUNT/donor_product/pangu/system/." "$STAGE/system/system/"
rm -rf "$STAGE/product/pangu"

echo '[3/6] remove incompatible duplicate NFC payloads / updater'
rm -rf "$STAGE/system/system/app/Nfc_st" "$STAGE/system/system/app/nfc_st" \
       "$STAGE/product/app/Nfc_st" "$STAGE/product/app/nfc_st"
rm -rf "$STAGE/product/app/Updater"

echo '[4/6] merge mi_ext properties without replacing donor OS4 properties'
python3 - "$STAGE/product/etc/build.prop" "$MOUNT/donor_mi_ext/etc/build.prop" <<'PY'
import sys
dst, src = sys.argv[1:]
lines = open(dst, encoding='utf-8', errors='replace').read().splitlines()
keys = {x.split('=',1)[0] for x in lines if '=' in x and not x.lstrip().startswith('#')}
extra=[]
for line in open(src, encoding='utf-8', errors='replace').read().splitlines():
    if not line or line.lstrip().startswith('#') or '=' not in line: continue
    k=line.split('=',1)[0]
    if k not in keys:
        extra.append(line); keys.add(k)
if extra:
    lines += ['', '# merged from mi_ext/build.prop (OS4 RMX5010 port h19)', *extra]
open(dst, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines)+'\n')
PY
# mi_ext init overlay targets a separate /mnt/vendor/mi_ext mount; user-space already merged.
rm -f "$STAGE/system/system/etc/init/init.miui.mi_ext.rc" \
      "$STAGE/system/system/etc/build.prop" "$STAGE/system/system/etc/NOTICE.xml.gz"

echo '[5/6] build EROFS with combined contexts'
cat "$STAGE/system/system/etc/selinux/plat_file_contexts" \
    "$STAGE/system_ext/etc/selinux/system_ext_file_contexts" \
    "$STAGE/product/etc/selinux/product_file_contexts" > "$STAGE/all_file_contexts"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/ \
  --file-contexts="$STAGE/all_file_contexts" "$OUT/images/system.raw.img" "$STAGE/system" > "$OUT/logs/mkfs_system.log" 2>&1
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/system_ext \
  --file-contexts="$STAGE/all_file_contexts" "$OUT/images/system_ext.raw.img" "$STAGE/system_ext" > "$OUT/logs/mkfs_system_ext.log" 2>&1
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/product \
  --file-contexts="$STAGE/all_file_contexts" "$OUT/images/product.raw.img" "$STAGE/product" > "$OUT/logs/mkfs_product.log" 2>&1

echo '[6/6] verify, sparse-convert, hash'
for p in system system_ext product; do
  fsck.erofs "$OUT/images/$p.raw.img" > "$OUT/logs/fsck_$p.log" 2>&1
  img2simg "$OUT/images/$p.raw.img" "$OUT/images/$p.img"
  rm -f "$OUT/images/$p.raw.img"
done
sha256sum "$OUT/images"/*.img > "$OUT/metadata/sha256_images.txt"
du -sh "$OUT/images" "$STAGE" | tee "$OUT/metadata/size.txt"

cat > "$OUT/metadata/provenance.txt" <<'EOF'
haotian h19 RMX5010 boot set (minimal-change boot build)
donor: Xiaomi 15 Pro haotian OS4.0.0.19.XOBCNXM, payload sha256-prefix 7635b407031d2c57
user space: donor system/system_ext/product; donor mi_ext system/system_ext/product merged;
            donor product/pangu/system merged into system
hardware base: already-flashed device partitions (boot/vendor/odm/vbmeta/firmware untouched)
removed: donor Nfc_st duplicates, product Updater, mi_ext mount init overlay
flash: fastbootd, active slot only, system_a/b + system_ext_a/b + product_a/b as needed
EOF
echo H19_BOOT_SET_DONE
