#!/usr/bin/env bash
# patch_finddevice_apk.sh — apply the Notz smali patch to MIUIFindDeviceCN.apk and re-sign it.
#
#   patch_finddevice_apk.sh --apk <original.apk> --smali-dir <dir> \
#                           --keystore <ks.jks> --ks-pass <pass> [--key-pass <pass>] \
#                           [--alias <alias>] --out <patched.apk>
#
#   patch_finddevice_apk.sh --apk <original.apk> --report-perms        # 只分析权限图（需 aapt）
#
# Requires: java, and baksmali/smali 2.5.2 fat jars (dex 039 is NOT supported by 2.2.0),
#           apksigner, zipalign, python3. JAR paths via BAKSMALI_JAR / SMALI_JAR env vars.
#
# The patch files (dir given by --smali-dir) must be named:
#   gf_s0.smali              -> replaces  gf/s0.smali
#   DeviceCredentialTZ.smali -> replaces  com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali
set -euo pipefail

APK=""; SMALI_DIR=""; KS=""; KSPASS=""; KEYPASS=""; ALIAS="finddevice"; OUT=""; REPORT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apk) APK=$2; shift 2;;
    --smali-dir) SMALI_DIR=$2; shift 2;;
    --keystore) KS=$2; shift 2;;
    --ks-pass) KSPASS=$2; shift 2;;
    --key-pass) KEYPASS=$2; shift 2;;
    --alias) ALIAS=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --report-perms) REPORT=1; shift;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$APK" ] || { echo "usage: $0 --apk <apk> --smali-dir <dir> --keystore <ks> --ks-pass <p> --out <apk>" >&2; exit 2; }
BAKSMALI_JAR=${BAKSMALI_JAR:-baksmali-2.5.2-fat.jar}
SMALI_JAR=${SMALI_JAR:-smali-2.5.2-fat.jar}
for t in java python3; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 2; }; done

if [ "$REPORT" = 1 ]; then
  command -v aapt >/dev/null || { echo "aapt required for --report-perms" >&2; exit 2; }
  echo "== requested permissions =="
  aapt dump permissions "$APK" | sed -n "s/uses-permission: name='\(.*\)'/\1/p"
  echo
  echo "== declared permissions + protectionLevel =="
  aapt dump xmltree "$APK" AndroidManifest.xml | grep -A3 "E: permission " | grep -E 'android:name|protectionLevel'
  exit 0
fi

[ -n "$SMALI_DIR" ] && [ -n "$KS" ] && [ -n "$KSPASS" ] && [ -n "$OUT" ] || {
  echo "need --smali-dir --keystore --ks-pass --out" >&2; exit 2; }
[ -f "$SMALI_DIR/gf_s0.smali" ] && [ -f "$SMALI_DIR/DeviceCredentialTZ.smali" ] || {
  echo "smali dir must contain gf_s0.smali and DeviceCredentialTZ.smali" >&2; exit 2; }
[ -z "$KEYPASS" ] && KEYPASS="$KSPASS"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "[1/6] disassemble every dex"
mkdir -p "$WORK/dex" "$WORK/tree"
python3 - "$APK" "$WORK/dex" <<'PY'
import sys, zipfile
apk, outdir = sys.argv[1:3]
with zipfile.ZipFile(apk) as z:
    n = 0
    for name in z.namelist():
        if name.endswith('.dex'):
            open(f'{outdir}/{name}', 'wb').write(z.read(name)); n += 1
print(f'  extracted {n} dex files')
PY
for d in "$WORK"/dex/*.dex; do
  java -jar "$BAKSMALI_JAR" d "$d" -o "$WORK/tree" >/dev/null
done

echo "[2/6] locate target files in the tree"
TZ=$(find "$WORK/tree" -path "*com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali" | head -1)
S0=$(find "$WORK/tree" -path "*/gf/s0.smali" | head -1)
[ -n "$TZ" ] && [ -n "$S0" ] || { echo "  target classes not found (wrong APK version?)" >&2; exit 3; }
echo "  TZ: $TZ"
echo "  s0: $S0"
TZ_DEX=$(echo "$TZ" | sed "s|$WORK/tree/||" | cut -d/ -f1)   # not used; we rebuild per-dex below
# figure out which dex each file belongs to
for d in "$WORK"/dex/*.dex; do
  n=$(basename "$d" .dex)
  rm -rf "$WORK/chk"; mkdir -p "$WORK/chk"
  java -jar "$BAKSMALI_JAR" d "$d" -o "$WORK/chk" >/dev/null
  [ -f "$WORK/chk/gf/s0.smali" ] && echo "$n" > "$WORK/dex_of_s0"
  [ -f "$WORK/chk/com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali" ] && echo "$n" > "$WORK/dex_of_tz"
done
DEX_S0=$(cat "$WORK/dex_of_s0"); DEX_TZ=$(cat "$WORK/dex_of_tz")
echo "  gf/s0 in $DEX_S0.dex ; DeviceCredentialTZ in $DEX_TZ.dex"

echo "[3/6] apply patch files"
cp "$SMALI_DIR/gf_s0.smali" "$WORK/tree/gf/s0.smali"
cp "$SMALI_DIR/DeviceCredentialTZ.smali" "$WORK/tree/com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali"

echo "[4/6] rebuild the two dex files (api 28 -> dex 039)"
mkdir -p "$WORK/newdex"
# rebuild each dex from its own subtree
rm -rf "$WORK/t1" "$WORK/t2"; mkdir -p "$WORK/t1" "$WORK/t2"
java -jar "$BAKSMALI_JAR" d "$WORK/dex/$DEX_S0.dex" -o "$WORK/t1" >/dev/null
java -jar "$BAKSMALI_JAR" d "$WORK/dex/$DEX_TZ.dex" -o "$WORK/t2" >/dev/null
cp "$SMALI_DIR/gf_s0.smali" "$WORK/t1/gf/s0.smali"
cp "$SMALI_DIR/DeviceCredentialTZ.smali" "$WORK/t2/com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali"
java -jar "$SMALI_JAR" a "$WORK/t1" -o "$WORK/newdex/$DEX_S0.dex" -a 28
java -jar "$SMALI_JAR" a "$WORK/t2" -o "$WORK/newdex/$DEX_TZ.dex" -a 28
for f in "$WORK"/newdex/*.dex; do
  echo "  $(basename $f): $(stat -c%s $f) bytes, dex version=$(xxd -s 4 -l 3 -p $f)"
done

echo "[5/6] repack APK (preserve order/compression of every other entry)"
python3 - "$APK" "$WORK/newdex" "$WORK/repacked.apk" "$DEX_S0.dex" "$DEX_TZ.dex" <<'PY'
import sys, zipfile, os
apk, newdex, out, d1, d2 = sys.argv[1:6]
zin = zipfile.ZipFile(apk)
zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
replaced = 0
for zi in zin.infolist():
    if zi.filename in (d1, d2):
        data = open(os.path.join(newdex, zi.filename), 'rb').read()
        zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
        zi2.compress_type = zi.compress_type
        zi2.external_attr = zi.external_attr
        zi2.internal_attr = zi.internal_attr
        zi2.create_system = zi.create_system
        zout.writestr(zi2, data); replaced += 1
    else:
        zout.writestr(zi, zin.read(zi.filename))
zout.close(); zin.close()
print(f'  replaced {replaced} entries -> {os.path.getsize(out)} bytes')
PY

echo "[6/6] align + sign"
mkdir -p "$(dirname "$OUT")"
zipalign -p -f 4 "$WORK/repacked.apk" "$WORK/aligned.apk"
apksigner sign --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KEYPASS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT" "$WORK/aligned.apk"
apksigner verify --verbose "$OUT" | head -8
zipalign -c -p 4 "$OUT" && echo "  zipalign OK"
echo "PATCHED: $OUT  sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
