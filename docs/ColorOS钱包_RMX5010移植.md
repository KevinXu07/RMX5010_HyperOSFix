# ColorOS 钱包（FinShell/TAS）RMX5010 移植记录

状态（2026-10-26）：

| 项目 | 状态 |
|---|---|
| FinShell 钱包主界面 | ✅ 实机（隐私页 → `WalletIndexActivity` 首页） |
| 默认支付钱包 / WALLET 角色 | ✅ 实机（`com.finshell.wallet`） |
| eSE 路由 | ✅ 实机（`eSE=192`，即 `0xC0`；`Routed to 0xc0`） |
| HTMS（移动服务） | ✅ 实机（不装会弹“请安装最新版本移动服务”） |
| 登录 / 实名 / 发卡 / 实际刷卡支付 | ⏳ 需要账号、真实卡片和终端 |
| 系统 App 身份 / 系统特权 | ❌ 未完成；当前为用户态安装 |
| eID / 公交 / 门禁真实交易 | ⏳ 未验证 |

## 1. 这是哪一种钱包

不是小米钱包，而是 **ColorOS 钱包套件**：

```text
com.finshell.wallet          FinShellWallet 5.44.9
com.heytap.tas               TasWallet 5.43.9
com.heytap.htms              HeytapHTMS 2.1.28（“移动服务”）
com.unionpay.tsmservice      UPTsmService 01.01.13
com.oplus.eid                EidService 16（eID 服务）
```

来源：`Maga-King/COS-WALLET-FIX` v0.11.0 的

```text
ColorOS_Wallet_SystemInject_Release1.0.1_A17_noLSP_noSE.zip
SHA-256 a8ecb7a9795c310440844c805d4344de35915211b3b824e88908f1cae033da56
```

LSP 兼容模块：

```text
COS_WALLET_FIX_v0.11.0.apk
SHA-256 d798b634fa59499be92aa9c55ab2e98fa7c1890c27d431aa30035684bbacb347
package local.mio.coloroswalletcompat
```

## 2. RMX 硬件条件

```text
NFC 控制器       NXP SN220（libnfc-mtp-SN220.conf）
NFC 框架         com.android.nfc / XMNfcNci（小米 NFC）
eSE              android.hardware.secure_element.ISecureElement/eSE1
NXP AIDL         vendor.nxp.nxpnfc_aidl.INxpNfc/default
OPlus NFC HAL    vendor.oplus.hardware.nfc.IOplusNfc/default
OPlus eID HAL    vendor.oplus.hardware.eid.IEidDevice/default
已有 TSM         com.miui.tsmclient、com.unionpay.tsmservice.mi
```

NXP 配置里逻辑路由是 `OFFHOST_ROUTE_ESE={01}`，但实际 eSE NFCEE 由控制器报告为
**0xC0 / 192**。模块日志确认：

```text
routing singleton captured iso=2, offhost=2, felica=0, eSE=192
official routing queued (wallet_policy) iso=192, ab=192, felica=0
direct official routing commit status=0
```

这与 OnePlus 13 的 SN220 一致，所以模块的 `0xC0` 常数在 RMX 上**不用改**。

## 3. 实际部署方式（已验证可用）

当前采用**用户态安装 + LSPosed**，不是系统 App：

1. 安装 `COS_WALLET_FIX_v0.11.0.apk`。
2. 依次安装五个钱包 APK（顺序不严格）：
   - FinShellWallet
   - TasWallet
   - UPTsmService
   - EidService
   - HeytapHTMS
3. 在 LSPosed 中给 `local.mio.coloroswalletcompat` 注册作用域：

```text
android
system
com.android.nfc
com.android.se
com.android.settings
com.finshell.wallet
com.heytap.tas
com.unionpay.tsmservice
com.oplus.eid
com.heytap.htms
com.miui.tsmclient
```

4. **重启一次**，让 LSPosed 在 SystemUI/NFC/钱包进程启动前加载作用域。
5. 打开“钱包”，同意隐私政策；HTMS 已安装后不会再弹“安装移动服务”。

自动化脚本：`scripts/install_cos_wallet.sh`（会校验 SHA、安装 APK、注册模块和
作用域；`--reboot` 可自动重启）。

### 3.1 作用域会被卸载清掉

实测卸载钱包包后，LSPosed 会把对应 scope 行清掉。重装 APK 后只热补 scope
不会注入已经运行的 FinShell 进程，必须：

```text
重装 APK → 重新写 scope → 重启
```

否则 FinShell 会显示“钱包不支持在该系统运行”（因为没有加载本地 vendor gate）。

## 4. 已验证结果

### 4.1 钱包 UI

```text
com.finshell.wallet/com.nearme.wallet.SplashActivity
→ 用户须知
→ com.nearme.wallet.main.WalletIndexActivity
```

首页可见“付款 / 乘车 / 开门 / 卡包 / 添加一张门禁卡 / 我的”等入口。

### 4.2 默认钱包与 WALLET 角色

`dumpsys nfc`：

```text
*** Current wallet payment service:
    ComponentInfo{com.finshell.wallet/com.nearme.wallet.nfc.CardService}
*** Current preferred payment service:
    ComponentInfo{com.finshell.wallet/com.nearme.wallet.nfc.CardService}
Wallet role package: com.finshell.wallet
Preferred payment service:
    ComponentInfo{com.finshell.wallet/com.nearme.wallet.nfc.CardService}
```

LSP 日志：

```text
fixed wallet policy reconciled reason=wallet_role_result changed=true
wallet role request accepted=true
```

### 4.3 eSE / NFC 路由

```text
Current off-host SE:eSE1
Routed to 0xc0
eSE=192
```

模块把 ISO/off-host 默认路由设为 192，并提交成功（`status=0`）。这证明
RMX 的 SN220 eSE 编号和模块的 C0 假设一致。

### 4.4 权限

```text
oplus.permission.OPLUS_COMPONENT_SAFE: granted=true
wallet runtime permission grants updated=6
```

`OPLUS_COMPONENT_SAFE` 由 LSP 模块 manifest 定义，system_server 里的
`WalletRuntimePermissions` 负责给 FinShell/TAS 授予并配置后台 AppOp。
定位、联系人、短信、相机等运行时权限仍是 denied，需要用户按业务授予。

### 4.5 HTMS

不安装 `com.heytap.htms` 时，FinShell 会弹“请安装最新版本移动服务”。
安装后该弹窗消失，HTMS 子进程启动并访问 `htms.heytapmobi.com`。

### 4.6 双击电源键打开刷卡页

本机设置：

```text
settings get system double_click_power_key
launch_QAW_wallet
settings get secure double_tap_power_button_gesture
1
```

系统原本走 Android Quick Access Wallet（QAW），但 FinShell 没有声明
`QuickAccessWalletService`；Settings 的
`double_tap_power_wallet_footer_title` 正是
“当前的默认钱包应用不支持该手势”。COS-WALLET-FIX 里只有 Mi TSM
`DoubleClickActivity` → `CardPackageActivity` 的重定向，既没有处理 QAW
检查，目标也是卡包页而不是 NFC 刷卡页。

本仓库**不拦截电源键事件流**。双击判定仍由 HyperOS 自己的
`PowerKeyRule` / `CentralSurfaces` 完成，模块只替换两个“已经判定为双击”
之后的落点：

1. **解锁/亮屏路径**：SystemUI
   `com.android.systemui.wallet.controller.QuickAccessWalletController.startGestureUiIntent(ActivityStarter)`
   （由 `CentralSurfacesCommandQueueCallbacks.onPowerButtonLaunchGestureTriggered`
   调用）→ `WalletHooks` 直接启动刷卡页；
2. **锁屏/息屏或 Mi TSM 路径**：system_server
   `com.miui.server.input.util.ShortCutActionsUtils.launchDefaultWallet()`
   → `SystemServerHooks` 同样启动刷卡页。

两条路径使用相同的 intent：

```text
com.finshell.wallet/com.nearme.wallet.nfc.ui.NfcConsumeActivity
action: finshell.wallet.intent.action.OPEN
extra:  local.mio.coloroswalletcompat.extra.LOCKSCREEN_SESSION=true
flags:  NEW_TASK | SINGLE_TOP | CLEAR_TOP | 0x00080000
```

`NfcConsumeActivity` 的 manifest 已声明 `showWhenLocked=true`，extra 由
COS-WALLET-FIX 的锁屏会话 hook 消费。不再经过
`QuickAccessWalletClient`，因此 FinShell 没有 `QuickAccessWalletService`
也不会出现 “Wallet service unavailable”。

早先版本直接 hook `PhoneWindowManager` 的双击 POWER，会与 Keyguard 的
单击锁屏逻辑抢同一个按键流，实测表现为“先锁屏、刷卡页再弹出来”。该方案
已完全移除；上述两个 hook 都不接触按键流，因此不会再把屏幕锁上。

实测（解锁状态双击）：

```text
RMX5010HyperOSFix: wallet gesture -> FinShell swipe hook installed
RMX5010HyperOSFix: wallet gesture -> com.finshell.wallet/com.nearme.wallet.nfc.ui.NfcConsumeActivity
```

`mDreamingLockscreen=false`，前台窗口和 top-resumed activity 都是
`NfcConsumeActivity`，日志中不再出现 `QAWalletSClient: Wallet service
unavailable` 或 `double_tap_power_wallet_not_supported`。界面停在“钱包 /
充电卡 / 靠近读卡器”，即 NFC 刷卡页而不是卡包首页。

息屏/锁屏状态双击最初只能看到一帧：Activity 已经创建并绘制，但 HyperOS
`ActivityRecordImpl.canShowWhenLocked()` 还会检查 AppOps `10020`
（`MIUIOP(10020)`，show-when-locked）。FinShell 在本机是用户态安装，
默认被拒绝：

```text
ActivityRecordImpl: MIUILOG- Show when locked PermissionDenied pkg : com.finshell.wallet uid : 10313
KeyGuardHelper: showWhenLocked:
```

Keyguard 因此暂停 Activity，FinShell 的 `onStop` 再走
`SystemStateManager.postDelayFinish` → `finishAndRemoveTask`，表现为
“锁屏双击弹不出来”。只给钱包包放行该 AppOp：

```text
cmd appops set com.finshell.wallet 10020 allow
cmd appops get com.finshell.wallet 10020
MIUIOP(10020): allow
```

之后锁屏双击，`mDreamingLockscreen=false`，`NfcConsumeActivity` 成为
前台和 top-resumed activity，日志中没有 `PermissionDenied`、`onPause` 或
`finishAndRemoveTask`。截图里锁屏时钟和刷卡页同时存在，说明页面确实覆盖
在 Keyguard 上，而不是把设备解锁了。

该授权已固化到：

- `kernel-src/ksu-module/service.sh`：开机等 `sys.boot_completed=1` 后执行；
- `scripts/install_cos_wallet.sh`：安装钱包 APK 后立即执行。

这是 HyperOS 私有 AppOp，卸载钱包后可能被清除；重装后重跑安装脚本即可。
当前设备未登录钱包、没有卡，但刷卡页已经能在锁屏常驻；登录并加卡后的
选卡/交易仍需实机回归。Settings 里的 “当前的默认钱包应用不支持该手势”
是静态 footer，仍可能显示；运行时双击已不走 QAW，不会再弹该提示。

## 5. 失败实验：KSU system overlay

尝试把五个 APK 放进 KSU 模块：

```text
/data/adb/modules/cos_wallet/system/app/...
```

KSU 显示 `mount=true`，但 `/system/app` 实际没有出现文件，PackageManager
也扫不到；直接做 overlayfs 测试返回：

```text
mount: 'overlay'->'/data/local/tmp/ov/merged': Invalid argument
dmesg: overlay: case-insensitive capable filesystem on ... not supported
```

原因是 `/data` 是 case-insensitive capable 文件系统，不能作为 overlayfs
upperdir；KSU 的 magic mount 同样没有生效。该模块已删除，不要重复这条路径。

如果后续确实需要系统 App 身份/特权，可选：

1. 用 loop-mounted **ext4** 镜像作为 overlay upperdir（ext4 大小写敏感），
   在 `post-fs-data.sh` 里对 `/system/app` 和 `/system_ext/app` 做 overlay；
2. 或直接重建 system/system_ext EROFS 镜像并刷入（需要处理 APK 权限、
   privapp allowlist 和 SELinux 标签）。

## 6. 还没验证 / 风险

- **登录与实名**：需要 OPPO/OnePlus 账号；当前只到首页，没有登录。
- **发卡、公交、门禁、实际刷卡支付**：需要账号、真实卡片和终端；当前只证明
  默认钱包、WALLET 角色和 eSE C0 路由正确，不能宣称交易成功。
- **eID**：EidService 已作为用户 App 安装，OPlus eID HAL 存在；没有做身份证
  eID 开通。
- **TAS/UPTsm**：已安装，未做真实卡包/银联 TSM 交易。
- **系统 App 特权**：`WRITE_SECURE_SETTINGS`、`READ_PRIVILEGED_PHONE_STATE`
  等未授予；钱包 UI 可用，但部分风控/发卡步骤可能需要系统身份。
- **设备身份**：模块在钱包进程内伪装 OnePlus 13（PJZ110）和
  `ro.product.cuptsm=ONEPLUS|ESE|01|02`；不改 TEE/CPLC/证书。若服务端做
  硬件级设备认证，仍可能拒绝。
- **NFC 刷卡位置**：C0 路由已确认，但实体门禁/公交需要现场测试。

## 7. 从 COS-WALLET-FIX 学到的东西

1. **默认钱包不是只写 UI**：要同时维护 WALLET 角色、payment 组件、off-host
   eSE1 和标签偏好，四者缺一不可。
2. **eSE NFCEE ID 是设备假设**：OnePlus 13 的 SN220 是 C0；RMX 实测也是 C0，
   但不能把这个结论套到不同 NFC 芯片。
3. **签名白名单**：`com.android.se` 只对原始 FinShell/TAS 签名做特权通道
   放行；重签 APK 会破坏这条链。
4. **事件驱动**：ContentObserver、包变化、NFC 回调、350 ms 合并；没有轮询、
   常驻 shell 或 watchdog。
5. **标签分发与默认支付分开**：支付宝/微信仍走 NDEF/AAR，不能把所有标签
   强制转给钱包。
6. **选卡状态机**：选卡广播 → 动态 AID → RF profile/DH85/SAK → 提交路由，
   缺一段就会出现“能录卡但刷不出”。
7. **不伪造 TEE/CPLC/证书**：只修软件衔接；硬件认证失败要如实报告。

## 8. 复现与文件

```bash
# 一键安装（需已下载 release 包，或脚本自动下载）
bash scripts/install_cos_wallet.sh --reboot
```

相关工具：

```text
scripts/install_cos_wallet.sh
tools/lspd/LspdModule.java
tools/lspd/lspdscope.dex
```

钱包 APK/LSP APK 不在仓库内，按脚本中的 SHA-256 从上游 release 下载。
