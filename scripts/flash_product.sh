#!/usr/bin/env bash
# 只刷 product 分区（fastbootd），严格遵守：枚举后等 5 秒再执行任何命令（含 getvar）
#
# 用法：PART=product_a IMG=/path/product_fp.img ./flash_product.sh
set -uo pipefail
ADB="${ADB:-/d/AndroidSDK/platform-tools/adb.exe}"
FB="${FB:-/d/AndroidSDK/platform-tools/fastboot.exe}"
SERIAL="${SERIAL:-acbefdc7}"
PART="${PART:-product_a}"
IMG="${IMG:?IMG is required}"
S="-s $SERIAL"

echo "=== [0] adb -> bootloader ==="
"$ADB" $S get-state || exit 1
"$ADB" $S reboot bootloader
for i in $(seq 1 90); do
  "$FB" devices 2>/dev/null | grep -q "$SERIAL" && break
  sleep 1
done

echo "=== [1] -> fastbootd ==="
"$FB" $S reboot fastboot || true
for i in $(seq 1 90); do
  "$FB" devices 2>/dev/null | grep -q "$SERIAL" && break
  sleep 1
done
echo "等待 6 秒（5 秒规则）"
sleep 6
"$FB" $S getvar is-userspace 2>&1 | grep -qi yes || { echo "FAIL not fastbootd"; exit 1; }

echo "=== [2] 刷 $PART ==="
"$FB" $S -S 128M flash "$PART" "$IMG" || { echo "FAIL flash"; exit 1; }
"$FB" $S reboot

echo "=== [3] 等待开机并验证 ==="
for i in $(seq 1 180); do
  st=$("$ADB" $S get-state 2>/dev/null | tr -d '\r\n')
  if [ "$st" = "device" ] && \
     [ "$("$ADB" $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" = "1" ]; then
    break
  fi
  sleep 2
done
"$ADB" $S shell 'pm list features | grep -i fingerprint'
"$ADB" $S shell 'dumpsys biometric 2>&1 | head -8'
echo FLASH_PRODUCT_DONE
