#!/usr/bin/env bash
# 为真我 GT7 Pro（RMX5010，6.6.89-android15-8 GKI 内核）构建 FOD 内核桥模块。
#
# 关键点（血泪）：真机内核是 Google GKI 构建，arm64 的 struct mod_arch_specific
# 比 realme 公开源码多两个 KCFI 字段（16 字节）。不补齐的话，模块的
# struct module 布局会比真机短 16 字节，装载时 .rela.gnu.linkonce.this_module
# 里 exit 的重定位会写进真机的 target_list 链表头，mod_sysfs_setup 一读就 Oops。
#
# 用法：在 WSL 里先准备好内核树，然后：
#   KBUILD=/root/kbuild/kernel ./build_fod_modules.sh
# 需要：
#   - realme_GT7pro-AndroidV-kernel-source（kernel-6.6.89 分支）及配套 vendor-source
#   - /proc/config.gz（真机）保存的 config
#   - clang 18（GKI 用 18.x；本脚本默认 /root/llvm188/bin/clang-18）
set -euo pipefail

K="${KBUILD:-/root/kbuild/kernel}"
OUT="${OUT:-$PWD/out}"
CCBIN="${CCBIN:-/root/llvm188/bin/clang-18}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
UNAME="${UNAME:-6.6.89-android15-8-g7e1f3c083cc6-abogki467167594-4k}"
DEVICE_CONFIG="${DEVICE_CONFIG:-/root/device_kernel.config}"
SYMVERS="${SYMVERS:-/root/vdlkm_scan/Module.symvers.full}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export CROSS_COMPILE="$CROSS"

echo "== [1] 应用 struct module 布局补丁 =="
if grep -q "num_kcfi_tids" "$K/arch/arm64/include/asm/module.h"; then
  echo "  已打过补丁"
else
  patch -d "$K" -p1 < "$HERE/patches/0001-arm64-mod_arch_specific-add-GKI-KCFI-fields.patch"
fi

echo "== [2] 用真机 config 配置内核树 =="
cp "$DEVICE_CONFIG" "$K/.config"
make -C "$K" ARCH=arm64 CC="$CCBIN" LD=ld.lld-18 HOSTCC=gcc olddefconfig >/dev/null
make -C "$K" ARCH=arm64 CC="$CCBIN" LD=ld.lld-18 HOSTCC=gcc -j"$(nproc)" modules_prepare

echo "== [3] 覆盖 vermagic 与符号版本表 =="
cp "$SYMVERS" "$K/Module.symvers"
printf '#define UTS_RELEASE "%s"\n' "$UNAME" > "$K/include/generated/utsrelease.h"
echo "$UNAME" > "$K/include/config/kernel.release"

echo "== [4] 编译 =="
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$HERE/rmx5010_fod_bridge.c" "$HERE/rmx5010_fod_diag.c" "$OUT/"
printf 'obj-m += rmx5010_fod_bridge.o\n' > "$OUT/Makefile"
make -C "$K" ARCH=arm64 CC="$CCBIN" LD=ld.lld-18 HOSTCC=gcc M="$OUT" -j"$(nproc)"
mv "$OUT/rmx5010_fod_bridge.ko" "$OUT/fod_bridge.ko"
rm -f "$OUT"/rmx5010_fod_bridge.* "$OUT/Makefile"
printf 'obj-m += rmx5010_fod_diag.o\n' > "$OUT/Makefile"
make -C "$K" ARCH=arm64 CC="$CCBIN" LD=ld.lld-18 HOSTCC=gcc M="$OUT" -j"$(nproc)"

echo "== [5] 自检 =="
for f in "$OUT/fod_bridge.ko" "$OUT/rmx5010_fod_diag.ko"; do
  echo "  $f"
  strings -a "$f" | grep -a vermagic | head -1 | sed 's/^/    /'
  /root/llvm188/bin/llvm-readelf -r -W "$f" | grep -a -A3 "rela.gnu.linkonce.this_module" | tail -2 | sed 's/^/    /'
done
cat <<'EOF'
  自检要点：@exit 重定位偏移必须是 0x5b8（真机 layout），不能是 0x5a8。
EOF
echo BUILD_KERNEL_MODULES_DONE
