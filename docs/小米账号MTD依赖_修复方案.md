# 小米账号 / MTD 依赖闭包（RMX5010 × nezha OS4）

> 状态：**离线验证通过，待实机验证**（2026-10-16）
> 载体：`odm.img` + `vendor.img`（其余 52 张镜像不动）

## 1. 症状链

移植系统能开机、能过大部分开机引导，但**卡在小米账号 / 开机引导（Provision）**：

```
小米账号向导点击"同意并继续" → 前台 ANR → 进程被杀 → 退回开机引导首页
```

从日志抓到的实际因果链（OS3 阶段实机确认，见 [历史验证记录](历史验证记录_OS3小米账号.md)）：

```
mtd storage HAL 缺席（AIDL 未注册）
  → FindDevice 全局锁不释放（每秒重试持久化存储服务）
  → content://com.xiaomi.finddevice.provider 查询不返回
  → Provision 主线程等待 5000ms 超时 ANR
  → TermsAndStatementActivity 失焦 → 系统杀进程 → 回首页
```

## 2. 根因

`/odm/bin/mtd` 的 inode 标签指向的策略类型**在最终加载的策略里不存在**，内核在策略加载时直接报：

```
SELinux: Context u:object_r:hal_mtdservice_default_exec:s0 is not valid (left unmapped).
```

后果：init 无法按 native 域启动 mtd → mtd 的 AIDL 服务 `vendor.xiaomi.hardware.aidl.mtdservice.IMTService/default` 永不注册 → 上面的链条成立。

也就是说：**文件在不在不重要，"标签 + 域 + 服务注册 + 属性读写"这一整套闭包在不在才重要。**

## 3. 闭包内容（本仓库落地的形态）

### 3.1 载荷文件

来自社区 8elite 依赖包（提取自小米 15 Ultra / xuanyuan，作者标注在 Realme GT8 Pro 测试通过）：

| 分区 | 新增 | 内容 |
|---|---|---|
| `odm` | 23 | `bin/{mtd,idmanager,mlipayd,fidoca,vendor.xiaomi.hardware.mikeybag-service}`、5 个 rc、5 个 vintf manifest、8 个库（libmt/libsecid/libwvkeybox/libmfido/libmlipay/libidprovision/idmanager-ndk/mikeybag-impl） |
| `vendor` | 18 | `bin/hw/vendor.xiaomi.hardware.misys.core-service`、`bin/hypsys_vendor`、2 个 rc、2 个 manifest、12 个库（misys/misight/mtdservice-ndk/blackbox/mfidoca/mikeybag/mlipay/hypsys-common/keymaster…） |
| `vendor`（本仓库补） | 1 | `etc/vintf/manifest/vendor.xiaomi.hardware.blackbox.xml` —— 原包缺失，但 `hypsys_vendor` 运行时必需（没有它 blackbox 未在 VINTF 里，misys 返回 `STATUS_BAD_VALUE(-3)`） |

**目标原厂已有的 11 个库不覆盖**（`libkeymaster*`/`libmink*`/`liboemcrypto`/`libesesbprovision`/`libqtikeymaster4`/`vendor.qti.hardware.minkipcbinder`）：原包用法明确要求"重复文件点跳过"，这些是 QTI/realme 自己的版本，替换会引入 ABI 风险。

### 3.2 标签（关键：不要照抄原包的"万能域"）

8elite 原包用法要求把**所有路径**都标成 `hal_allocator_default_exec`。这套在 RMX5010 上**已被证伪**：strict 用法版刷入后卡第一屏。原因是 RMX 基线里的 `libbase`/`libcutils` 等共享库带 `same_process_hal_file` 之类专用标签，不能改；且 `hal_allocator_default` 域在本机型策略里没有服务注册路径。

本仓库采用**分级标签**：

| 路径 | 标签 |
|---|---|
| `/odm/bin/mtd` | `hal_mtdservice_default_exec` |
| `/vendor/bin/hypsys_vendor` | `hal_misys_vendor_default_exec` |
| `/vendor/bin/hw/vendor.xiaomi.hardware.misys.core-service` | `hal_misyscore_default_exec` |
| `/odm/bin/{idmanager,mlipayd,fidoca,mikeybag-service}` | `vendor_file`（无专用域 → 不启动；与 OS3 实机验证状态一致，不影响账号链路） |
| 所有新增 `.so` | `vendor_file` |
| 所有新增 `rc` / `vintf manifest` | `vendor_configs_file` |
| `/odm/etc/selinux/odm_file_contexts`（新建） | `file_contexts_file` |

完整清单见 [`patches/xiaomi-account/labels.tsv`](../patches/xiaomi-account/labels.tsv)。

### 3.3 SELinux 策略

在 `vendor/etc/selinux/vendor_sepolicy.cil`（以及 debug 变体）末尾追加两个块：

- [`misys_hypys_block.cil`](../patches/xiaomi-account/selinux/misys_hypys_block.cil)：`hal_misys_vendor_default`、`hal_misyscore_default` 域 + 服务类型 + init 迁移 + binder 规则
- [`mtd_block.cil`](../patches/xiaomi-account/selinux/mtd_block.cil)：`hal_mtdservice_default` 域 + `hal_mtdservice_service` 服务类型 + `vendor_payment_security_prop`/`vendor_cpuid_prop`/`vendor_deviceid_prop`/`ta_data_file` 属性与文件类型 + 该 HAL 需要的设备访问（TEE/qce/ion/停用 persist 目录等）

**不需要**重新生成 `odm/etc/selinux/precompiled_sepolicy`：本机型在启动时会从 `.cil` 源重新编译策略（OS3 实证：其 odm 的 `precompiled_sepolicy` 里没有这些域，但运行期域是活的）。改 `.cil` 后对应的 `*.sha256` 旁文件自然不匹配，正好触发重编译路径。

追加前应做离线校验（见 `scripts/verify` 与规范文档）：

```bash
secilc -m -M true -G -N -c 30 \
  <plat_sepolicy.cil> <mapping/202404.cil> <mapping/202404.compat.cil> \
  <vendor/plat_pub_versioned.cil> <system_ext_sepolicy.cil> <product_sepolicy.cil> \
  <vendor_sepolicy.cil(mod)>
```

### 3.4 服务与属性上下文

- `vendor_service_contexts` +5：

```
vendor.xiaomi.hardware.blackbox.IBlackboxImpl/default        → hal_misys_vendor_service
vendor.xiaomi.hardware.misys.common.IHypSysIntl/default      → hal_misys_vendor_service
vendor.xiaomi.hardware.misys.common.IMiSysImpl/default       → hal_misys_vendor_service
vendor.xiaomi.hardware.misys.core.IMiSysCore/default         → hal_misyscore_service
vendor.xiaomi.hardware.aidl.mtdservice.IMTService/default    → hal_mtdservice_service
```

- `vendor_property_contexts` +34（`vendor_payment_security_prop` / `vendor_deviceid_prop` / `vendor_cpuid_prop`：`odm.security.*`、`persist.vendor.sys.*`、`ro.vendor.oem.*` 等）
- `vendor_file_contexts` +21，其中两条是**运行时目录映射**（mtd 自身要读写）：

```
/data/vendor/images(/.*)?        u:object_r:ta_data_file:s0
/mnt/vendor/persist/fdsd(/.*)?   u:object_r:vendor_persist_drm_file:s0
```

## 4. 镜像重建参数（必须与原厂一致）

```bash
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/odm    --file-contexts=<full> out/odm.raw.img    stage/odm
mkfs.erofs --quiet -zlz4 -C262144 -b4096 -T0 --mount-point=/vendor --file-contexts=<full> out/vendor.raw.img stage/vendor
```

- `-C262144`（big pcluster）与原厂 odm/vendor 的 superblock 特征一致；
- `--file-contexts` 必须 **100% 覆盖**（目录 + 文件 + 符号链接），生成方式见规范文档；
- 详细陷阱见 [SELinux闭包与EROFS重建规范](SELinux闭包与EROFS重建规范.md)。

## 5. 离线验证证据（2026-10-16）

在目标基线 `odm.img`/`vendor.img`（16.0.7.201）上执行：

| 检查 | 结果 |
|---|---|
| 注入文件标签 | 24（odm）+ 19（vendor）全部符合 `labels.tsv`，0 处不符 |
| 全量差分 | odm：+24 文件 / -0 / 常规文件变更 0；vendor：+19 / -0 / 常规文件变更 5（**仅** 4 个 selinux 上下文/策略文件 + 1 个 debug 变体） |
| 符号链接 | odm 3 条、vendor 296 条，目标全部一致 |
| 目录 | 模式/属主全部一致（仅目录尺寸随新增文件变大） |
| `security.capability` | vendor 基线 9 个文件的能力 xattr 全部保留 |
| 策略编译 | `secilc` Android 运行时模式通过；严格 neverallow 输出与基线逐行一致（无新增冲突） |
| sparse 结构 | `simg2img` 回读与 raw 逐字节一致 |
| 镜像哈希 | `odm.img` `3a90d956…`、`vendor.img` `dc491842…` |
| 包校验 | `verify_package.ps1 -Strict` 54/54 通过 |

## 6. 实机验证清单（待做）

```bash
# 刷入 odm+vendor 后
adb shell su -c 'dmesg | grep -iE "not valid|avc denied" | tail -40'
adb shell su -c 'ps -A -Z | grep -E "mtd|hypsys|misys"'
adb shell su -c 'service list | grep -iE "mtdservice|misys|blackbox"'
adb shell 'dumpsys dropbox --print | grep -i cne'      # 顺带核对信号掉线的另一可能病因
# 然后走一遍小米账号向导：同意协议 → 应能进入下一步，不再退回首页 / 不再前台 ANR
```

## 7. 残余风险与未闭环

- `mfidoca` / `mlipay` / `idmanager` / `mikeybag` 四个辅助 HAL 没有专用域（本机型策略里不存在），**不会启动**。它们服务于支付/FIDO/KeyBag 等场景；如后续需要，应按 `mtd_block.cil` 的形态各自补域，并逐项实机验证。
- 本修复解决的是**账号依赖的 native 服务链**。TZ 凭证层（Realme QTEE 拒绝小米 trustlet）导致的查找设备/小爱门槛问题属于另一条链，需要 LSPosed 侧方案（见状态矩阵），两者互相独立。
- 换底包（donor 或 target 版本变动）后需重新推导：类型后缀（如 `_202404`）、`plat_pub_versioned.cil`、`mapping/*.cil` 都可能变化。
