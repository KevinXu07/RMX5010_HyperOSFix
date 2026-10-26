#!/usr/bin/env bash
# Build Sense and copy the APK to RMX5010_HyperOSFix/out.
#
# Sense is the single LSPosed module: its Compose UI, the RMX5010 hooks and
# the ColorOS wallet compatibility hooks all live in this one APK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SENSE_DIR="${SENSE_DIR:-$ROOT/../Sense}"
OUT="${OUT:-$ROOT/out}"
JAVA_HOME="${JAVA_HOME:-/d/Program Files/Android/Android Studio/jbr}"

[ -x "$SENSE_DIR/gradlew" ] || {
  echo "Sense gradlew not found under $SENSE_DIR" >&2
  echo "Set SENSE_DIR to the Sense source directory." >&2
  exit 1
}

export JAVA_HOME
cd "$SENSE_DIR"
./gradlew :app:assembleDebug --no-daemon

APK="$SENSE_DIR/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || { echo "Sense APK not produced: $APK" >&2; exit 1; }

mkdir -p "$OUT"
cp -f "$APK" "$OUT/Sense-RMX5010.apk"
echo "Sense module: $OUT/Sense-RMX5010.apk"
sha256sum "$OUT/Sense-RMX5010.apk"
