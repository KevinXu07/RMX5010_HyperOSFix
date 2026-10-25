# 内核模块构建：GKI KCFI 与 `struct module` 布局坑

> 2026-10-25 实机血泪记录。任何给 RMX5010（GT7 Pro，6.6.89-android15-8 GKI）写的
> out-of-tree 模块都必须先读完这篇，否则 insmod 100% Oops/panic。

## 1. 现象

自编 `.ko`（哪怕只有 `pr_info` 的 hello world）`insmod` 时：

```text
Unable to handle kernel paging request at virtual address 000017a09752c5f9
pc : mod_sysfs_setup+0x2c0/0x458
Call trace:
 mod_sysfs_setup+0x2c0/0x458
 load_module+0xfd4/0x1130
 __arm64_sys_finit_module+0x260/0x300
```

- 原厂自带模块（`llcc_perfmon.ko`、`atmel_mxt_ts.ko`）用 `su` insmod 完全正常。
- 崩溃点固定在 `mod_sysfs_setup` 的 `add_usage_links()`，读 `use->target->holders_dir`。
- `panic_on_oops=1` 时直接重启；`panic_on_oops=0` 时模块加载锁 `module_mutex` 被
  永久占住（之后任何 insmod/`/proc/modules` 都卡死），必须重启。

## 2. 根因

真机内核是 Google GKI 构建，arm64 的 `struct mod_arch_specific` 比 realme 公开
源码（`realme_GT7pro-AndroidV-kernel-source`，kernel-6.6.89 分支）多两个 KCFI 字段：

```c
#ifdef CONFIG_CFI_CLANG
	unsigned int		num_kcfi_tids;
	u32			*kcfi_tid_array;
#endif
```

共 16 字节。`struct mod_arch_specific arch` 在 `struct module` 里位于
`init` 之后、`source_list/target_list/exit` 之前，所以：

| 字段 | realme 源码编译 | 真机内核 |
|---|---|---|
| `mod->init`（reloc） | 0x188 | 0x188 |
| `mod->target_list` | 0x598 | **0x5a8** |
| `mod->exit`（reloc） | 0x5a8 | **0x5b8** |

`.gnu.linkonce.this_module` 段里带两个重定位（init/exit）。装载器按 **.ko 里编译时
写下的偏移** 打重定位补丁：`mod->exit = cleanup_module` 被写到 `0x5a8`——在真机布局
里正好是 `target_list.next`。于是链表头变成内核代码地址，`list_for_each_entry` 立刻
解引用野指针，`mod_sysfs_setup` Oops。

用 `.rela.gnu.linkonce.this_module` 的偏移即可一眼判定：

```bash
llvm-readelf -r -W xxx.ko | grep -A3 rela.gnu.linkonce.this_module
# 原厂模块 / 正确构建：exit 偏移 00000000000005b8
# 错误构建：            exit 偏移 00000000000005a8
```

## 3. 修复

给内核树打补丁（`kernel-src/patches/0001-arm64-mod_arch_specific-add-GKI-KCFI-fields.patch`），
让 `struct mod_arch_specific` 与真机一致，然后正常编译即可。

```bash
patch -d /root/kbuild/kernel -p1 < patches/0001-arm64-mod_arch_specific-add-GKI-KCFI-fields.patch
```

补齐后验证三件事：

1. `.gnu.linkonce.this_module` 段大小仍为 `0x600`（与所有原厂模块一致）；
2. `rela.gnu.linkonce.this_module` 中 `cleanup_module` 的 Offset = `0x5b8`；
3. `strings xxx.ko | grep vermagic` 与 `uname -r` 完全一致。

## 4. 构建环境要点（本项目已验证可用的组合）

- 源码：realme_GT7pro-AndroidV-kernel-source（6.6.89）+ vendor-source，`vendor/`
  目录映射到 `/root/vendor`（`oplus_cpu` 等符号链接依赖它）。
- clang：官方 LLVM 18.1.8（`/root/llvm188`）。Ubuntu clang 18.1.3 也能编过，
  但**不是**崩溃原因；崩溃只与布局有关。
- 配置：直接使用真机 `/proc/config.gz`（`zcat > device_kernel.config`），
  `olddefconfig` 后 `modules_prepare`。gki_defconfig 虽然也能编，但布局以真机
  config 为准更稳妥。
- `Module.symvers`：从真机 `vendor_dlkm.img` 各模块的 `__versions` 段提取 CRC
  （`scripts/extract_vdlkm_crc.sh`），生成 5 列格式（末尾必须有 tab）：
  `0xCRC\tSymbol\tvmlinux\tEXPORT_SYMBOL\t`。
- vermagic 覆盖：`modules_prepare` 之后写
  `include/generated/utsrelease.h` 与 `include/config/kernel.release`，
  否则会带上本地 git describe。
- 模块签名不强制（`MODULE_SIG` 有但无 FORCE），未签名模块可加载。

完整脚本：`kernel-src/build_fod_modules.sh`。

## 5. 交付方式

真机已有 SukiSU root，模块用 KernelSU 模块在开机后加载，不动 vendor 镜像：

```text
/data/adb/modules/rmx5010_fod_bridge/
├── module.prop
├── service.sh                  # 等 oplus_bsp_tp_notify 就绪后 insmod
└── rmx5010_fod_bridge.ko
```

仓库对应目录：`kernel-src/ksu-module/`。安装：

```bash
adb push kernel-src/ksu-module /data/local/tmp/
adb shell su -c 'mkdir -p /data/adb/modules/rmx5010_fod_bridge && \
  cp /data/local/tmp/ksu-module/* /data/adb/modules/rmx5010_fod_bridge/ && \
  chmod 0755 /data/adb/modules/rmx5010_fod_bridge/service.sh'
adb reboot
```

验证：

```bash
adb shell su -c 'dmesg | grep op13_fod_bridge; grep op13_fod_bridge /proc/modules'
# 期望：input: op13_fod_bridge as /devices/virtual/input/inputX
#       op13_fod_bridge: active
```

## 6. 排查工具箱（下次再遇到"模块一装就崩"）

1. **先确认是不是只有自编模块崩**：挑一个未加载的原厂模块 insmod
   （如 `/vendor_dlkm/lib/modules/llcc_perfmon.ko`）。原厂能装 = 构建产物问题。
2. **关掉 `panic_on_oops`**（`echo 0 > /proc/sys/kernel/panic_on_oops`），
   让 Oops 只杀进程，dmesg 拿到完整 trace。注意之后 `module_mutex` 已被占死，
   任何 insmod 都会挂起，**测试前必须重启**。
3. **别信 pstore**：本机 `console-ramoops` 内容严重花屏（时间戳都乱），读不出主 panic。
4. **hello world 二分**：20 行模块就能复现的，不要再往业务代码里找。
5. **直接读真机内核**：`dd if=/dev/block/by-name/boot_a` → boot v4 header
   （kernel 在 offset 4096，长度 = header 里 kernel_size），拿 Oops 的 `Code:` 字节
   去镜像里搜，可定位到确切函数并反汇编，比猜偏移快得多。
6. **比对重定位**：`llvm-readelf -r` 对比自编 .ko 与原厂 .ko 的
   `this_module` 偏移，是发现布局差异的最快手段。
