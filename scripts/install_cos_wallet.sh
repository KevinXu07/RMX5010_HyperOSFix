#!/usr/bin/env bash
# Install the ColorOS wallet suite (FinShell/TAS/HTMS/UPTsm/EidService) and the
# COS-WALLET-FIX LSPosed module on RMX5010 HyperOS, then register the LSPosed
# module/scope without the manager UI.
#
# The wallet APKs are third-party binaries from Maga-King/COS-WALLET-FIX
# v0.11.0; this script downloads and SHA-256 verifies the original release.
#
# Usage:
#   bash scripts/install_cos_wallet.sh [--reboot] [--no-download]
#
# Env:
#   ADB, SERIAL, WORK, WALLET_ZIP, LSP_APK
set -euo pipefail

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
LSP_URL="https://github.com/Maga-King/COS-WALLET-FIX/releases/download/v0.11.0/COS_WALLET_FIX_v0.11.0.apk"
LSP_SHA="d798b634fa59499be92aa9c55ab2e98fa7c1890c27d431aa30035684bbacb347"
WALLET_ZIP="${WALLET_ZIP:-$WORK/ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip}"
LSP_APK="${LSP_APK:-$WORK/COS_WALLET_FIX_v0.11.0.apk}"

ADB_CMD=("$ADB")
[ -n "$SERIAL" ] && ADB_CMD+=(-s "$SERIAL")

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
if [ ! -f "$LSP_APK" ]; then
  [ "$DOWNLOAD" = 1 ] || { echo "missing $LSP_APK" >&2; exit 1; }
  echo "download COS wallet LSP module ..."
  curl -L --retry 3 --retry-delay 5 -o "$LSP_APK" "$LSP_URL"
fi
sha_check "$WALLET_ZIP" "$WALLET_SHA"
sha_check "$LSP_APK" "$LSP_SHA"

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
  "${ADB_CMD[@]}" install -r "$apk"
done

echo "== allow FinShell swipe page over keyguard =="
# HyperOS gates FLAG_SHOW_WHEN_LOCKED behind AppOps 10020 (MIUIOP(10020)).
# User-installed FinShell is denied by default; without this the double-click
# swipe page is paused by Keyguard and finishes itself.
"${ADB_CMD[@]}" shell "cmd appops set com.finshell.wallet 10020 allow"
"${ADB_CMD[@]}" shell "cmd appops get com.finshell.wallet 10020" | grep -q 'allow' \
  || { echo "warning: show-when-locked app-op not applied" >&2; }

echo "== install COS-WALLET-FIX LSP module =="
"${ADB_CMD[@]}" install -r "$LSP_APK"

echo "== register LSPosed module + scope =="
"${ADB_CMD[@]}" push "$ROOT/tools/lspd/lspdscope.dex" /data/local/tmp/lspd_wallet.dex >/dev/null
APK_PATH="$("${ADB_CMD[@]}" shell pm path local.mio.coloroswalletcompat | tr -d '\r' | sed -n 's/^package://p' | head -1)"
[ -n "$APK_PATH" ] || { echo "LSP module not installed" >&2; exit 1; }

SCOPES="android system com.android.nfc com.android.se com.android.settings com.finshell.wallet com.heytap.tas com.unionpay.tsmservice com.oplus.eid com.heytap.htms com.miui.tsmclient"
"${ADB_CMD[@]}" shell "su -c 'cd /data/local/tmp && CLASSPATH=lspd_wallet.dex app_process /system/bin LspdModule /data/adb/lspd/config/modules_config.db local.mio.coloroswalletcompat \"$APK_PATH\" $SCOPES'"

echo
echo "Installed. Reboot is required before LSPosed can inject into the wallet processes."
if [ "$REBOOT" = 1 ]; then
  "${ADB_CMD[@]}" reboot
else
  echo "Run: adb reboot"
fi
echo "After reboot, open com.finshell.wallet, accept the privacy notice, and log in."
echo "If wallet packages were uninstalled/reinstalled, rerun this script and reboot:"
echo "  LSPosed prunes scope rows when the package is absent."
