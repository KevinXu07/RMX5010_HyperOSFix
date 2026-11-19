# RMX5010 haotian OS4.0.4.0 全量镜像包（54 分区）

这是从原厂 ColorOS 首次刷入本移植系统用的完整镜像包，共 54 个分区镜像。
适用于真我 GT7 Pro / RMX5010，bootloader 已解锁，原厂底包 16.0.7.201。

## 来源

- `system` / `system_ext` / `product`：小米 15 Pro（haotian）**OS4.0.4.0.XOBCNXM**
  正式版（Android 17），payload SHA-256 `536dfc9b…`。按 OS4.0.0.19 包的同一套
  改动重新构建，逐项对照 0.19 包实机回读核对过（改动清单见仓库
  `docs/镜像改动总表.md`）：
  - system：mi_ext 合并、去掉 Nfc_st、TeleService 信号补丁（3 处，原签名块拼回）、
    RMX 原厂 MTP rc、注入 XMNfcNci；
  - system_ext：miui-services.jar 指纹硬件检测桩；Settings 保持**原厂签名版**；
  - product：DPI 500、NFC/刷新率/FOD 属性、`haotian.xml` 刷新率与屏下指纹开关、
    本机亮度曲线、指纹特性声明、OplusCamera 预置（替换 MiuiCamera）；
    两个 Devices overlay 为补丁版（按 zipalign 对齐、拼回原厂签名块）。
  - **模块静态部分已合入镜像**（2026-11-17）：原来 KSU 模块开机时挂载/注入的
    相机移植（OplusCamera 6.070.45、系统库、cameraserver、桩应用、SELinux 映射）、
    音频卡顿补丁、亮度曲线、QESDK/微信修复、相关属性和 SELinux 规则，以及
    millet / FOD 桥内核模块（由 vendor rc 加载）都已在镜像里；
    product `build.prop` 带 `ro.rmx5010.image_merge=1`，模块 1.7.27+ 据此跳过这些步骤。
  - 第二批：触控报点率配置、ColorOS 钱包 5 件套（预装，免安装）、GMS 推送不被
    息屏冻结（微信/QQ 进白名单），以及相册桩 1.3——相机点缩略图不装 Sense 也能
    跳到小米相册。
  - 三个镜像与 0.19 包共有的路径，SELinux 标签全部一致。
- `odm` / `vendor`：OS4.0.0.19 包（原厂底 + 账号闭包、身份、LTPO、指纹等修复）
  加上从模块合入的相机库与配置、微信修复、QESDK seccomp、内核模块与 rc，
  原有文件的属主、权限、SELinux 标签逐一核对不变。
- 其余 49 个分区与 OS4.0.0.19 包**逐字节相同**：8 个精简 `my_*`、`vbmeta` 三件套
  （flags=3）、31 个 RMX5010 原厂 16.0.7.201 固件分区以及原厂
  boot / vendor_boot / init_boot / dtbo / recovery / system_dlkm / vendor_dlkm。
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

### 检测到 fastbootd 后报“没有唯一的 fastboot 设备”

bootloader 切到 fastbootd 时 USB 会重新枚举，设备可能短暂从 `fastboot
devices` 里消失。脚本现在会**重试 10 次（约 20 秒）**，并且把实际检测结果打印
出来（`[设备] 当前 fastboot 设备数：N`，多台时列出序列号）：

- 显示 0 台：换 USB 口/数据线，确认手机停在 fastbootd 界面，关掉其它占用
  fastboot 的程序后重跑；仍然 0 台时会提示 `fastboot devices 执行失败`，
  说明是驱动或 USB 问题。
- 显示多台：只保留目标手机（拔掉其它手机、关掉其它 fastboot 窗口）后重跑。

这个提示不会改动手机：脚本在写动态分区之前就停下了，重跑即可（会重新执行
bootloader 阶段和 `-w`，数据本来就是清的）。

## 首次开机后

1. 安装 `optional/SukiSU_v4.2.0_40900-release.apk`（Root 管理器），重启一次。
2. 安装 `camera_fix/rmx5010_fod_bridge-1.8.2-lite.zip`（KSU 精简模块，versionCode 68，
   只能装在本整包上）。镜像已带模块静态部分和 ColorOS 钱包补丁版，精简模块只负责
   镜像里还没有的修复（屏下指纹/锁屏、抬手亮屏、AOD、计步、IFAA、蓝牙 LHDC、
   双卡数据切换、相机细节等 Sense 修复，以及触控报点率、推送等运行时设置）。
   模块自带安装器，会自动部署 ZygiskNext 1.5.2、LSPosed 2.2.1 (7912)、
   Sense 1.60（已安装的跳过），并把 Sense 的 LSPosed 作用域直接写进 LSPosed 配置
   （不含钱包、NFC、SE、小米 TSM、eID，这些进程在镜像里已是补丁版）。安装完成后重启一次；如果本次新装了
   LSPosed，首次开机后模块会自动补注册作用域，再重启一次即可。
3. `camera_fix/Sense-1.60.apk` 与模块内置的是同一个文件，只在需要单独安装时用。
   手机上已有 debug 签名的 Sense 时不能覆盖安装，需要先卸载 `com.zephiel.sense`。
4. 详细说明见 `camera_fix/README_FIRST_zh.txt`。未启用 Sense 前，灵动岛为
   donor 默认位置、人脸录入可能卡在进度环（预期）。

失败时模块会把对应的包复制到 `/sdcard/Download/rmx5010_installer/`，
安装日志在 `/data/local/tmp/rmx5010_installer.log`。

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
- 本包是 haotian OS4.0.4.0 底包；OS4.0.0.19 包和 nezha OS4.0.2.0 的 system / system_ext / product 镜像不能混用。

## 第三方组件与授权

- `optional/SukiSU_v4.2.0_40900-release.apk`：SukiSU 项目发布版，版权归其作者。
- `camera_fix/Sense-1.60.apk`：Sense 项目提供的 LSPosed 模块，版权归其作者；
  本包中的副本用 `CN=Sense, OU=RMX5010, O=zephiel` 的 release 密钥签名。
- 模块 zip 内 `installer/` 打包了 LSPosed 2.2.1 (7912) 与 ZygiskNext 1.5.2
  的官方 release，二者均为 GPL-3.0，源码见各自仓库
  （<https://github.com/LSPosed/LSPosed>、<https://github.com/Dr-TSNG/ZygiskNext>）。
- 镜像内预装的 ColorOS 钱包 APK 基于 `Maga-King/COS-WALLET-FIX` v0.11.0 的
  release 包（`ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip`，
  SHA-256 a8ecb7a9…33da56），为适配本机做了 dex 补丁，版权归原权利人。
- `images/` 中的原厂分区、镜像内的 OplusCamera 与系统库来自
  对应原厂 / 移植源，版权归原权利人；本包仅用于同机型个人移植与修复交流，
  请勿用于商业分发。

## 文件结构

```
images/                 54 个分区镜像
metadata/PARTITIONS_54.txt
metadata/sha256_images.txt
optional/init_boot_sukisu.img
optional/SukiSU_v4.2.0_40900-release.apk
official_vbmeta/        原厂 vbmeta 三件套（先在 bootloader 刷入以进入 fastbootd，收尾时覆盖为 flags=3 版本）
camera_fix/rmx5010_fod_bridge-1.8.2-lite.zip
camera_fix/Sense-1.60.apk
camera_fix/README_FIRST_zh.txt
platform-tools/
verify_package.ps1
flash_device_check.ps1
flash_os4_rmx5010_haotian_54part.bat
README_zh.md
```
