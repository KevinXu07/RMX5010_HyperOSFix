#!/usr/bin/env bash
# Build the ColorOS wallet in-APK shim (Windows / Git Bash, local SDK):
#
#   patches/cos-wallet/RmxWalletShim.java -> patches/cos-wallet/rmx-wallet-shim.dex
#   patches/cos-wallet/RmxSeBridge.java   -> patches/cos-wallet/rmx-se-bridge.dex
#   patches/cos-wallet/RmxWalletNfc.java  -> patches/cos-wallet/rmx-nfc-bridge.dex
#   patches/cos-wallet/RmxWalletTsm.java  -> patches/cos-wallet/rmx-tsm-bridge.dex
#
# scripts/patch_cos_wallet.py adds the dex to FinShell / TAS / UnionPay TSM as
# their next classesN.dex.  patches/cos-wallet/stubs holds compile-only stubs
# of hidden platform classes (android.os.SystemProperties); they are not dexed.
#
# Env: BUILD_TOOLS, ANDROID_JAR, JAVA_HOME as in build_miui_services_bridges.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CW="$ROOT/patches/cos-wallet"
BT="${BUILD_TOOLS:-/d/AndroidSDK/build-tools/36.0.0}"
ANDROID_JAR="${ANDROID_JAR:-/d/AndroidSDK/platforms/android-37.0/android.jar}"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"

win() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/classes" "$TMP/dex"
"$JAVA_HOME/bin/javac.exe" --release 17 -classpath "$(win "$ANDROID_JAR")" \
  -sourcepath "$(win "$CW/stubs")" -implicit:none \
  -d "$(win "$TMP/classes")" "$(win "$CW/RmxWalletShim.java")"
CLASSES=()
while IFS= read -r f; do CLASSES+=("$(win "$f")"); done \
  < <(find "$TMP/classes/com" -name '*.class' | sort)
JAVA_HOME="$JAVA_HOME" "$BT/d8.bat" --release --min-api 29 --lib "$(win "$ANDROID_JAR")" \
  --output "$(win "$TMP/dex")" "${CLASSES[@]}"
cp "$TMP/dex/classes.dex" "$CW/rmx-wallet-shim.dex"
echo "dex: $CW/rmx-wallet-shim.dex"

# ---- SecureElement bridge (patches/cos-wallet/RmxSeBridge.java -> rmx-se-bridge.dex),
# added to system/app/SecureElement by scripts/patch_secure_element.py
mkdir -p "$TMP/se_classes" "$TMP/se_dex"
"$JAVA_HOME/bin/javac.exe" --release 17 -classpath "$(win "$ANDROID_JAR")" \
  -d "$(win "$TMP/se_classes")" "$(win "$CW/RmxSeBridge.java")"
SE_CLASSES=()
while IFS= read -r f; do SE_CLASSES+=("$(win "$f")"); done \
  < <(find "$TMP/se_classes" -name '*.class' | sort)
JAVA_HOME="$JAVA_HOME" "$BT/d8.bat" --release --min-api 33 --lib "$(win "$ANDROID_JAR")" \
  --output "$(win "$TMP/se_dex")" "${SE_CLASSES[@]}"
cp "$TMP/se_dex/classes.dex" "$CW/rmx-se-bridge.dex"
echo "dex: $CW/rmx-se-bridge.dex"

# ---- NFC service bridge (patches/cos-wallet/RmxWalletNfc.java -> rmx-nfc-bridge.dex),
# added to system/app/XMNfcNci by scripts/patch_xm_nfc.py
mkdir -p "$TMP/nfc_classes" "$TMP/nfc_dex"
"$JAVA_HOME/bin/javac.exe" --release 17 -classpath "$(win "$ANDROID_JAR")" \
  -d "$(win "$TMP/nfc_classes")" "$(win "$CW/RmxWalletNfc.java")"
NFC_CLASSES=()
while IFS= read -r f; do NFC_CLASSES+=("$(win "$f")"); done \
  < <(find "$TMP/nfc_classes" -name '*.class' | sort)
JAVA_HOME="$JAVA_HOME" "$BT/d8.bat" --release --min-api 33 --lib "$(win "$ANDROID_JAR")" \
  --output "$(win "$TMP/nfc_dex")" "${NFC_CLASSES[@]}"
cp "$TMP/nfc_dex/classes.dex" "$CW/rmx-nfc-bridge.dex"
echo "dex: $CW/rmx-nfc-bridge.dex"

# ---- Mi TSM bridge (patches/cos-wallet/RmxWalletTsm.java -> rmx-tsm-bridge.dex),
# added to product/app/MITSMClient by scripts/patch_tsmclient.py
mkdir -p "$TMP/tsm_classes" "$TMP/tsm_dex"
"$JAVA_HOME/bin/javac.exe" --release 17 -classpath "$(win "$ANDROID_JAR")" \
  -d "$(win "$TMP/tsm_classes")" "$(win "$CW/RmxWalletTsm.java")"
TSM_CLASSES=()
while IFS= read -r f; do TSM_CLASSES+=("$(win "$f")"); done \
  < <(find "$TMP/tsm_classes" -name '*.class' | sort)
JAVA_HOME="$JAVA_HOME" "$BT/d8.bat" --release --min-api 29 --lib "$(win "$ANDROID_JAR")" \
  --output "$(win "$TMP/tsm_dex")" "${TSM_CLASSES[@]}"
cp "$TMP/tsm_dex/classes.dex" "$CW/rmx-tsm-bridge.dex"
echo "dex: $CW/rmx-tsm-bridge.dex"
