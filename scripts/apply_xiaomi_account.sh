#!/usr/bin/env bash
# apply_xiaomi_account.sh — inject the Xiaomi account (MTD) HAL closure into an
# RMX5010 odm+vendor baseline and rebuild both EROFS images.
#
#   apply_xiaomi_account.sh --odm <baseline odm mount> --vendor <baseline vendor mount> \
#                           --patch <patches/xiaomi-account> --out <outdir>
#
# Optional:
#   --lz4-level   erofs compressor (default -zlz4)
#   --pcluster    big pcluster size (default 262144, matches RMX5010 stock)
#   --skip-cil    do not append the SELinux policy blocks (labels only)
#
# What it does, in order:
#   1. stage  = copy of the baseline tree (xattrs/mode/owner preserved)
#   2. inject payload files (existing paths are SKIPPED, never overwritten)
#   3. create  /odm/etc/selinux/odm_file_contexts
#   4. append   vendor_service_contexts / vendor_property_contexts / vendor_file_contexts
#   5. append   the misys/hypsys + mtd CIL blocks to vendor_sepolicy.cil (+debug)
#   6. add      the blackbox VINTF manifest (missing from the upstream archive)
#   7. strip    security.selinux from the stage (keep security.capability!)  -> §4.1 of the spec
#   8. build    100%-coverage --file-contexts from baseline labels + labels.tsv
#   9. mkfs.erofs -> fsck.erofs -> img2simg  (odm and vendor)
#
# Exit non-zero on any failure. Output: <out>/odm.img, <out>/vendor.img, <out>/build_report.txt
set -euo pipefail

ODM_MNT=""; VEN_MNT=""; PATCH=""; OUT=""; ZFLAG="-zlz4"; PCLUSTER=262144; DO_CIL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --odm) ODM_MNT=$2; shift 2;;
    --vendor) VEN_MNT=$2; shift 2;;
    --patch) PATCH=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --lz4-level) ZFLAG="-$2"; shift 2;;
    --pcluster) PCLUSTER=$2; shift 2;;
    --skip-cil) DO_CIL=0; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$ODM_MNT" ] && [ -n "$VEN_MNT" ] && [ -n "$PATCH" ] && [ -n "$OUT" ] || {
  echo "usage: $0 --odm <mnt> --vendor <mnt> --patch <dir> --out <dir>" >&2; exit 2; }

mountpoint -q "$ODM_MNT"  || { echo "odm baseline not mounted: $ODM_MNT" >&2; exit 2; }
mountpoint -q "$VEN_MNT"  || { echo "vendor baseline not mounted: $VEN_MNT" >&2; exit 2; }
[ -f "$PATCH/labels.tsv" ] || { echo "labels.tsv not found under $PATCH" >&2; exit 2; }
for t in mkfs.erofs fsck.erofs img2simg python3; do
  command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 2; }
done

mkdir -p "$OUT/logs"
STAGE="$OUT/stage"
REPORT="$OUT/build_report.txt"
: > "$REPORT"
say() { echo "$@" | tee -a "$REPORT"; }

say "== apply_xiaomi_account =="
say "baseline odm   : $ODM_MNT"
say "baseline vendor: $VEN_MNT"
say "patch          : $PATCH"
say "output         : $OUT"
say ""

say "[1/9] staging baseline trees"
rm -rf "$STAGE"; mkdir -p "$STAGE/odm" "$STAGE/vendor"
cp -a "$ODM_MNT/." "$STAGE/odm/"
cp -a "$VEN_MNT/." "$STAGE/vendor/"
say "  odm entries=$(find "$STAGE/odm" | wc -l)  vendor entries=$(find "$STAGE/vendor" | wc -l)"

say "[2/9] injecting payload (skip existing)"
python3 - "$PATCH" "$STAGE" "$REPORT" <<'PY'
import os, shutil, sys
patch, stage, report = sys.argv[1:4]
added, skipped, missing = [], [], []
rows = []
for line in open(os.path.join(patch, 'labels.tsv'), encoding='utf-8'):
    if line.startswith('#') or not line.strip(): continue
    part, rel, label, action = line.rstrip('\n').split('\t')
    rows.append((part, rel, label, action))
sample_placeholder = None
for part, rel, label, action in rows:
    if action != 'add':
        continue
    # these two are created by later steps, not copied from payload/
    if rel.endswith('blackbox.xml') or rel == 'etc/selinux/odm_file_contexts':
        continue
    src = os.path.join(patch, 'payload', part, rel)
    if not os.path.isfile(src):
        missing.append(f'{part}/{rel}'); continue
    dst = os.path.join(stage, part, rel)
    if os.path.exists(dst):
        skipped.append(f'{part}/{rel}'); continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, 0o755 if rel.startswith('bin/') else 0o644)
    os.chown(dst, 0, 0)
    added.append(f'{part}/{rel}')
with open(report, 'a', encoding='utf-8') as f:
    f.write(f'  added={len(added)} skipped(existing)={len(skipped)} missing_from_patch={len(missing)}\n')
    f.write(f'  skipped: {skipped}\n')
    if missing: f.write(f'  MISSING (payload incomplete!): {missing}\n')
print(f'  added={len(added)} skipped(existing)={len(skipped)} missing={len(missing)}')
if skipped: print(f'  skipped: {skipped}')
if missing:
    print(f'  ERROR: payload files missing from the patch: {missing}')
    sys.exit(3)
PY

say "[3/9] writing /odm/etc/selinux/odm_file_contexts"
mkdir -p "$STAGE/odm/etc/selinux"
cp "$PATCH/selinux/odm_file_contexts" "$STAGE/odm/etc/selinux/odm_file_contexts"
chmod 644 "$STAGE/odm/etc/selinux/odm_file_contexts"; chown 0:0 "$STAGE/odm/etc/selinux/odm_file_contexts"
say "  $(wc -l < "$STAGE/odm/etc/selinux/odm_file_contexts") lines"

say "[4/9] appending vendor contexts"
cat "$PATCH/selinux/vendor_service_contexts.append"  >> "$STAGE/vendor/etc/selinux/vendor_service_contexts"
cat "$PATCH/selinux/vendor_property_contexts.append" >> "$STAGE/vendor/etc/selinux/vendor_property_contexts"
cat "$PATCH/selinux/vendor_file_contexts.append"     >> "$STAGE/vendor/etc/selinux/vendor_file_contexts"

say "[5/9] appending SELinux policy blocks"
if [ "$DO_CIL" = 1 ]; then
  for f in "$STAGE/vendor/etc/selinux/vendor_sepolicy.cil" "$STAGE/vendor/etc/selinux/vendor_sepolicy_debug.cil"; do
    [ -f "$f" ] || continue
    { echo; cat "$PATCH/selinux/misys_hypys_block.cil"; echo; cat "$PATCH/selinux/mtd_block.cil"; } >> "$f"
    say "  $(basename "$f") -> $(wc -l < "$f") lines"
  done
else
  say "  skipped (--skip-cil)"
fi

say "[6/9] adding blackbox VINTF manifest"
cp "$PATCH/vintf/vendor.xiaomi.hardware.blackbox.xml" "$STAGE/vendor/etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml"
chmod 644 "$STAGE/vendor/etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml"
chown 0:0 "$STAGE/vendor/etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml"

say "[7/9] stripping security.selinux from stage (keeping security.capability)"
python3 - "$STAGE" "$REPORT" <<'PY'
import os, sys
stage, report = sys.argv[1:3]
n = 0
for part in ('odm', 'vendor'):
    base = os.path.join(stage, part)
    for dp, dn, fn in os.walk(base):
        for name in fn + dn:
            try:
                os.removexattr(os.path.join(dp, name), 'security.selinux', follow_symlinks=False); n += 1
            except OSError:
                pass
with open(report, 'a', encoding='utf-8') as f:
    f.write(f'  stripped security.selinux from {n} inodes (capabilities untouched)\n')
PY

say "[8/9] building 100%-coverage file-contexts"
python3 - "$PATCH" "$ODM_MNT" "$VEN_MNT" "$OUT" "$REPORT" <<'PY'
import os, re, sys
patch, odm_mnt, ven_mnt, out, report = sys.argv[1:6]
rows = []
for line in open(os.path.join(patch, 'labels.tsv'), encoding='utf-8'):
    if line.startswith('#') or not line.strip(): continue
    part, rel, label, action = line.rstrip('\n').split('\t')
    if action == 'add': rows.append((part, rel, label))
rows.append(('vendor', 'etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml', 'vendor_configs_file'))

summary = []
def build(part, mnt, mp, outp, new):
    entries, noattr, seen = [], [], set()
    try:
        entries.append(re.escape(mp) + ' ' +
                       os.getxattr(mnt, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode() + '\n')
    except OSError:
        noattr.append('/')
    for dp, dn, fn in os.walk(mnt):
        for name in list(dn) + list(fn):
            p = os.path.join(dp, name)
            rel = os.path.relpath(p, mnt).replace(os.sep, '/')
            if rel in new:
                entries.append(re.escape(mp + '/' + rel) + ' u:object_r:' + new[rel] + ':s0\n'); seen.add(rel)
            else:
                try:
                    lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
                except OSError:
                    noattr.append(rel); continue
                entries.append(re.escape(mp + '/' + rel) + ' ' + lbl + '\n')
    for rel, lbl in new.items():
        if rel not in seen:
            entries.append(re.escape(mp + '/' + rel) + ' u:object_r:' + lbl + ':s0\n')
    entries.sort()
    open(outp, 'w', encoding='utf-8').write(''.join(entries))
    summary.append(f'  {mp}: entries={len(entries)} explicit_new={len(new)} without_xattr={len(noattr)}')
    if noattr: summary.append(f'    WARNING no-xattr entries: {noattr[:8]}')

build('odm', odm_mnt, '/odm', os.path.join(out, 'odm_file_contexts'), {r: l for p, r, l in rows if p == 'odm'})
build('vendor', ven_mnt, '/vendor', os.path.join(out, 'vendor_file_contexts'), {r: l for p, r, l in rows if p == 'vendor'})
with open(report, 'a', encoding='utf-8') as f:
    f.write('[8] file-contexts coverage\n')
    f.write('\n'.join(summary) + '\n')
PY

say "[9/9] building images"
mkfs.erofs --quiet $ZFLAG -C$PCLUSTER -b4096 -T0 --mount-point=/odm \
  --file-contexts="$OUT/odm_file_contexts" "$OUT/odm.raw.img" "$STAGE/odm" >>"$OUT/logs/mkfs_odm.log" 2>&1
fsck.erofs "$OUT/odm.raw.img" >>"$OUT/logs/fsck_odm.log" 2>&1
img2simg "$OUT/odm.raw.img" "$OUT/odm.img"
mkfs.erofs --quiet $ZFLAG -C$PCLUSTER -b4096 -T0 --mount-point=/vendor \
  --file-contexts="$OUT/vendor_file_contexts" "$OUT/vendor.raw.img" "$STAGE/vendor" >>"$OUT/logs/mkfs_vendor.log" 2>&1
fsck.erofs "$OUT/vendor.raw.img" >>"$OUT/logs/fsck_vendor.log" 2>&1
img2simg "$OUT/vendor.raw.img" "$OUT/vendor.img"

say ""
say "images:"
say "  $OUT/odm.img    $(stat -c%s "$OUT/odm.img") bytes  sha256=$(sha256sum "$OUT/odm.img" | cut -d' ' -f1)"
say "  $OUT/vendor.img $(stat -c%s "$OUT/vendor.img") bytes  sha256=$(sha256sum "$OUT/vendor.img" | cut -d' ' -f1)"
say ""
say "next: scripts/verify_xiaomi_account.sh --out $OUT --baseline-odm $ODM_MNT --baseline-vendor $VEN_MNT"
say "APPLY_OK"
