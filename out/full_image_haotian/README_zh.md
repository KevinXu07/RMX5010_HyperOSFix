# RMX5010 haotian OS4.0.0.19 全量镜像包（54 分区）

这是从原厂 ColorOS 首次刷入本移植系统用的完整镜像包，共 54 个分区镜像。
适用于真我 GT7 Pro / RMX5010，bootloader 已解锁，原厂底包 16.0.7.201。

## 来源

- 23 个移植分区：从当前已验证的 haotian OS4.0.0.19.XOBCNXM 实机回读，
  包含当前所有已验证的移植修复。
- `system_ext` 的 `Settings.apk` 已换回**原厂签名版**（MIUI 平台证书验签通过），
  避免 `-w` 后 PMS 首次扫描验签失败导致设置消失；
  `images/system_ext.img` SHA-256 `08c0e163…`。
- `product` 以相机终版 `27108e…` 为底，仅把
  `overlay/DevicesOverlay.apk` 与 `DevicesAndroidOverlay.apk` 换回 donor
  原厂签名版（灵动岛几何改由 Sense hook 控制）；
  `images/product.img` SHA-256 `b1c8b190…`。
- 31 个固件分区：RMX5010 原厂 16.0.7.201 固件（与 V9 包同源，未改动）。
- `images/init_boot.img` 为原厂 stock 版本；刷机脚本实际刷
  `optional/init_boot_sukisu.img`（带 SukiSU Root），`optional/` 内附
  SukiSU 管理器 APK。

## 54 个分区

**脚本会刷的 23 个移植分区：**

- bootloader 阶段（8）：
  `vbmeta`、`vbmeta_system`、`vbmeta_vendor`、`boot`、`vendor_boot`、
  `init_boot`、`dtbo`、`recovery`
- fastbootd 阶段（15）：
  `my_engineering`、`my_carrier`、`my_region`、`my_manifest`、
  `my_bigball`、`my_heytap`、`my_product`、`my_stock`、`vendor`、`odm`、
  `system_dlkm`、`vendor_dlkm`、`system`、`system_ext`、`product`

**脚本默认不刷的 31 个原厂固件分区（保留用于完整性和回滚）：**

`abl`、`aop`、`aop_config`、`bluetooth`、`cpucp`、`cpucp_dtb`、`devcfg`、
`dsp`、`engineering_cdt`、`featenabler`、`hyp`、`imagefv`、`keymaster`、
`modem`、`oplus_sec`、`oplusstanvbk`、`pdp`、`pdp_cdb`、`pvmfw`、`qupfw`、
`shrm`、`soccp_dcd`、`soccp_debug`、`splash`、`spuservice`、`tz`、`uefi`、
`uefisecapp`、`xbl`、`xbl_config`、`xbl_ramdump`

## 刷入前提

- 真我 GT7 Pro / RMX5010，bootloader 已解锁
- 原厂 ColorOS 16.0.7.201（11.F.64_2640）或兼容底包
- Windows 电脑，使用包内 `platform-tools`
- **首次刷入会清除 userdata/cache**，先备份照片、应用和内置存储

## 刷入步骤

1. 确认 `images/` 下有 54 个 `.img`，`metadata/sha256_images.txt` 有 54 行。
2. 双击运行 `flash_os4_rmx5010_haotian_54part.bat`（强力模式见下文）。
3. 脚本会先调用 `verify_package.ps1 -Strict -IncludeSukisu` 校验 54 个镜像，
   任一失败会停止。
4. 输入 `y` 确认后：
   - **设备预检**：读取 product / current-slot / unlocked，核对 8 个启动分区
     是否都在设备分区表里；设备或刷机包不匹配时在写入前停止
   - bootloader 阶段刷 8 个启动分区
   - `fastboot -w` 清除 userdata/cache；失败时自动改用
     `erase userdata` + `erase metadata`
   - 重启到 fastbootd，**清理 COW 快照分区**（虚拟 A/B 残留会占用 super
     空间，导致动态分区扩容失败）
   - 核对 15 个动态分区是否存在、镜像是否大于分区（大于时 fastboot 自动扩容）
   - 按镜像由小到大刷 15 个动态分区
   - `erase frp`（失败可忽略），最后覆盖刷 vbmeta 三件套
5. 刷完手机会停在 fastbootd，脚本不会自动重启；确认无报错后手动重启。
6. 首次开机较慢，等待进入系统。

## 2026-11-02 修复

上一版整包刷完卡第一屏/重启的根因是链式 vbmeta 的 flags 没打上：
`fastboot --disable-verification --disable-verity` 只改顶层 `vbmeta`，
`vbmeta_system` / `vbmeta_vendor` 仍是原厂 flags=0。first-stage 按 fstab 的
`avb=vbmeta_system` / `avb=vbmeta_vendor` 读取 ColorOS 的 hashtree 描述符，
与 port 镜像对不上 → dm-verity 读失败 → 挂载失败 → 重启。

本版三张 vbmeta 已在 offset 120 预置 `0x00000003`，并恢复为已验证的
system / system_ext / product 回读镜像（product = `27108e…`）。

## 动态分区刷写方式

动态分区按 `-S 128M` 分块刷写，保持既有顺序（`my_*` 优先，大 `product` 最后，
避免 `Not enough space to resize partition`）。刷前会清理 COW 快照并逐个核对
镜像与分区尺寸；镜像大于分区时 fastboot 会在刷写时自动扩容，只有 super 空间
不足才会报 `Not enough space to resize partition`，此时用强力模式。

## 强力模式（force）

```
flash_os4_rmx5010_haotian_54part.bat force
```

普通刷写报 `Partition not found`、`Not enough space to resize partition`、
`data too large`，或者 super 逻辑分区丢失时使用。与普通刷写的区别：

- 先 `set_active a` 把启动槽位固定到 A，保证后续写入和启动是同一槽位；
- 在 fastbootd 里先清理 COW 快照，再对**缺失或小于镜像**的逻辑分区执行
  `delete-logical-partition` + `create-logical-partition`（容量取原分区与
  镜像的较大值，向上取整到 MB），然后按普通流程刷写；
- 不会重建健康的分区，未涉及的分区保持原样；
- 需要额外输入 `force` 确认。

思路来自 VioletToolBox 的欧加「强力线刷」（`oujiaflash.cs` 的
`ExecuteForceOujiaFlashWorkflowAsync` / `ExecutePowerFlashProcess`）：先固定
A 槽、清 COW、重建 super 逻辑分区再刷。这里改为只修有问题的分区，避免整表
重建带来的容量偏差。

## 设备预检（flash_device_check.ps1）

刷写脚本会在写入前调用：

- `-Stage bootloader`：product、current-slot、unlocked（明确未解锁直接停止），
  以及 8 个启动分区是否存在（`getvar all` + `partition-type`/`has-slot` 兜底；
  完全读不到分区信息时只告警不拦截）。
- `-Stage fastbootd`：`is-userspace` 必须是 yes；按当前槽位把 15 个分区名解析
  为实际名称（`system` → `system_a`）；镜像不存在或目标分区缺失即停止；
  镜像大于分区时提示自动扩容；`-CleanCow` 清理 `cow*` 逻辑分区。

## 首次开机后

1. 安装 `optional/SukiSU_v4.2.0_40900-release.apk`（Root 管理器）。
2. 安装 `camera_fix/rmx5010_fod_bridge-1.6.9-camera-full.zip`（KSU/Magisk
   模块，versionCode 36）。**不要**直接安装
   `camera_fix/RMX5010_HyperOSFix_1.5.7_share_20261102.zip`——那是分享包，
   不是 KSU 模块，KSU 会报 "specific file not found in archive"。
3. 安装 LSPosed 框架（本包未提供），再安装
   `camera_fix/Sense-1.38.apk`（本次新增：人脸录入修复 +
   灵动岛 74px / 状态栏 padding 14px）。
4. LSPosed 作用域至少勾选 `com.android.settings`、`com.android.systemui`
   （相机、钱包等原有作用域照旧），重启。
5. 相机、星空、多景、相册桥接、触感、人脸录入、灵动岛修复才会完整生效。
   未启用 Sense 前，灵动岛为 donor 默认位置、人脸录入可能卡在进度环（预期）。

## 警告

- 不要刷到其他机型、其他底包或未解锁 bootloader 的机器。
- 不要在 bootloader 阶段刷动态分区；不要在 fastbootd 阶段动
  `xbl/aop/hyp/tz/abl/keymaster/modem` 等固件分区。
- 31 个固件镜像默认不刷，只有回滚/修复固件时才单独刷。
- 三个 `vbmeta` 已**预先**写入 flags=0x3（验证和 hashtree 都已禁用），刷机脚本直接普通刷入。
  不要换回未打 flags 的原厂 vbmeta；也不要依赖 `fastboot --disable-verification`——
  它只对名字以 `vbmeta` 结尾的分区生效，`vbmeta_system` / `vbmeta_vendor` 不会被改。
  `verify_package.ps1` 会在刷前断言三张都是 flags=3。
- 镜像哈希以 `metadata/sha256_images.txt` 为准；校验失败禁止刷入。
- 本包是 haotian OS4.0.0.19 底包；nezha OS4.0.2.0 的镜像不能混用。

## 文件结构

```
images/                 54 个分区镜像
metadata/PARTITIONS_54.txt
metadata/sha256_images.txt
optional/init_boot_sukisu.img
optional/SukiSU_v4.2.0_40900-release.apk
camera_fix/RMX5010_HyperOSFix_1.5.7_share_20261102.zip
camera_fix/rmx5010_fod_bridge-1.6.9-camera-full.zip
camera_fix/Sense-1.38.apk
camera_fix/README_FIRST_zh.txt
platform-tools/
verify_package.ps1
flash_device_check.ps1
flash_os4_rmx5010_haotian_54part.bat
README_zh.md
```
