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
  HeytapHTMS、UPTsmService、EidService APK/原生库。它们**不在本仓库内**，
  由 `scripts/install_cos_wallet.sh` 按 SHA-256 从上游 release 下载。第三方
  APK/JAR/SO 的版权归原权利人，不随本仓库的 MIT/项目授权改变。
- `IfaaHooks`、触感兼容层和 SELinux 处理思路参考了该项目的对应实现，
  代码已按 RMX5010 的包名、AIDL 签名、HAL 域名和马达特性重写。

该项目包含 HyperCeiler 派生内容，遵循 AGPLv3；上述派生文件的使用/再分发
请同时遵守上游项目与 Savitech 的授权。该项目的完整工程请直接从上游获取。

## 5. 其它

- 仓库内的脚本与文档由本项目编写；**授权方式由仓库所有者决定**（如需开源发布，请自行添加 `LICENSE`）。
- 不包含任何私钥、签名材料或设备唯一标识。刷机脚本中出现的序列号占位符请替换为你自己的设备。
