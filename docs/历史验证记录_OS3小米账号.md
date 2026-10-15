# 历史验证记录：OS3 小米账号闭包（设备实测证据链）

本文件摘录自 OS3 阶段（RMX5010 + ColorOS 16.0.9.400 硬件底 + 小米 OS3 用户空间）的实机排障记录，是当前 nezha 主线账号修复方案的**依据**。原始记录在项目工作区 `os3_v5_final_xiaomi_account_20260823/docs/OS3_v5小米账号SELinux修复_20260822.md`。

## 1. 实机二分结论（8elite 原包用法被证伪）

| 试验 | 结果 |
|---|---|
| 严格按 8elite 用法：**所有路径** `hal_allocator_default_exec` | **卡第一屏**（不能原样套到 RMX5010） |
| 安全标签版：库 `vendor_file`、rc/xml `vendor_configs_file`、服务二进制专用域 | 可开机；`hypsys_vendor` 在 `hal_allocator_default` 下缺库/缺 `libcutils` |
| 完整 vendor ELF 闭包 allocator 版 | 卡第一屏（RMX 的 `libbase`/`libcutils` 含 `same_process_hal_file` 等基线专用标签，不能改） |
| native-minimal v2 | 可开机；`misys core` 常驻注册；`hypsys_vendor` 因 blackbox 未列入 VINTF 返回 `STATUS_BAD_VALUE(-3)` |
| native-minimal v3（+blackbox manifest） | 可开机；`hypsys_vendor` 常驻，三个 vendor AIDL 全部注册 |
| **v21e / mtd 最小策略（只补 mtd 域）** | **可开机、SELinux Enforcing、mtd 域 `u:r:hal_mtdservice_default:s0`、 AIDL 注册并收到真实调用、Provision 正常进入下一步、用户确认引导不再卡死** |

## 2. 关键把柄：策略确实会被"未映射"

```
SELinux: Context u:object_r:hal_mtdservice_default_exec:s0 is not valid (left unmapped).
SELinux: Context u:object_r:hal_mfidoca_default_exec:s0 is not valid (left unmapped).
SELinux: Context u:object_r:hal_mlipay_default_exec:s0 is not valid (left unmapped).
```

这些告警出现在**只补了 misys/hypsys 域、没有 mtd 域**的版本上。OLM 的 mtd 二进制标签指向不存在的类型 → init 无法进入 native 域 → 服务永不注册（`/odm/bin/mtd` 对 shell 也是 Permission denied）。

## 3. 最终根因与闭包（原样引用）

```
最终 v3 vendor 漏 mtd native type
-> /odm/bin/mtd exec context left unmapped
-> mtd AIDL 不注册
-> FindDevice 持锁等待
-> Provision 查询阻塞并 ANR

补 mtd domain/transition/service/property rules
+ /data/vendor/images -> ta_data_file
+ /mnt/vendor/persist/fdsd -> vendor_persist_drm_file
-> mtd 正常运行并注册 AIDL
-> FindDevice 返回
-> Provision 正常完成
```

补充事实：

- 修复仅刷 **vendor** 一张（`os3_v5_xiaomi_mtd_minimal_v1/vendor.img`），ODM 沿用已含 8elite 文件的版本；
- `libmt.so` 与 8elite 包版本逐字节比较只差 GNU Build ID，**无需替换**；
- `mfidoca`/`mlipay`/`idmanager` 当时仍"未映射"，**实测不影响这条成功链**，因此当时结论是"不要再并入当前包"。
- 策略层面：已刷入设备的 `vendor_sepolicy.cil` 哈希与构建输入一致，证明**改 `.cil` 即生效**（设备启动时重编译），而 odm 的 `precompiled_sepolicy` 里并不含这些新域。

## 4. 对 nezha 主线的移植要点

1. 标签分级照搬（mtd/misys/hypsys 专用域；库 `vendor_file`；rc/xml `vendor_configs_file`）。
2. 策略块整段移植，但必须重新核对类型后缀（OS3 是 `_202404`，nezha 底包的 `plat_pub_versioned.cil` 同为 `_202404`，可直接用）。
3. `ta_data_file` 与 `vendor_persist_drm_file` 两条目录映射必须一起带上（mtd 读写 `/data/vendor/images`、`/mnt/vendor/persist/fdsd`）。
4. blackbox manifest 必须补（8elite 包缺）。
5. 完整文件清单与标签表见 `patches/xiaomi-account/labels.tsv`。
