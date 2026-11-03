# 整包刷机 bootloop 根因：链式 vbmeta 的 flags 没被打上

日期：2026-11-02

现象：按 54 分区包刷完后，亮第一屏（realme logo）→ 黑屏 → 重启，循环若干次后落到 fastboot；
同一台机器刷回 ColorOS 201 原厂包可以正常开机。

## 结论

`fastboot --disable-verification --disable-verity flash <分区>` **只会给分区名以 `vbmeta` 结尾**的目标改 flags。
fastboot 源码（`system/core/fastboot/fastboot.cpp`）：

```cpp
static bool is_vbmeta_partition(const std::string& partition) {
  return android::base::EndsWith(partition, "vbmeta") ||
         android::base::EndsWith(partition, "vbmeta_a") ||
         android::base::EndsWith(partition, "vbmeta_b");
}
...
uint64_t flags_offset = 123 + vbmeta_offset;
if (g_disable_verity) { data[flags_offset] |= 0x01; }
if (g_disable_verification) { data[flags_offset] |= 0x02; }
```

`vbmeta_system` 以 `system` 结尾、`vbmeta_vendor` 以 `vendor` 结尾，**都不匹配**。
所以 `fastboot --disable-verification --disable-verity flash vbmeta_system vbmeta_system.img`
实际是**原样刷入**，flags 仍然是 `0x0`。

## 为什么这会导致卡第一屏

stock vendor_boot 内的 `first_stage_ramdisk/fstab.qcom`（已解包核对）：

```
system      ... avb=vbmeta_system, logical, first_stage_mount
system_ext  ... avb=vbmeta_system, logical, first_stage_mount
product     ... avb=vbmeta_system, logical, first_stage_mount
vendor      ... avb=vbmeta_vendor, logical, first_stage_mount
vendor_dlkm ... avb=vbmeta,        logical, first_stage_mount
system_dlkm ... avb=vbmeta,        logical, first_stage_mount
```

first-stage init 通过 `avb=vbmeta_system` / `avb=vbmeta_vendor` 读取**链式 vbmeta 自己的**
hashtree 描述符。原厂三件套 flags=0，描述符里是 ColorOS 201 的尺寸：

- `vbmeta_system`：system 972,681,216 / system_ext 1,137,422,336 / product 9,031,680
- `vbmeta_vendor`：vendor 645,877,760

port 镜像的尺寸/内容完全不同（system 972,824,576、system_ext 804,081,664、product 4.3G、
vendor 682,934,272），也没有对应偏移的 hashtree。dm-verity 建立后第一次读 superblock 就 EIO，
mount 失败，init panic → 重启。正好对应“亮 logo 后黑屏重启、连开机动画都看不到”。

顶层 vbmeta 打 flags=3 只跳过顶层描述符（boot/vendor_boot/init_boot/dtbo/recovery 以及
system_dlkm/vendor_dlkm 的 hashtree），**不会改链式 vbmeta 自己的 flags**。

## 离线验证

- `images/vbmeta*.img` 原为 stock201 原厂文件，flags 均为 `0x0`（offset 120，大端 u32）。
- 刷机脚本第 5 步只把顶层 `vbmeta` 打成了 `0x3`；`vbmeta_system` / `vbmeta_vendor` 仍为 `0x0`。
- `readback_vbmeta/` 里的 65K 三件套其实是手写 avboff（release string
  `haotian_port_h19 avboff`，flags=3，无描述符），不是设备回读。

## 修复

三张图预先在 offset 120 写 `0x00000003`，然后**普通刷入**（不带任何 fastboot 后缀参数）：

| 镜像 | 大小 | flags | SHA-256（前 16 位） |
|---|---|---|---|
| images/vbmeta.img | 12,288 B | 0x3 | a32f25f5de5c3600 |
| images/vbmeta_system.img | 4,096 B | 0x3 | 2cad200cfc68526c |
| images/vbmeta_vendor.img | 4,096 B | 0x3 | 773c1b4f4c174896 |

- 刷机脚本第 5 步改为直接刷这三张预置图。
- `verify_package.ps1` 在刷前断言三张图的 flags==3，不通过直接拒绝刷入。
- avboff 空头三件套同样是 flags=3，可作备份方案（D8 已验证能开机）。

## 注意

- flags=3 会使 vbmeta 签名失效；解锁 bootloader 下 libavb 先读 flags 再决定是否验签，因此可用。
- 不要只改顶层 `vbmeta`；三张必须都改。
- 这与“官方 vbmeta + 后缀参数”的直觉相反：后缀只作用于名字以 `vbmeta` 结尾的分区。
