#!/usr/bin/env bash
# Copy the RMX5010 and ColorOS wallet hook sources into the Sense project.
# Sense-specific UI, manifest, xposed_init and resources are not touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SENSE_DIR="${SENSE_DIR:-$ROOT/../Sense}"
WALLET_DIR="${WALLET_DIR:-$ROOT/../COS-WALLET-FIX}"

[ -d "$SENSE_DIR/app/src/main/java/local/mio" ] || {
  echo "Sense source not found at $SENSE_DIR" >&2
  exit 1
}
[ -d "$WALLET_DIR/app/src/main/java/local/mio/coloroswalletcompat" ] || {
  echo "COS-WALLET-FIX source not found at $WALLET_DIR" >&2
  exit 1
}

rm -rf "$SENSE_DIR/app/src/main/java/local/mio/gt7profodfix"
cp -r "$ROOT/lsposed-src/java/local/mio/gt7profodfix" \
  "$SENSE_DIR/app/src/main/java/local/mio/"
rm -rf "$SENSE_DIR/app/src/main/java/local/mio/coloroswalletcompat"
cp -r "$WALLET_DIR/app/src/main/java/local/mio/coloroswalletcompat" \
  "$SENSE_DIR/app/src/main/java/local/mio/"

mkdir -p "$SENSE_DIR/app/src/main/assets"
cp "$WALLET_DIR/app/src/main/assets/oplus-fwk.jar" \
  "$SENSE_DIR/app/src/main/assets/oplus-fwk.jar"

mkdir -p "$SENSE_DIR/app/src/main/jniLibs/arm64-v8a"
cp "$ROOT/lsposed-src/libs/arm64-v8a/"*.so \
  "$SENSE_DIR/app/src/main/jniLibs/arm64-v8a/"

echo "Synced hooks into $SENSE_DIR"
echo "Build with: $ROOT/scripts/build_sense_module.sh"
