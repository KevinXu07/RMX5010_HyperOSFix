#!/usr/bin/env bash
# Register the installed Sense APK as the single LSPosed module and add the
# RMX5010 + ColorOS wallet scopes without using the LSPosed manager UI.
#
# Sense must already be installed. The old local.mio.gt7profodfix and
# local.mio.coloroswalletcompat modules must not be enabled at the same time.
set -euo pipefail

# Git Bash/MSYS otherwise rewrites /data/local/tmp/... into a Windows path.
export MSYS2_ARG_CONV_EXCL='*'

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-adb}"
SERIAL="${SERIAL:-}"
DEX="$ROOT/tools/lspd/lspdscope.dex"
SCOPES="android system com.android.systemui com.android.bluetooth com.android.settings com.miui.securitymanager com.miui.securitycenter org.ifaa.aidl.manager com.xiaomi.finddevice com.android.nfc com.android.se com.finshell.wallet com.heytap.tas com.unionpay.tsmservice com.oplus.eid com.miui.tsmclient"

ADB_CMD=("$ADB")
[ -n "$SERIAL" ] && ADB_CMD+=(-s "$SERIAL")

[ -f "$DEX" ] || { echo "missing $DEX" >&2; exit 1; }

APK_PATH="$("${ADB_CMD[@]}" shell pm path com.zephiel.sense | tr -d '\r' | sed -n 's/^package://p' | head -1)"
[ -n "$APK_PATH" ] || {
  echo "Sense is not installed; install out/Sense-RMX5010.apk first." >&2
  exit 1
}

for old in local.mio.gt7profodfix local.mio.coloroswalletcompat; do
  if "${ADB_CMD[@]}" shell pm path "$old" | grep -q '^package:'; then
    echo "warning: old LSPosed module still installed: $old" >&2
    echo "         uninstall it, otherwise hooks will be applied twice." >&2
  fi
done

DEX_ARG="$DEX"
if command -v cygpath >/dev/null 2>&1; then
  DEX_ARG="$(cygpath -w "$DEX")"
fi
"${ADB_CMD[@]}" push "$DEX_ARG" /data/local/tmp/lspd_sense.dex >/dev/null

"${ADB_CMD[@]}" shell "su -c 'cd /data/local/tmp && CLASSPATH=lspd_sense.dex app_process /system/bin LspdModule /data/adb/lspd/config/modules_config.db com.zephiel.sense \"$APK_PATH\" $SCOPES'"

# HyperOS gates FLAG_SHOW_WHEN_LOCKED behind AppOps 10020 (MIUIOP(10020)).
if "${ADB_CMD[@]}" shell pm path com.finshell.wallet | grep -q '^package:'; then
  "${ADB_CMD[@]}" shell "cmd appops set com.finshell.wallet 10020 allow"
fi

echo "Registered com.zephiel.sense. Reboot to load the merged LSPosed module."
