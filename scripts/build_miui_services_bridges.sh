#!/usr/bin/env bash
# Build the image-side system_server bridges (Windows / Git Bash, local SDK):
#
#   patches/screen-color/RmxScreenColorBridge.java  screen colour (DisplayFeatureManagerService)
#   patches/haptic/RmxHapticBridge.java              haptics (VibratorManagerServiceImpl)
#   patches/cos-wallet/RmxWalletBridge.java          ColorOS wallet (ShortCutActionsUtils,
#                                                    AurogonImmobulusMode)
#       -> patches/miui-services-bridges.dex, added to
#       system_ext/framework/miui-services.jar as an extra classesN.dex by
#       scripts/patch_miui_services_greeze.py
#   patches/screen-color/overlay/ -> patches/screen-color/RMX5010ColorModes.apk
#       static RRO for android: config_availableColorModes + ColorOS render
#       intents 301/303/307, installed to product/overlay by
#       scripts/merge_module_into_image.sh.  targetSdk 28: OverlayManager does
#       not enforce <overlayable> for a preinstalled pre-Q overlay, so the
#       result does not depend on whether framework-res declares this
#       resource overlayable.
#
# Env:
#   BUILD_TOOLS   build-tools directory (default: /d/AndroidSDK/build-tools/36.0.0)
#   ANDROID_JAR   platform android.jar (default: /d/AndroidSDK/platforms/android-37.0/android.jar)
#   DEBUG_KEYSTORE / DEBUG_KEY_ALIAS / DEBUG_KEYPASS  overlay signing key (debug key)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SC="$ROOT/patches/screen-color"
BT="${BUILD_TOOLS:-/d/AndroidSDK/build-tools/36.0.0}"
ANDROID_JAR="${ANDROID_JAR:-/d/AndroidSDK/platforms/android-37.0/android.jar}"
DEBUG_KEYSTORE="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
DEBUG_KEY_ALIAS="${DEBUG_KEY_ALIAS:-androiddebugkey}"
DEBUG_KEYPASS="${DEBUG_KEYPASS:-android}"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"

win() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- bridge dex (both classes in one dex)
mkdir -p "$TMP/classes" "$TMP/dex"
"$JAVA_HOME/bin/javac.exe" --release 17 -classpath "$(win "$ANDROID_JAR")" \
  -d "$(win "$TMP/classes")" \
  "$(win "$SC/RmxScreenColorBridge.java")" "$(win "$ROOT/patches/haptic/RmxHapticBridge.java")"   "$(win "$ROOT/patches/cos-wallet/RmxWalletBridge.java")"
# every class file, including anonymous inner classes (RmxHapticBridge$1)
CLASSES=()
while IFS= read -r f; do CLASSES+=("$(win "$f")"); done < <(find "$TMP/classes" -name '*.class' | sort)
JAVA_HOME="$JAVA_HOME" "$BT/d8.bat" --release --min-api 35 --lib "$(win "$ANDROID_JAR")" \
  --output "$(win "$TMP/dex")" "${CLASSES[@]}"
cp "$TMP/dex/classes.dex" "$ROOT/patches/miui-services-bridges.dex"
echo "dex: $ROOT/patches/miui-services-bridges.dex"

# ---- colour mode overlay
mkdir -p "$TMP/compiled"
"$BT/aapt2.exe" compile --dir "$(win "$SC/overlay/res")" -o "$(win "$TMP/compiled/res.zip")"
"$BT/aapt2.exe" link -o "$(win "$TMP/unsigned.apk")" \
  --manifest "$(win "$SC/overlay/AndroidManifest.xml")" \
  -I "$(win "$ANDROID_JAR")" "$(win "$TMP/compiled/res.zip")" \
  --min-sdk-version 28 --target-sdk-version 28
"$BT/zipalign.exe" -p -f 4 "$(win "$TMP/unsigned.apk")" "$(win "$TMP/aligned.apk")"
JAVA_HOME="$JAVA_HOME" "$BT/apksigner.bat" sign \
  --ks "$(win "$DEBUG_KEYSTORE")" --ks-key-alias "$DEBUG_KEY_ALIAS" \
  --ks-pass "pass:$DEBUG_KEYPASS" --key-pass "pass:$DEBUG_KEYPASS" \
  --out "$(win "$SC/RMX5010ColorModes.apk")" "$(win "$TMP/aligned.apk")"
rm -f "$SC/RMX5010ColorModes.apk.idsig"
echo "overlay: $SC/RMX5010ColorModes.apk"
