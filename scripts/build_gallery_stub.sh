#!/usr/bin/env bash
# Rebuild ColorOSGalleryStub.apk, the metadata-only com.coloros.gallery3d
# package OplusCamera requires (Util.e0 reads its meta-data).
#
# The package has no activity and no MAIN/LAUNCHER intent-filter: it must not
# show a "Gallery" icon on the home screen.
#
# The APK is signed with the Android debug key, the same key the previously
# deployed stub used, so `pm install -r` can update an installed copy.
#
# Env:
#   BUILD_TOOLS   build-tools directory (default: /d/AndroidSDK/build-tools/36.0.0)
#   ANDROID_JAR   platform android.jar (default: /d/AndroidSDK/platforms/android-37.0/android.jar)
#   DEBUG_KEYSTORE / DEBUG_KEY_ALIAS / DEBUG_KEYPASS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/kernel-src/ksu-module/camera/priv-app/ColorOSGalleryStub"
BT="${BUILD_TOOLS:-/d/AndroidSDK/build-tools/36.0.0}"
ANDROID_JAR="${ANDROID_JAR:-/d/AndroidSDK/platforms/android-37.0/android.jar}"
DEBUG_KEYSTORE="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
DEBUG_KEY_ALIAS="${DEBUG_KEY_ALIAS:-androiddebugkey}"
DEBUG_KEYPASS="${DEBUG_KEYPASS:-android}"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"

[ -f "$SRC/AndroidManifest.xml" ] || { echo "manifest not found: $SRC/AndroidManifest.xml" >&2; exit 1; }
[ -f "$ANDROID_JAR" ] || { echo "android.jar not found: $ANDROID_JAR" >&2; exit 1; }
[ -f "$DEBUG_KEYSTORE" ] || { echo "debug keystore not found: $DEBUG_KEYSTORE" >&2; exit 1; }

win() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
UNSIGNED="$TMP/unsigned.apk"
ALIGNED="$TMP/aligned.apk"
OUT="$SRC/ColorOSGalleryStub.apk"

"$BT/aapt2.exe" link -o "$(win "$UNSIGNED")" \
  --manifest "$(win "$SRC/AndroidManifest.xml")" \
  -I "$(win "$ANDROID_JAR")" \
  --min-sdk-version 35 --target-sdk-version 36
"$BT/zipalign.exe" -p -f 4 "$(win "$UNSIGNED")" "$(win "$ALIGNED")"
JAVA_HOME="$JAVA_HOME" "$BT/apksigner.bat" sign \
  --ks "$(win "$DEBUG_KEYSTORE")" \
  --ks-key-alias "$DEBUG_KEY_ALIAS" \
  --ks-pass "pass:$DEBUG_KEYPASS" \
  --key-pass "pass:$DEBUG_KEYPASS" \
  --out "$(win "$OUT")" "$(win "$ALIGNED")"

"$BT/aapt2.exe" dump badging "$(win "$OUT")" | grep -E '^package:|launchable-activity' || true
if "$BT/aapt2.exe" dump badging "$(win "$OUT")" | grep -q 'launchable-activity'; then
  echo "ERROR: stub still declares a launcher activity" >&2
  exit 1
fi
echo "gallery stub: $OUT"
