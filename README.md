# RMX5010_HyperOSFix

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的**镜像级修复集**：把小米用户空间拉到 realme 原厂硬件底上跑通，并用最小改动量、可复现、可验证的方式记录每一条修复。

本仓库不是 LSPosed 模块工程，而是**补丁集 + 构建/验证脚本 + 证据文档**。每一条修复都按同一套格式落地：

```
症状签名（logcat / 现象） → 根因 → 载荷（文件 + 标签 + 策略） → 构建脚本 → 验证证据 → 残余风险
```

## 适用范围（先读）

- **仅 RMX5010（realme GT7 Pro）**，目标分区布局 54 张镜像；不要套用到别的机型。
- 修复按**底包版本**对齐。当前主线底包：
  - 硬件底：RMX5010 ColorOS **16.0.7.201**（11.F.64_2640）
  - 用户空间（donor）：小米 **nezha** OS4.0.2.0.XPACNXM（Android 17 / SDK 37）
- 换底包后**必须重新推导 SELinux 闭包**（类型后缀/策略版本都会变），不能直接套用本仓库的 `.cil` 片段。
- 动 vendor / odm 属于高风险操作：本仓库所有脚本都假定 `vendor` 之外的固件分区（xbl/aop/hyp/tz/abl/keymaster/modem…）**永不改写**。

## 当前修复状态

| 修复项 | 载体 | 离线验证 | 实机验证 | 文档 |
|---|---|---|---|---|
| 小米账号 / MTD 依赖闭包 | odm + vendor 重建 | ✅ 标注/差分/策略编译 | ✅ 实机验证通过 | [方案](docs/小米账号MTD依赖_修复方案.md) |
| 查找设备 | 保持 nezha 官方原版（官方 Platform 签名 + 原厂 oat） | ✅ 官方哈希核对 | ✅ 实机验证通过 | [说明](patches/finddevice-notz/README.md) |
| 信号掉线（TeleService XTS + CNE 防崩） | system + vendor 重建（dex 补丁，保签名块） | ✅ dex 往返/差分/结构 | ✅ 实机验证通过 | [补丁](patches/signal-fix/README.md) |
| MTP + DPI 500 | system rc + product build.prop | ✅ 镜像差分 | ✅ 实机验证通过 | [补丁](patches/mtp-and-dpi/README.md) |
| ODM 身份修正（PJA110→Xiaomi/nezha） | odm build.prop 断 import 链 + 写死身份 | ✅ 镜像差分 | ✅ 实机验证通过 | [补丁](patches/odm-identity/README.md) |
| 亮度曲线 + 圆角/状态栏高度 | product（displayconfig XML + DevicesAndroidOverlay） | ✅ 差分/资源核对 | ✅ 实机验证通过 | [补丁](patches/brightness-overlay/README.md) |
| 音频爆音 / 切音"哔"声（appname 截断） | system_ext 重建（libaudiopolicymanagerimpl.so 补丁） | ✅ 差分/反汇编核对 | ✅ 实机验证通过 | [补丁](patches/audio-pop-fix/README.md) |
| 分辨率列表（1.5K/1080p）+ 120Hz 刷新率 | product（nezha.xml + build.prop 动态帧率） | ✅ 差分/XML语法核对 | ✅ 实机验证通过 | [补丁](patches/resolution-and-refresh/README.md) |
| 原生内核级事件驱动 LTPO 降频恢复 | vendor 重建（rmx5010_ltpo_restore.ko + init 原生自启） | ✅ 符号/校验/ELF一致 | ✅ 实机验证通过（lsmod 常驻） | [补丁](patches/resolution-and-refresh/README.md) |
| 相机 P010 厂商格式崩溃修复 | system（libnativewindow.so 扩展分支） | ✅ 差分/反汇编核对 | ✅ 实机验证通过 | [补丁](patches/camera-p010-fix/README.md) |
| NFC 功能（NXP SN220 + Xiaomi 协议栈） | system + vendor + product（XMNfcNci + 策略/属性） | ✅ 服务/属性/策略闭包 | ✅ 实机验证通过（mState=on） | [补丁](patches/nfc-nxp-fix/README.md) |
| SELinux 闭包与 EROFS 重建规范 | — | ✅ | — | [规范](docs/SELinux闭包与EROFS重建规范.md) |
| 分区血缘与刷写顺序 | — | ✅ | ✅（历史包） | [说明](docs/分区血缘与刷机顺序.md) |
| 历史修复（状态栏/灵动岛/相机/信号/音频/NFC/亮度…） | system/product/odm + KSU 模块 | 部分 | 部分 | [状态矩阵](docs/修复清单与状态矩阵.md) |

> 状态列含义：**离线验证** = 可在无设备环境复现的检查（哈希、fsck、标签、策略编译、差分）；**实机验证** = 真机回归通过。两者不可互相替代。

## 目录

| 目录 | 内容 |
| --- | --- |
| `patches/` | 每个修复一个子目录：载荷文件、SELinux 片段、标签表、应用说明 |
| `scripts/` | 可复现的注入/重建/校验脚本（WSL Linux 侧运行） |
| `docs/` | 方案文档、规范、状态矩阵、历史验证记录 |
| `upstream/` | 第三方来源包的原样快照（不修改） |
| `tools/` | 一次性分析工具（挂载、差分、策略核对） |

## 快速开始（应用小米账号修复到你的包）

前提：Linux / WSL 环境，具备 `mkfs.erofs`、`fsck.erofs`、`simg2img`、`img2simg`、`erofsfuse`，并已解出基线 `odm.img` / `vendor.img`。

```bash
# 1) 挂载基线（只读）
scripts/mount_erofs.sh target/odm.img    /mnt/odm
scripts/mount_erofs.sh target/vendor.img /mnt/vendor

# 2) 注入 + 重建（幂等；会自动跳过目标已有的重复库）
scripts/apply_xiaomi_account.sh \
    --odm    /mnt/odm \
    --vendor /mnt/vendor \
    --patch  patches/xiaomi-account \
    --out    out/

# 3) 校验（标签、差分、xattr、sparse 回读）
scripts/verify_xiaomi_account.sh --out out/ --baseline-odm /mnt/odm --baseline-vendor /mnt/vendor
```

产物：`out/odm.img`、`out/vendor.img`（sparse，可直接 `fastboot flash`）。

**单变量刷写**（已开机状态下只验证本修复）：

```bat
fastboot -S 128M flash odm_a    out\odm.img
fastboot -S 128M flash vendor_a out\vendor.img
fastboot reboot
```

刷完的实机回读检查：

```bash
adb shell su -c 'dmesg | grep -i "avc\|not valid"'      # 期望：无 mtd/misys 相关 avc，无 "not valid" 上下文
adb shell su -c 'ps -A -Z | grep -E "mtd|hypsys"'       # 期望：mtd → u:r:hal_mtdservice_default:s0
adb shell su -c 'service list | grep -E "mtdservice|misys"'   # 期望：IMTService/default 已注册
```

## 设计原则

1. **单变量**：一次只改一个分区/一个修复，并保留可回滚镜像。
2. **不猜标签**：可执行文件用专用 HAL 域；共享库 `vendor_file`；rc/vintf `vendor_configs_file`。绝不把整棵 payload 标成同一个"万能域"。
3. **不签名伪造**：改过 dex 的 APK 必须有效重签，或改走运行时挂载（KSU 模块）路线。
4. **区分验证层级**：离线检查通过 ≠ 实机功能通过；文档里分开记。
5. **保留证据**：每次构建留 `provenance`（输入哈希、参数、差分结果）。

## 来源与许可

见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本仓库包含来自第三方移植社区的二进制载荷（原样保留并标注来源）与小米/realme 原厂文件，权利归各自权利人；仓库自身脚本与文档的授权方式由仓库所有者确定。
