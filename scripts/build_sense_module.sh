#!/usr/bin/env bash
# Build Sense and copy a signed, non-debuggable APK to RMX5010_HyperOSFix/out.
#
# Sense is the single LSPosed module: its Compose UI, the RMX5010 hooks and
# the ColorOS wallet compatibility hooks all live in this one APK.
#
# Env:
#   SENSE_DIR         Sense source (default: ../Sense)
#   OUT               output directory (default: ./out)
#   SENSE_KEYSTORE    signing keystore (default: ~/.android/debug.keystore)
#   SENSE_KEY_ALIAS   key alias (default: androiddebugkey)
#   SENSE_KEYSTOREPASS / SENSE_KEYPASS (default: android)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SENSE_DIR="${SENSE_DIR:-$ROOT/../Sense}"
OUT="${OUT:-$ROOT/out}"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"
SDK="${SDK:-/d/AndroidSDK}"
BT="$SDK/build-tools/36.0.0"
SENSE_KEYSTORE="${SENSE_KEYSTORE:-$HOME/.android/debug.keystore}"
SENSE_KEY_ALIAS="${SENSE_KEY_ALIAS:-androiddebugkey}"
SENSE_KEYSTOREPASS="${SENSE_KEYSTOREPASS:-android}"
SENSE_KEYPASS="${SENSE_KEYPASS:-android}"

[ -x "$SENSE_DIR/gradlew" ] || {
  echo "Sense gradlew not found under $SENSE_DIR" >&2
  echo "Set SENSE_DIR to the Sense source directory." >&2
  exit 1
}
[ -f "$SENSE_KEYSTORE" ] || {
  echo "Signing keystore not found: $SENSE_KEYSTORE" >&2
  echo "Set SENSE_KEYSTORE, or generate the default Android debug keystore." >&2
  exit 1
}

export JAVA_HOME
cd "$SENSE_DIR"
./gradlew :app:assembleRelease --no-daemon

UNSIGNED="$SENSE_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"
[ -f "$UNSIGNED" ] || { echo "Sense release APK not produced: $UNSIGNED" >&2; exit 1; }

mkdir -p "$OUT"
ALIGNED="$OUT/Sense-RMX5010-aligned.apk"
SIGNED="$OUT/Sense-RMX5010.apk"
rm -f "$ALIGNED" "$SIGNED"

win() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

"$BT/zipalign.exe" -f -p 4 "$(win "$UNSIGNED")" "$(win "$ALIGNED")"
JAVA_HOME="$JAVA_HOME" "$BT/apksigner.bat" sign \
  --ks "$(win "$SENSE_KEYSTORE")" \
  --ks-pass "pass:$SENSE_KEYSTOREPASS" \
  --key-pass "pass:$SENSE_KEYPASS" \
  --ks-key-alias "$SENSE_KEY_ALIAS" \
  --out "$(win "$SIGNED")" "$(win "$ALIGNED")"
rm -f "$ALIGNED"
JAVA_HOME="$JAVA_HOME" "$BT/apksigner.bat" verify --print-certs "$(win "$SIGNED")" \
  | grep -E 'Signer #1 certificate (DN|SHA-256)'

echo "Sense module: $SIGNED"
sha256sum "$SIGNED"
