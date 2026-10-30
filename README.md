# RMX5010_HyperOSFix

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的**镜像级修复集**：把小米用户空间拉到 realme 原厂硬件底上跑通，并用最小改动量、可复现、可验证的方式记录每一条修复。

本仓库不是 LSPosed 模块工程，而是**补丁集 + 构建/验证脚本 + 证据文档**。LSPosed 注入层现在由 Sense（`com.zephiel.sense`）承担：Sense 同时是控制界面和唯一的 LSPosed 模块，内含本仓库的主 hooks 与 ColorOS 钱包 hooks。每一条修复都按同一套格式落地：

```
症状签名（logcat / 现象） → 根因 → 载荷（文件 + 标签 + 策略） → 构建脚本 → 验证证据 → 残余风险
```

## 适用范围（先读）

- **仅 RMX5010（realme GT7 Pro）**，目标分区布局 54 张镜像；不要套用到别的机型。
- 修复按**底包版本**对齐。当前主线底包（**2026-10-25 起**）：
  - 硬件底：RMX5010 ColorOS **16.0.7.201**（11.F.64_2640）
  - 用户空间（donor）：小米 **haotian**（15 Pro）**OS4.0.0.19.XOBCNXM**（Android 17 / SDK 37）
- **主线切换记录**：2026-10-25 起 donor 从 nezha OS4.0.2.0.XPACNXM 切换为 haotian OS4.0.0.19.XOBCNXM（"以 15 Pro 的包修"）。下表状态列注明各行适用主线：**haotian** = 已迁移到 haotian 底并实机验证；**nezha** = 仅在 nezha 主线验证，方法有效、待迁移。
- 换底包后**必须重新推导 SELinux 闭包**（类型后缀/策略版本都会变），不能直接套用本仓库的 `.cil` 片段。
- 动 vendor / odm 属于高风险操作：本仓库所有脚本都假定 `vendor` 之外的固件分区（xbl/aop/hyp/tz/abl/keymaster/modem…）**永不改写**。

## 当前修复状态

| 修复项 | 主线 | 载体 | 离线验证 | 实机验证 | 文档 |
|---|---|---|---|---|---|
| 小米账号 / MTD 依赖闭包 | **haotian**（原厂 16.0.7.201 底） | odm + vendor 重建 | ✅ 标注/差分/策略编译 | ✅ 实机验证通过（开机引导过账号） | [方案](docs/小米账号MTD依赖_修复方案.md) |
| ODM 身份（PJA110→nezha→**haotian**） | **haotian** | odm build.prop 断 import 链 + 写死身份（device/name=haotian、model=2410DPN6CC、marketname=Xiaomi 15 Pro） | ✅ 镜像差分/字节级对比 | ✅ 实机验证通过（指纹 Xiaomi/haotian/haotian:17/…OS4.0.0.19.XOBCNXM） | [补丁](patches/odm-identity/README.md) |
| 信号掉线（TeleService XTS，CNE 防崩为可选件） | **haotian**（0.19 TeleService 重打，三处标记点一致） | system（dex 补丁，保签名块） | ✅ dex 往返/差分/结构 | ✅ 实机验证通过（h19 开机） | [补丁](patches/signal-fix/README.md) |
| MTP + DPI 500 | **haotian**（0.19 donor DPI 600→500） | system rc + product build.prop | ✅ 镜像差分 | ✅ 实机验证通过（wm density 500） | [补丁](patches/mtp-and-dpi/README.md) |
| NFC 载荷（XMNfcNci + NXP 栈） | **haotian**（0.19 donor 不带 XMNfcNci，注入） | system 注入 | ✅ 哈希/大小核对 | ✅ 实机（service nfc found、initialized=true） | [补丁](patches/nfc-nxp-fix/README.md) |
| 查找设备 | nezha（保持官方原版） | — | ✅ 官方哈希核对 | ✅（nezha 主线） | [说明](patches/finddevice-notz/README.md) |
| CNE 防崩（可选件） | nezha | vendor dex 补丁 | ✅ | ✅（nezha 主线） | [补丁](patches/signal-fix/README.md) |
| 亮度曲线 + 圆角/状态栏高度 | nezha | product（displayconfig XML + DevicesAndroidOverlay） | ✅ 差分/资源核对 | ✅（nezha 主线） | [补丁](patches/brightness-overlay/README.md) |
| 音频爆音 / 切音"哔"声（appname 截断） | nezha | system_ext 重建（libaudiopolicymanagerimpl.so 补丁） | ✅ 差分/反汇编核对 | ✅（nezha 主线） | [补丁](patches/audio-pop-fix/README.md) |
| 分辨率列表（1.5K/1080p）+ 120Hz 刷新率 | nezha | product（nezha.xml + build.prop 动态帧率） | ✅ 差分/XML语法核对 | ✅（nezha 主线） | [补丁](patches/resolution-and-refresh/README.md) |
| 原生内核级事件驱动 LTPO 降频恢复 | nezha | vendor 重建（rmx5010_ltpo_restore.ko + init 原生自启） | ✅ 符号/校验/ELF一致 | ✅（nezha 主线） | [补丁](patches/resolution-and-refresh/README.md) |
| 相机 P010 厂商格式崩溃修复 | nezha | system（libnativewindow.so 扩展分支） | ✅ 差分/反汇编核对 | ✅（nezha 主线） | [补丁](patches/camera-p010-fix/README.md) |
| 相机全套成像与多摄落盘闭包（IMX906/LYT600/前摄/14路/fakejar） | nezha | product + odm 重建（OplusCamera 特权预置 + Provider stub） | ✅ 差分/标签/策略/fsck | ✅（nezha 主线） | [补丁](patches/camera-full-fix/README.md) |
| NFC 五项 Mi 调优 prop（mitouch/phonecase/repair/secure_display_optim/wallet_fusion） | haotian（**未生效**） | product build.prop → 运行时被 factory vendor 策略拒（init 无 vendor_nfc_mi_prop set 权限） | ✅ 镜像差分 | ❌ 运行时缺属性；NFC 基础功能不受影响，vendor sepolicy 补丁方案见 nfc README | [补丁](patches/nfc-nxp-fix/README.md) |
| 超声波屏下指纹（FOD 物理中心 632,2146 + 特性声明 + UFF HAL） | nezha | product + odm 重建（nezha.xml + 权限声明 + odm 坐标） | ✅ 差分/参数/语法核对 | ✅（nezha 主线；haotian 底**已知未修**——sensorType 映射坑待重做） | [补丁](patches/fingerprint-fod/README.md) |
| 低共振触觉铃声（MiRemix.ogg 1.15MB 旗舰声学对齐） | nezha | product 重建（高品质低共振音频载荷替换） | ✅ 文件与 SHA256 核对 | ✅（nezha 主线） | [补丁](patches/haptic-ringtone/README.md) |
| 双击亮屏（AOD LPWG + F4 唤醒） | **haotian** | KSU 模块 `service.sh`（触摸 HAL 写 node1=1 / node21=2） + LSPosed F4 钩子（HBP 一次双击一个 F4，单 F4 直接唤醒） | ✅ 冷启动 / touchDaemon 重启自动重发 | ✅ 实机（`low power gesture mode enabled`，注入单 F4 从 Dozing → Awake） | [文档](docs/双击亮屏_LPWG根因与修复.md) |
| 超级小爱语音识别（ASR） | **haotian** | LSPosed `com.xiaomi.finddevice` NoTZ 凭证委托 + KSU 通用 `acc_udevid` | ✅ 账号 uDevId / MiTalk / fid+sig+ts 签名链路 | ⏳ Aliyun（主）/ Volc（回退）均 `40002 Device deny`（设备/账号授权，非本地凭证） | [根因](docs/超级小爱语音识别_根因与修复.md) / [鉴权逆向](docs/超级小爱鉴权逆向_读取清单.md) |
| IFAA / 支付宝指纹支付 | **haotian** | LSPosed `IfaaHooks` + system_server 权限放行 + KSU SELinux live patch | ✅ T1=17 / T3 / T4→Oplus HAL / 支付宝登录期真实 processCmd | ⏳ 当前 0 枚指纹且支付宝要求新设备验证，最终扣款待用户 | [实现与验证](docs/IFAA指纹支付_RMX5010实现与验证.md) |
| 触感兼容 / 强度校准 / 线性化 | **haotian** | LSPosed `HapticHooks`（88 个 HyperOS 私有 effect ID 全覆盖 + 未知 ID 回退、VibratorInfo 扩展、键盘/Launcher/SystemUI 多 Step pattern → 校准 effect 2/4/5、侧滑返回 162/163→flick/flick.light）；`ctl.sh`/`service.sh` 写 QTI HV `fifo_vmax/vmax/cl_vmax` | ✅ map/info/scale/click/strength hook 加载；真实 Sogou 191ms→TICK，Launcher 212ms→POP；滑条 0.3→`Set Vmax 600mV`、1.0→8200mV | ✅ 实机机制；默认 1.0/2/4，侧滑返回/多任务手感待用户确认 | [适配记录](docs/触感_采样率_LHDC_RMX适配.md) |
| 触控采样率（节点 182） | **haotian** | KSU 模块补丁 `sys_touch_function_feature_config.xml`（两个 report_rate 开关）+ `touch_rate.sh` / `service.sh`；Sense 120/180/240/360 滑条 | ✅ `touch_supported=1`；240Hz 后 daemon `actual rate 240`；息屏 120/亮屏 240 | ✅ 实机 | [适配记录](docs/触感_采样率_LHDC_RMX适配.md) |
| LHDC V5 编码器桥接 | **haotian** | Sense 内 `com.android.bluetooth` hook + NDK helper + `jniLibs/arm64-v8a` 三个 Savitech 库 | ✅ `status=7`、接口安装成功、蓝牙稳定 | ⏳ 未配对 LHDC 耳机做端到端试听 | [适配记录](docs/触感_采样率_LHDC_RMX适配.md) |
| MiCharge / 手机管家电池时间 | **haotian** | LSPosed `MiCharge*` + `SecurityCenterTimeHooks`，scope SecurityCenter/Manager | ✅ 框架桥/W MAX 安装；电池页 0→36 时 36 分 | ⏳ 充电中预计充满/小数/W MAX 待插充电器 | [适配记录](docs/MiCharge与电池时间_RMX适配.md) |
| 音频卡顿（appname 参数） | **haotian** | KSU `post-fs-data.sh` bind-mount 补丁库（8×`blr x8`→`nop`） | ✅ 原/补丁哈希、8 个调用点逐字节核对；目标哈希匹配 | ✅ audioserver/铃声预览通过；主观听感待回归 | [补丁说明](docs/音频卡顿_appname补丁.md) |
| 抬起亮屏严格服从开关 | **haotian** | LSPosed `SettingsHooks` 暴露开关 + `SystemUiHooks` 只读设置 + ContentObserver | ✅ 开/关时 type 22 注册/注销，模块不写设置 | ✅ 实机 | [说明](docs/抬起亮屏_严格服从系统开关.md) |
| Sense 配置前端 / 唯一 LSPosed 模块 | **haotian** | `com.zephiel.sense`（Compose UI + `SenseXposedEntry` + 主 hooks + 钱包 hooks + `oplus-fwk.jar`） | ✅ 合并源码后 Gradle 构建通过；KSU `ctl.sh` 状态读取正常 | ✅ 实机（SukiSU 授权、LSPosed 各进程加载、锁屏/解锁刷卡页、配置页状态） | [评估与落地](docs/Sense配置前端评估.md) |
| 状态栏反色 | **haotian** | Sense `StatusBarHooks` 归一化 SystemUI displayId（3 个回调）；兼容已直比较的现机 APK | ✅ 现机 APK 已带直比较补丁；hook 安装日志 `normalization hooks=3` | ✅ 实机（现机视觉正常；hook 幂等） | [适配记录](docs/Sense配置前端评估.md) |
| Sense 性能调度 / 刷新率尝试 | **haotian** | CPU governor `powersave`/`schedutil`/`performance` 预设；刷新率写 `user_refresh_rate`/`miui_refresh_rate` | ✅ 两簇 governor 切换实测；❌ 刷新率只改 desired，`activeMode` 仍 120，已从 UI 移除 | ✅ 实机（调度）；刷新率无效 | [评估与落地](docs/Sense配置前端评估.md) |
| 模块合并形态 | **haotian** | 一个 KSU 模块（`rmx5010_fod_bridge` 1.4.1）+ Sense 作为唯一 LSPosed 模块 | ✅ `build_sense_module.sh` / `register_sense_lsposed.sh` / `ctl.sh` | ✅ 实机 | [说明](docs/Sense配置前端评估.md) |
| QESDK/QAPE 性能服务 | **haotian** | KSU 1.3.9 `qesdk_fix.sh`：三份 vendor seccomp policy 补 `lseek` 并 bind mount；关闭 qseelogd | ✅ 三服务不再 SIGSYS；qseelogd 停；开机 swap 7.1GB→489MB | ✅ 实机（重启后验证） | [状态矩阵](docs/修复清单与状态矩阵.md) |
| 游戏 24fps / 游戏静置降 24Hz | **haotian** | KSU 1.4.1 连续采样：前台游戏每 2 秒读取 SF `(uid, frameRate)`；≥30Hz 只观察不终止；进入 24Hz/无请求后 5 秒按 fallback 抬帧，保留本会话观察到的最高档（最高 120） | ✅ Blue Archive 静置 24Hz → 60Hz（custom 60）；120 请求被观察并保留；无包名名单 | ✅ 实机（2026-10-29，日志 `apply ... requested 24.00Hz`） | [诊断记录](docs/游戏24fps诊断_ACE与帧率策略.md) |
| 相机移植（OplusCamera 6.070.45 完整算法） | **haotian** | 16.0.7.201 原厂 OplusCamera 6.070.45 作为数据区更新；原厂 `unit.sdk.jar` / APS libs / `camera_unit_config`；KSU `oplus_camera_app2` 域补 `mediacodec`/`mediaswcodec`/`hal_camera_default` 双向 binder；APK 补 `OplusHansFreezeManager` stub 与 `TypeFaceUtil` NPE catch；开机自动注入 `libvndksupport`/`lib2DSlender`；`system_ext/lib64` 补 `libcsextimpl` 的 7 个 NEEDED 依赖；Sense 增加 `com.oplus.camera` 高速 session SurfaceUtils hook、`ApsDataConvert.getApsModeName` professional_mode→common hook 和 `yn.h1.a` 相册包名→`com.miui.gallery` hook；cameraserver 补 DataSpace override 单变量补丁 | ✅ 后摄 1x 完整 APS 多帧（`mRequestNum=8`、TurboHDR/ArcSoft/离线 Bayer2Yuv、原生保存 3072×4096）；前摄 3456×4608；0.6x/1x/2x/3x/6x 变焦；夜景、街拍、高像素 6144×8192、电影、多景录像（有效 MP4，finalize 待修）、慢动作 `VID20261031044023.mp4`、长曝光、专业模式 `IMG20261031043941.jpg` 3072×4096（`onApsJpegArrived`/`completeCapture`/`Picture Save End`）；相册缩略图打开 `com.miui.gallery/.activity.ExternalPhotoPageActivity`；重启后复测成功 | ⚠️ 超级文本因缺 `libXDocProcessSDK-jni.qti.so` 的 Qualcomm 变体仍会崩溃；延时摄影停止时报 `VCP_RECORD_FILE_IS_INVALID`；全景需实际平移；0.6x EXIF 可能仍写 73mm，实际 capture surface 含 `rear_wide`；专业模式走 common APS 而非原厂 professionalFull | [说明](docs/相机移植_OplusCamera系统级_20261029.md) |
| 微信闪退（fake CameraX） | **haotian** | KSU 1.3.9 `wechat_fix.sh` 在 post-fs-data bind mount 最小 `<permissions/>`，注销 ODM fake jar 的共享库 | ✅ `cmd package list libraries` 不再出现 `androidx.camera.extensions.impl` | ✅ 机制实机；⏳ 当前未安装微信，待启动回归 | [说明](docs/微信闪退_fake_CameraX库.md) |
| 抖音/LTPO 触摸升帧 | **haotian** | KSU 1.3.9 `post-fs-data.sh` 用 `ksud resetprop` 把 `ro.surface_flinger.set_touch_timer_ms` 从 0 改为 2000 | ✅ 评论区滑动 `renderRate=120`、120 计数增长；停止 2 秒回落 30Hz/60 模式 | ✅ 实机（2026-10-29） | [说明](docs/刷新率_触摸升帧_LTPO.md) |
| 未完成清单（2026-10-27） | — | 汇总待验证/未实现/不适用项 | — | — | [清单](docs/未完成清单.md) |
| ColorOS 钱包（FinShell/TAS/HTMS/UPTsm/eID） | **haotian** | 五个钱包 APK（用户态）+ Sense 内钱包 hooks + LSPosed scope | ✅ FinShell 首页、默认钱包、WALLET 角色、eSE C0 路由；HTMS 必需 | ⏳ 登录/实名/发卡/实际交易、系统 App 特权 | [移植记录](docs/ColorOS钱包_RMX5010移植.md) |
| 双击电源键打开 NFC 刷卡页 | **haotian** | Sense 内 `SystemServerHooks` hook `launchDefaultWallet`（锁屏/息屏）+ `WalletHooks` hook SystemUI `startGestureUiIntent`（解锁）→ `NfcConsumeActivity`；KSU 放行 show-when-locked AppOp 10020 | ✅ 解锁/锁屏双击都直达刷卡页；锁屏页面覆盖 Keyguard 常驻，无“不支持”提示 | ⏳ 未登录/无卡；登录+加卡后回归选卡/交易 | [移植记录](docs/ColorOS钱包_RMX5010移植.md#46-双击电源键打开刷卡页) |
| SELinux 闭包与 EROFS 重建规范 | — | — | ✅ | — | [规范](docs/SELinux闭包与EROFS重建规范.md) |
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
