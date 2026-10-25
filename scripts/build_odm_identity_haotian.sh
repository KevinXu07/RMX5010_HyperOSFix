#!/usr/bin/env bash
set -euo pipefail
W=/root/odm_identity_fix
IMG_E=/mnt/e/code/modify/haotian_port_h19/account_fix/odm.img
STAGE=$W/odm_stage

echo '=== [1] contexts: verbatim labels incl. symlink-inode xattrs (no-follow) ==='
MO=/tmp/odm_old_mnt
umount "$MO" 2>/dev/null || true
mkdir -p "$MO"
mount -o loop,ro "$W/odm_old.raw.img" "$MO"
python3 - "$W" <<'PY'
import os, re, sys
old_m, W = "/tmp/odm_old_mnt", sys.argv[1]
entries = []
for dp, dn, fn in os.walk(old_m):
    for name in list(dn) + list(fn):
        p = os.path.join(dp, name)
        rel = os.path.relpath(p, old_m).replace(os.sep, '/')
        try:
            lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
        except OSError:
            continue
        entries.append(re.escape('/odm/' + rel) + ' ' + lbl + '\n')
entries.append('/odm u:object_r:vendor_file:s0\n')
entries.sort()
open(W + "/odm_mkfs_contexts", 'w', encoding='utf-8').write(''.join(entries))
print("  entries:", len(entries))
assert len(entries) > 2500
PY
umount "$MO"

echo '=== [2] stage: full haotian identity ==='
sed -i \
  -e 's|^ro\.product\.model=25128PNA1G$|ro.product.model=2410DPN6CC|' \
  -e 's|^ro\.product\.odm\.model=25128PNA1G$|ro.product.odm.model=2410DPN6CC|' \
  -e 's|^ro\.product\.device=nezha$|ro.product.device=haotian|' \
  -e 's|^ro\.product\.odm\.device=nezha$|ro.product.odm.device=haotian|' \
  -e 's|^ro\.product\.name=nezha$|ro.product.name=haotian|' \
  -e 's|^ro\.product\.odm\.name=nezha$|ro.product.odm.name=haotian|' \
  -e 's|^ro\.product\.marketname=Realme GT7 Pro$|ro.product.marketname=Xiaomi 15 Pro|' \
  -e 's|^ro\.product\.odm\.marketname=Realme GT7 Pro$|ro.product.odm.marketname=Xiaomi 15 Pro|' \
  "$STAGE/etc/build.prop"
n=$(grep -c "25128PNA1G\|nezha\|Realme" "$STAGE/etc/build.prop" || true)
[ "$n" = "0" ] || { echo "FAIL refs remain"; exit 3; }

echo '=== [3] mkfs ==='
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm \
  --file-contexts="$W/odm_mkfs_contexts" "$W/odm_fixed.raw.img" "$STAGE" >/dev/null 2>&1
fsck.erofs "$W/odm_fixed.raw.img" >/dev/null && echo "  fsck OK"

echo '=== [4] verify: symlink inode must carry xattrs now ==='
M=/tmp/odm_verify_mnt
umount "$M" 2>/dev/null || true
mkdir -p "$M"
mount -o loop,ro "$W/odm_fixed.raw.img" "$M"
lab() { getfattr -h -n security.selinux --only-values "$1" 2>/dev/null | tr -d '\n\0' || true; }
printf '  dangling symlink [%s]\n' "$(lab "$M/etc/vintf/manifest/network_manifest.xml")"
printf '  /bin/mtd         [%s]\n' "$(lab "$M/bin/mtd")"
python3 - <<'PY'
import os
m = "/tmp/odm_verify_mnt"
dirs = labs = files = flabs = sl = 0
for dp, dn, fn in os.walk(m):
    dirs += 1
    try: os.getxattr(dp, 'security.selinux'); labs += 1
    except OSError: pass
    for f in fn:
        p = os.path.join(dp, f)
        files += 1
        try:
            os.getxattr(p, 'security.selinux', follow_symlinks=False); flabs += 1
        except OSError: pass
print(f"  dirs={dirs} labeled={labs} | files={files} labeled={flabs} (symlinks counted no-follow)")
PY
umount "$M"

echo '=== [5] sparse + replace + hash ==='
img2simg "$W/odm_fixed.raw.img" "$W/odm_fixed.img" 4096
cp -f "$W/odm_fixed.img" "$IMG_E"
{
  sha256sum "$IMG_E"
  sha256sum /mnt/e/code/modify/haotian_port_h19/account_fix/vendor.img
} > /mnt/e/code/modify/haotian_port_h19/account_fix/sha256_images.txt
cat /mnt/e/code/modify/haotian_port_h19/account_fix/sha256_images.txt
echo ODMM_SYMLINK_FIXED
