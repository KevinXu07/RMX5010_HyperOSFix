# 第三方来源说明 / THIRD_PARTY_NOTICES

本仓库包含来自不同来源的文件。它们**不是**同一个授权体系下的产物，请按下表理解每一项的来源与权利归属。

## 1. `patches/xiaomi-account/payload/`

小米账号 HAL 依赖文件集，取自第三方移植社区流传的 "8elite 米账号依赖补全包"（原文件：`骁龙8elite.zip`，作者署名 `tejat`，2025-11；包内说明称提取自小米 15 Ultra / xuanyuan，HyperOS3 / Android 16，并在 Realme GT8 Pro 上测试通过）。

- 本仓库**原样保留**这些二进制文件（未修改字节），并额外记录其应用方式与验证结果。
- 原始说明与上下文清单保留在 `upstream/`（`8elite_usage-用法.txt`、`8elite_odm_context.txt`、`8elite_vendor_context.txt`）。
- 文件本身是小米（Xiaomi）ROM 的组件，**版权归小米所有**；此处仅用于机型移植的技术交流与个人使用。若你是权利人并希望下架，请提 issue。

## 2. `patches/xiaomi-account/selinux/*.cil`

SELinux 策略片段。mtd 块由本项目从**本机已验证的 OS3 策略**中提取并按 RMX5010 基线核对；misys/hypsys 块形态同源。策略语言为 Android SELinux CIL，属 AOSP 约定，无第三方代码依附。

## 3. `docs/历史验证记录_OS3小米账号.md`

摘录自本项目工作区内的 OS3 阶段排障记录（自研），保留设备实测证据链。

## 4. 参考项目与派生代码

[Maga-King/OP13HyperOSFix](https://github.com/Maga-King/OP13HyperOSFix)：一加 13 的澎湃移植 LSPosed 修复模块。本仓库的组织方式（README 结构、`docs/`、`upstream/`、来源说明）参考该项目。

以下内容是在其基础上派生/移植的，不是本仓库原创：

- `lsposed-src/native/lhdc_patch.cpp`：LHDC V5 软件编码器桥接，来自该项目
  `app/src/main/cpp/lhdc_patch.cpp`；仅修改 JNI 符号名、日志 tag、包名相关路径。
- `lsposed-src/libs/arm64-v8a/liblhdcv5.so`、
  `liblhdcv5BT_enc.so`：LHDC/Savitech 编码器二进制，来自该项目
  `app/src/main/jniLibs/arm64-v8a/`，本仓库原样保留。
- `MiChargeHooks.java`、`MiChargeFrameworkBridge.java`、
  `MiChargePresentationHooks.java`、`SecurityCenterTimeHooks.java`：从该项目的
  MiCharge/手机管家实现移植，按 RMX5010 的包名、scope 和实际可用类名适配。
- ColorOS 钱包移植使用同一作者的 `COS-WALLET-FIX` v0.11.0：LSP 兼容模块
  `COS_WALLET_FIX_v0.11.0.apk`，以及 release 包内的 FinShellWallet、TasWallet、
  HeytapHTMS、UPTsmService、EidService APK。模块 1.7.1 起这 5 个 APK 随模块
  zip 分发（`kernel-src/ksu-module/installer/wallet/`，取自
  `ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip`，
  SHA-256 `a8ecb7a9795c310440844c805d4344de35915211b3b824e88908f1cae033da56`，
  字节未修改）；`scripts/install_cos_wallet.sh` 仍可按同一 SHA-256 从上游
  release 下载同一套文件。第三方 APK/JAR/SO 的版权归原权利人，不随本仓库的
  MIT/项目授权改变。
- `IfaaHooks`、触感兼容层和 SELinux 处理思路参考了该项目的对应实现，
  代码已按 RMX5010 的包名、AIDL 签名、HAL 域名和马达特性重写。

该项目包含 HyperCeiler 派生内容，遵循 AGPLv3；上述派生文件的使用/再分发
请同时遵守上游项目与 Savitech 的授权。该项目的完整工程请直接从上游获取。

## 5. 参考项目：VioletToolBox

[Smart-Paocai/VioletToolBox](https://github.com/Smart-Paocai/VioletToolBox)（GPL-3.0）：
欧加（OPPO/一加/真我）线刷工具。本项目只参考其线刷**流程设计**（
`VioletToolBox/oujiaflash.cs` 的普通线刷与「强力线刷」流程），未复制 C# 代码。

据此重写的脚本：`out/full_image_haotian/flash_os4_rmx5010_haotian_54part.bat`、
`flash_device_check.ps1`。采纳与未采纳的细节见
`docs/欧加线刷流程参考_VioletToolBox.md`。

## 6. 模块自带安装器分发的组件

`kernel-src/ksu-module/installer/` 随模块 zip 分发以下第三方 release，安装模块时
由 `install.sh` 部署到设备（已安装则跳过）：

- `LSPosed-v2.2.1-7912-release.zip`：LSPosed 2.2.1 (7912) 官方 release，
  GPL-3.0，<https://github.com/LSPosed/LSPosed>
- `zygisknext-1.5.2.zip`：ZygiskNext 1.5.2 (864-a4a72ce-release) 官方 release，
  GPL-3.0，<https://github.com/Dr-TSNG/ZygiskNext>
- `Sense-1.41.apk`：Sense 1.41 的 release 签名构建（`CN=Sense, OU=RMX5010,
  O=zephiel`；在已测试的 1.38 基础上只新增相机 `CameraDeferHooks`，
  让 APS 延迟拍照任务在前台执行）
- `wallet/*.apk`：ColorOS 钱包 5 件套（FinShellWallet、TasWallet、HeytapHTMS、
  UPTsmService、EidService），来自 `Maga-King/COS-WALLET-FIX` v0.11.0 的
  `ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip`
  （SHA-256 `a8ecb7a9795c310440844c805d4344de35915211b3b824e88908f1cae033da56`），
  安装模块时由 `install.sh` 装成普通用户应用

这些文件按上游发布原样保留，未修改其代码；分发时请同时遵守各自的 GPL-3.0 条款
（提供对应源码的获取方式）。

## 7. 其它

- 仓库内的脚本与文档由本项目编写；**授权方式由仓库所有者决定**（如需开源发布，请自行添加 `LICENSE`）。
- 不包含任何私钥、签名材料或设备唯一标识。刷机脚本中出现的序列号占位符请替换为你自己的设备。

