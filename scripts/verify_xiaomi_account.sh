#!/usr/bin/env bash
# verify_xiaomi_account.sh — offline verification for the applied Xiaomi-account patch.
#
#   verify_xiaomi_account.sh --out <outdir> --baseline-odm <mnt> --baseline-vendor <mnt> \
#                            [--patch <patches/xiaomi-account>]
#
# Checks (all must pass):
#   1. labels of every injected file match labels.tsv
#   2. regular files: 0 removed; only expected additions + the selinux context/policy files changed
#   3. symlink targets unchanged; directory mode/owner unchanged
#   4. security.capability xattrs not lost
#   5. appended contexts/policy content present in the images
#   6. sparse integrity: simg2img round-trip equals raw
#
# Exits non-zero if any check fails. Always remounts fresh (stale erofsfuse mounts
# would silently serve the previous image -> see docs/SELinux闭包与EROFS重建规范.md §4.3).
set -euo pipefail

OUT=""; ODM_MNT=""; VEN_MNT=""; PATCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2;;
    --baseline-odm) ODM_MNT=$2; shift 2;;
    --baseline-vendor) VEN_MNT=$2; shift 2;;
    --patch) PATCH=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$OUT" ] && [ -n "$ODM_MNT" ] && [ -n "$VEN_MNT" ] || {
  echo "usage: $0 --out <dir> --baseline-odm <mnt> --baseline-vendor <mnt> [--patch <dir>]" >&2; exit 2; }

[ -f "$OUT/odm.raw.img" ] && [ -f "$OUT/vendor.raw.img" ] || { echo "missing $OUT/*.raw.img (rebuild image with the same script that produced it)" >&2; exit 2; }
[ "$(command -v erofsfuse || true)" ] || { echo "erofsfuse not found" >&2; exit 2; }

NEW_ODM="$OUT/_mnt/odm"; NEW_VEN="$OUT/_mnt/vendor"
for d in "$NEW_ODM" "$NEW_VEN"; do
  mkdir -p "$d"
  fusermount3 -u "$d" 2>/dev/null || umount "$d" 2>/dev/null || true
done
erofsfuse "$OUT/odm.raw.img" "$NEW_ODM" >/dev/null 2>&1
erofsfuse "$OUT/vendor.raw.img" "$NEW_VEN" >/dev/null 2>&1
sleep 1
mountpoint -q "$NEW_ODM" || { echo "cannot mount new odm" >&2; exit 2; }
mountpoint -q "$NEW_VEN" || { echo "cannot mount new vendor" >&2; exit 2; }

PATCH_ARG="${PATCH:-$(cd "$(dirname "$0")/../patches/xiaomi-account" && pwd)}"
REPORT="$OUT/verify_report.txt"
: > "$REPORT"

python3 - "$PATCH_ARG" "$ODM_MNT" "$NEW_ODM" "$VEN_MNT" "$NEW_VEN" "$REPORT" <<'PY' | tee -a "$REPORT"
import hashlib, os, stat, sys
patch, o_mnt, n_odm, v_mnt, n_ven, report = sys.argv[1:7]

# expected labels
expect = {'odm': {}, 'vendor': {}}
for line in open(os.path.join(patch, 'labels.tsv'), encoding='utf-8'):
    if line.startswith('#') or not line.strip(): continue
    part, rel, label, action = line.rstrip('\n').split('\t')
    if action == 'add': expect[part][rel] = label
expect['vendor']['etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml'] = 'vendor_configs_file'
allowed_changes = {
 'etc/selinux/vendor_sepolicy.cil', 'etc/selinux/vendor_sepolicy_debug.cil',
 'etc/selinux/vendor_service_contexts', 'etc/selinux/vendor_property_contexts',
 'etc/selinux/vendor_file_contexts',
 'etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml',
 'etc/selinux/odm_file_contexts',
}

def scan(root):
    reg, lnk, dr = {}, {}, {}
    def rec(p, rel):
        s = os.lstat(p)
        if stat.S_ISLNK(s.st_mode):
            lnk[rel] = os.readlink(p)
        elif stat.S_ISDIR(s.st_mode):
            dr[rel] = (stat.S_IMODE(s.st_mode), s.st_uid, s.st_gid, s.st_mode)
            for n in sorted(os.listdir(p)): rec(os.path.join(p, n), rel + '/' + n if rel else n)
        else:
            h = hashlib.sha256()
            with open(p, 'rb') as f:
                for c in iter(lambda: f.read(1 << 22), b''): h.update(c)
            try: cap = os.getxattr(p, 'security.capability').hex()
            except OSError: cap = ''
            try: lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
            except OSError: lbl = '<none>'
            reg[rel] = (stat.S_IMODE(s.st_mode), s.st_uid, s.st_gid, s.st_size, h.hexdigest(), cap, lbl)
    for n in sorted(os.listdir(root)): rec(os.path.join(root, n), n)
    return reg, lnk, dr

fails = []
def check(cond, msg):
    print(('  OK   ' if cond else '  FAIL ') + msg)
    if not cond: fails.append(msg)

print('=== 1. injected file labels ===')
for part, mnt in (('odm', n_odm), ('vendor', n_ven)):
    bad = []
    for rel, want in sorted(expect[part].items()):
        p = os.path.join(mnt, rel)
        if not os.path.exists(p): bad.append(f'{rel}: MISSING'); continue
        got = os.getxattr(p, 'security.selinux', follow_symlinks=False).rstrip(b'\0').decode()
        if got != f'u:object_r:{want}:s0': bad.append(f'{rel}: {got} != u:object_r:{want}:s0')
    check(not bad, f'{part}: {len(expect[part])} injected files, {len(bad)} label problems')
    for b in bad[:10]: print('       ', b)

print()
print('=== 2-4. diff vs baseline ===')
for part, bmnt, nmnt in (('odm', o_mnt, n_odm), ('vendor', v_mnt, n_ven)):
    o_reg, o_lnk, o_dr = scan(bmnt)
    n_reg, n_lnk, n_dr = scan(nmnt)
    added = sorted(set(n_reg) - set(o_reg))
    removed = sorted(set(o_reg) - set(n_reg))
    changed = [k for k in sorted(set(o_reg) & set(n_reg)) if o_reg[k][:6] != n_reg[k][:6]]  # ignore label in this cmp? no: compare all but label
    changed = [k for k in sorted(set(o_reg) & set(n_reg)) if o_reg[k] != n_reg[k]]
    unexpected_add = [a for a in added if a not in expect[part]]
    unexpected_chg = [c for c in changed if c not in allowed_changes]
    l_bad = [k for k in sorted(set(o_lnk) & set(n_lnk)) if o_lnk[k] != n_lnk[k]]
    d_bad = [k for k in sorted(set(o_dr) & set(n_dr)) if o_dr[k][:3] != n_dr[k][:3]]
    lost_caps = [k for k in o_reg if o_reg[k][5] and not n_reg.get(k, ('',)*6)[5]]
    check(not removed, f'{part}: 0 removed regular files (got {len(removed)})')
    check(not unexpected_add, f'{part}: additions all expected ({len(added)} added, {len(unexpected_add)} unexpected)')
    check(not unexpected_chg, f'{part}: changes limited to selinux context/policy files ({len(changed)} changed, {len(unexpected_chg)} unexpected)')
    check(not l_bad, f'{part}: symlink targets unchanged ({len(o_lnk)} links, {len(l_bad)} changed)')
    check(not d_bad, f'{part}: directory mode/owner unchanged ({len(o_dr)} dirs, {len(d_bad)} changed)')
    check(not lost_caps, f'{part}: security.capability preserved (lost {len(lost_caps)})')
    for x in (removed[:5] + unexpected_add[:5] + unexpected_chg[:8] + lost_caps[:5]): print('       ', x)

print()
print('=== 5. appended content present ===')
def lines(p):
    try: return sum(1 for _ in open(p, encoding='utf-8', errors='replace'))
    except OSError: return -1
checks = [('vendor_sepolicy.cil has mtd domain', 'hal_mtdservice_default', f'{n_ven}/etc/selinux/vendor_sepolicy.cil'),
          ('vendor_sepolicy.cil has misys domain', 'hal_misys_vendor_default', f'{n_ven}/etc/selinux/vendor_sepolicy.cil'),
          ('vendor_service_contexts has IMTService', 'IMTService/default', f'{n_ven}/etc/selinux/vendor_service_contexts'),
          ('vendor_property_contexts has payment_security', 'vendor_payment_security_prop', f'{n_ven}/etc/selinux/vendor_property_contexts'),
          ('vendor_file_contexts has ta_data_file dir', '/data/vendor/images', f'{n_ven}/etc/selinux/vendor_file_contexts'),
          ('vendor_file_contexts has fdsd dir', '/mnt/vendor/persist/fdsd', f'{n_ven}/etc/selinux/vendor_file_contexts'),
          ('odm_file_contexts present', 'hal_mtdservice_default_exec', f'{n_odm}/etc/selinux/odm_file_contexts')]
for name, needle, path in checks:
    try: ok = needle in open(path, encoding='utf-8', errors='replace').read()
    except OSError: ok = False
    check(ok, name)

print()
if fails:
    print(f'VERIFY_FAILED ({len(fails)} problems)')
    sys.exit(1)
print('VERIFY_PASSED')
PY

echo "=== 6. sparse round-trip ===" | tee -a "$REPORT"
simg2img "$OUT/odm.img" "$OUT/_odm_rt.raw"
cmp -s "$OUT/odm.raw.img" "$OUT/_odm_rt.raw" && echo "  OK   odm sparse" | tee -a "$REPORT" || { echo "  FAIL odm sparse" | tee -a "$REPORT"; exit 1; }
simg2img "$OUT/vendor.img" "$OUT/_vendor_rt.raw"
cmp -s "$OUT/vendor.raw.img" "$OUT/_vendor_rt.raw" && echo "  OK   vendor sparse" | tee -a "$REPORT" || { echo "  FAIL vendor sparse" | tee -a "$REPORT"; exit 1; }
rm -f "$OUT/_odm_rt.raw" "$OUT/_vendor_rt.raw"
echo "report: $REPORT"
