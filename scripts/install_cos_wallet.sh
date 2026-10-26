#!/usr/bin/env bash
# Install the ColorOS wallet suite (FinShell/TAS/HTMS/UPTsm/EidService) and the
# Sense APK (the single LSPosed module) on RMX5010 HyperOS, then register the
# LSPosed scopes without the manager UI.
#
# The wallet APKs are third-party binaries from Maga-King/COS-WALLET-FIX
# v0.11.0; this script downloads and SHA-256 verifies the original release.
# Sense now contains both the RMX5010 compatibility hooks and the ColorOS
# wallet compatibility hooks; the old local.mio.* LSPosed modules must not be
# installed at the same time.
#
# Usage:
#   bash scripts/install_cos_wallet.sh [--reboot] [--no-download]
#
# Env:
#   ADB, SERIAL, WORK, WALLET_ZIP, SENSE_APK
set -euo pipefail

# Git Bash/MSYS otherwise rewrites /data/local/tmp/... into a Windows path.
export MSYS2_ARG_CONV_EXCL='*'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/work/cos_wallet}"
ADB="${ADB:-adb}"
SERIAL="${SERIAL:-}"
REBOOT=0
DOWNLOAD=1
for arg in "$@"; do
  case "$arg" in
    --reboot) REBOOT=1 ;;
    --no-download) DOWNLOAD=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

WALLET_URL="https://github.com/Maga-King/COS-WALLET-FIX/releases/download/v0.11.0/ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip"
WALLET_SHA="a8ecb7a9795c310440844c805d4344de35915211b3b824e88908f1cae033da56"
WALLET_ZIP="${WALLET_ZIP:-$WORK/ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip}"
SENSE_APK="${SENSE_APK:-$ROOT/out/Sense-RMX5010.apk}"

ADB_CMD=("$ADB")
[ -n "$SERIAL" ] && ADB_CMD+=(-s "$SERIAL")

local_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

sha_check() {
  local file="$1" expected="$2" got
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$got" != "$expected" ]; then
    echo "SHA-256 mismatch: $file" >&2
    echo "  expected $expected" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

mkdir -p "$WORK"
if [ ! -f "$WALLET_ZIP" ]; then
  [ "$DOWNLOAD" = 1 ] || { echo "missing $WALLET_ZIP" >&2; exit 1; }
  echo "download wallet inject zip ..."
  curl -L --retry 3 --retry-delay 5 -o "$WALLET_ZIP" "$WALLET_URL"
fi
sha_check "$WALLET_ZIP" "$WALLET_SHA"

rm -rf "$WORK/extract"
mkdir -p "$WORK/extract"
unzip -q "$WALLET_ZIP" \
  'system/app/*/*.apk' \
  'system/system_ext/app/*/*.apk' \
  -d "$WORK/extract"

echo "== install wallet APKs (user apps) =="
for apk in \
  "$WORK/extract/system/app/HeytapHTMS/HeytapHTMS.apk" \
  "$WORK/extract/system/app/FinShellWallet/FinShellWallet.apk" \
  "$WORK/extract/system/app/TasWallet/TasWallet.apk" \
  "$WORK/extract/system/app/UPTsmService/UPTsmService.apk" \
  "$WORK/extract/system/system_ext/app/EidService/EidService.apk"; do
  echo "-- $(basename "$apk")"
  "${ADB_CMD[@]}" install -r "$(local_path "$apk")"
done

echo "== allow FinShell swipe page over keyguard =="
# HyperOS gates FLAG_SHOW_WHEN_LOCKED behind AppOps 10020 (MIUIOP(10020)).
# User-installed FinShell is denied by default; without this the double-click
# swipe page is paused by Keyguard and finishes itself.
"${ADB_CMD[@]}" shell "cmd appops set com.finshell.wallet 10020 allow"
"${ADB_CMD[@]}" shell "cmd appops get com.finshell.wallet 10020" | grep -q 'allow' \
  || { echo "warning: show-when-locked app-op not applied" >&2; }

if [ ! -f "$SENSE_APK" ]; then
  echo "missing $SENSE_APK" >&2
  echo "Build it first: bash scripts/build_sense_module.sh" >&2
  exit 1
fi

echo "== install Sense (single LSPosed module) =="
if ! "${ADB_CMD[@]}" install -r "$(local_path "$SENSE_APK")"; then
  echo "Sense install failed. If the signature differs, uninstall" >&2
  echo "com.zephiel.sense first; that clears Sense settings." >&2
  exit 1
fi

echo "== register Sense LSPosed module + scope =="
ADB="$ADB" SERIAL="$SERIAL" bash "$ROOT/scripts/register_sense_lsposed.sh"

echo
echo "Installed. Reboot is required before LSPosed can inject into the wallet processes."
if [ "$REBOOT" = 1 ]; then
  "${ADB_CMD[@]}" reboot
else
  echo "Run: adb reboot"
fi
echo "After reboot, open Sense, accept the privacy notice, and log in to FinShell."
echo "If wallet packages were uninstalled/reinstalled, rerun this script and reboot:"
echo "  LSPosed prunes scope rows when the package is absent."
