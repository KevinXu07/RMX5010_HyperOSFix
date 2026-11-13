# MiPush 与 FCM 推送：诊断与修复（2026-11-13）

设备：RMX5010（真我 GT7 Pro），HyperOS OS4.0.0.19.XOBCNXM 移植包，伪装为 `Xiaomi 15 Pro / 2410DPN6CC`，地区 CN，模块 1.7.18。

问题：有的应用收不到通知。

## 结论

1. **MiPush（小米推送）正常**：xmsf 已注册、保持长连接、按时心跳，开机后的推送都能送达，状态栏也能显示。没有因为移植缺组件或设备标识而注册失败。
2. 收不到通知的应用分 4 类，大多与 MiPush 本身无关：

| 类别 | 应用（本机） | 原因 | 处理 |
|---|---|---|---|
| A. FCM 应用 | Telegram、X(Twitter)、ChatGPT、GitHub、Chrome、Gemini、Apple Music 等 | HyperOS CN 的 Greeze 在**息屏约 60 s 后冻结 `com.google.android.gms`**（`mGmsLimitEnabled`），亮屏才解冻；息屏期间 FCM 消息进不来 | **已修**：模块开机执行 `dumpsys greezer IM GMS disable`（可关） |
| B. 应用通知权限关闭 | 中国银行 `com.chinamworld.bocmbci`、工商银行 `com.icbc`、国家网络身份认证 `cn.cyberIdentity.certification`、夸克、UC、中国移动云盘 | `POST_NOTIFICATIONS granted=false`，`importance=NONE`；它们走 MiPush（个推/阿里 agoo 等通道），但应用本身的通知开关是关的 | 用户在“设置 → 通知”里逐个打开（或应用内授权）；不自动改 |
| C. 自带长连接、没有 MiPush 的应用 | **微信**（主应用和分身），以及 QQ 的实时通道 | 内核没有小米 **Millet** 驱动，Greeze 冻结进程后收到网络包也无法解冻（缺 `reportNet`）。每次亮屏（包括新通知点亮屏幕）都会触发 launch-mode 冻结（`LM FZ`），微信和 QQ 被冻住且不随 LM 超时解冻，只能等闹钟才醒，于是**微信消息延迟 1–2 分钟后成批到达** | **已修（绕过）**：模块开机把微信和 QQ 加入 Greeze 的 LM 白名单（`dumpsys greezer LM add`），云端列表变化时自动重加。根治要移植 Millet 内核模块，作为后续任务 |
| D. 没接任何推送的应用 | 只能靠前台或后台常驻 | — | 不处理 |

## 1. MiPush 工作证据

- 进程：`com.xiaomi.xmsf`、`:services`、`:privacy`，以及 `com.xiaomi.xmsfkeeper` 都在。`XMPushService` 开机即启动（`createTime` 等于开机时间，`lastStartId=161`）。
- 长连接：xmsf（uid 10207）有一条 `ESTABLISHED` TCP 连接，`192.168.0.24 → 114.247.154.4:5222`（MiPush XMPP 端口），见 `/proc/net/tcp6`。
- 注册：`shared_prefs/mipush.xml` 中 `valid=true`、`appRegion=China`、`envType=1`、已有 regId；`files/mipush_region=China`、`mipush_country_code=CN`。
- 心跳：`hb_record.xml` 显示 `record_long_hb_count=240`、`record_short_hb_count=0`，即一直在用长周期心跳，连接稳定。
- 已注册应用：`mipush_apps_scrt.xml` 共 51 个包，包括 QQ、支付宝、淘宝、京东、抖音、QQ 邮箱、酷安、小黑盒、滴滴、高德、学习通、中国银行、工商银行等。
- 实际送达：`dumpsys notification` 中 `opPkg=com.xiaomi.xmsf` 的通知在开机（13:03）后仍在到达，例如抖音 13:24/13:29/13:30、QQ 邮箱 13:09。`mipush_push_click_records.xml` 显示当天点击过酷安、QQ、QQ 邮箱、支付宝、小黑盒的推送。
- 冻结：Greeze `showCoreUids` 包含 10207（xmsf），统计为 `frozen=0s`，xmsf 不会被冻结。
- 设备标识：`ro.product.manufacturer/brand=Xiaomi`、`ro.miui.ui.version.code=816`。第三方聚合 SDK（个推 `com.igexin`、阿里 agoo、腾讯 TPNS 等）因此都选择 MiPush 通道，`cmd package query-receivers -a com.xiaomi.mipush.RECEIVE_MESSAGE` 列出 61 个接收器。

xmsf 的推送通道日志不写 logcat；`/sdcard/Android/data/com.xiaomi.xmsf/files/log/xmsf_log_1.log` 只记录 XMS kit 日志。判断连接状态请看上面的 socket 和 prefs，不要靠 logcat。

## 2. FCM：Greeze GMS 限制（已修）

### 根因

`/system_ext/framework/miui-services.jar`，`com.miui.server.greeze`：

- `GreezeManagerService` 构造时 `mGmsLimitEnabled = true`。
- `triggerGMSLimitAction()`：`PolicyManager.isCnModel() && mGmsLimitEnabled && !mScreenOn` 时，先 `removeAurogonAllowList("com.google.android.gms")`，再对主用户和分身用户的 GMS uid 做 `quick freeze`。息屏后由 `GreezeManagerService$H` 延时消息触发。
- 只有亮屏（`reason: screen_on`）或少量 provider/broadcast 调用会解冻。

实测（修复前，`dumpsys greezer` 历史）：
```
13:10:06 SCREEN OFF!
13:11:06 FZ uid = 10277 pid = [ 14303 6667 ] reason : quick freeze caller : 8
13:13:56 FZ uid = 10277 ... quick freeze
...
统计：10277 被 quick freeze 9 次、99910277 10 次；10277 的解冻原因为 screen_on 9 次、provider 1 次
```
GMS 被冻结时，mtalk.google.com:5228 的连接在内核里还在，但 GMS 进程无法处理下行和心跳，FCM 消息只能等亮屏才到。正版小米 CN 机型也是这个策略，不是移植引入的问题。不过本机装了 GMS 并依赖 FCM 的应用较多，所以默认关掉这个限制。

### 修法

`AurogonImmobulusMode.handleDumpIM()` 自带调试开关：

```
dumpsys greezer IM GMS disable   # mGmsLimitEnabled=false，triggerGMSLimitAction 直接返回
dumpsys greezer IM GMS enable    # 恢复原厂行为
```

这个值在 system_server 内存里，每次开机都会重置，所以放进模块：

- `kernel-src/ksu-module/ctl.sh`：新增 `apply-gms-push` 和 `set-gms-push <0|1>`；`status` 输出新增 `gms_unfreeze`、`gms_limit`；`reapply` 也会应用。开关为 `settings global op13_fix_gms_unfreeze`，默认 1（解除限制），设为 0 则保持原厂行为。
- `kernel-src/ksu-module/service.sh`：`sys.boot_completed` 之后执行 `ctl.sh apply-gms-push`。

GMS 不在 `MILLET_NO_RESTRICT_APP` 白名单里，也不靠“省电策略：无限制”，所以不受用户设置影响。

### 验证

- 运行时：`dumpsys greezer | grep mGmsLimitEnabled` 从 `true` 变为 `false`。`ctl.sh set-gms-push 0` 和 `set-gms-push 1` 能来回切换，`status` 显示 `gms_limit=1` 和 `gms_limit=0`。
- 息屏行为：见下文“息屏实测”。

## 3. 通知权限关闭的 MiPush 应用

`dumpsys package <pkg> | grep POST_NOTIFICATIONS`：

| 包 | targetSdk | POST_NOTIFICATIONS |
|---|---|---|
| com.chinamworld.bocmbci | 35 | granted=false |
| com.icbc | 30 | granted=false |
| cn.cyberIdentity.certification | 35 | granted=false |
| com.quark.browser | 30 | granted=false |
| com.UCMobile | 30 | granted=false |
| com.chinamobile.mcloud | 32 | granted=false（也没在 xmsf 注册，可能从未打开过） |

这些包的 flags 只有 `USER_SENSITIVE_*`，没有 `USER_SET` 或 `REVIEW_REQUIRED`。HyperOS CN 由安全中心管理通知默认值，targetSdk 低于 33 的应用不会触发系统弹窗，所以会一直保持关闭。xmsf 替这些应用发通知时会被 NMS 直接丢弃。处理方法：“设置 → 应用 → 通知”里打开，或执行 `pm grant <pkg> android.permission.POST_NOTIFICATIONS`。这是用户自己的选择，模块不自动改。

## 4. 微信、QQ 的自建长连接与缺失的 Millet

- `millet_monitor`（`/system_ext/bin/millet_monitor`，init 服务）每约 9 s 崩溃重启一次：
  ```
  E millet_monitor: MILLET_EPOLL: failed to create socket for type 1
  I millet_monitor: MILLET_USER: millet exit
  I init: starting service 'millet_monitor'...
  ```
  `ro.millet.netlink=31` 对应的 netlink 协议在 RMX5010 内核里不存在（没有 Xiaomi millet 驱动，也没有 `/proc/sys/millet`）。所以 Greeze 的 `MilletEnable=false`。
- Greeze 仍会通过 cgroup freezer 冻结后台应用：亮屏时 `LM FZ`（launch mode），以及 `repeat` 等。冻结后的唤醒依赖 Millet 上报：`reportNet`（网络包到达，reason `packet`）、`reportSignal`、`reportBinderTrans`。没有 Millet，这三条都不会发生。
- 实测统计（开机约 45 分钟）：

| uid | 应用 | 冻结占后台时间 |
|---|---|---|
| 10314 | 微信 | 2% |
| 99910314 | 微信分身 | 55–64% |
| 10313 | QQ | 77–84% |

  冻结后靠 `alarm`、`pending_notify`、`broadcast` 或亮屏解冻，例如 `13:47:09 LM FZ ... 10314 ... 99910314 ... 10313`，之后 LM timeout THAW 没有包含这三个 uid，到 `13:47:25 THAW uid=10314/99910314 reason: pending_notify` 才解冻。
- 影响：分身微信的消息会延迟（等到下一次闹钟或亮屏）；主微信偶尔在亮屏后十几秒才收到；QQ 的实时通道多数时间处于冻结状态，但服务器会在离线时改走 MiPush，所以 QQ 通知仍能到，只是可能延迟。
- “省电策略：无限制”（写入 `settings system MILLET_NO_RESTRICT_APP`）只在 `triggerQuickFreeze` 里生效，不影响 LM 冻结，帮不上忙。
- **微信延迟的直接证据**（13:52–13:56，息屏，用户没在用手机）：
  ```
  13:52:52 LM FZ [1000] uid = [ ... 10314 99910314 ... ]      # 新通知点亮屏幕 → LM 冻结微信
  13:52:55 LM timeout THAW uid = [ ...不含 10314... ]
  13:54:34.917 THAW uid = 10314 reason : alarm               # 约 100 s 后才被闹钟解冻
  13:54:35.608/.636/.680 notification_enqueue com.tencent.mm  # 0.7 s 内连发 3 条积压消息
  13:54:36 Waking up from Dozing (details=com.android.systemui:NOTIFICATION)
  13:54:36 LM FZ [1000] uid = [ ... 10314 99910314 ... ]      # 刚亮屏又被冻上
  13:55:25.658 THAW uid = 10314 reason : alarm
  13:55:26.346/.361 notification_enqueue com.tencent.mm
  ```
  微信每次都是被闹钟唤醒后才把积压消息推成通知，而通知点亮屏幕又会立刻触发下一次 LM 冻结，形成循环。
- **绕过修复**：`AurogonImmobulusMode.handleDumpLM()` 支持 `dumpsys greezer LM add <pkg>`，把包加入 `mAllowList`（LM、IM 共用的放行名单；按包名生效，分身用户 999 也一起放行）。Greeze 在 `Settings.Secure immobulus_mode_switch_restrict`（云端下发，形如 `enable_24_allowlist_..._wakeuplist_com.tencent.mm_...`）变化时会用“本地+云端”重建 `mAllowList`，把这次加的清掉。云端只把微信放进 `wakeuplist`，依赖 Millet 的网络唤醒，所以本机必须自己补。
  - `ctl.sh apply-greeze-allow`：逐个执行 `LM add`，并记录云端字符串的 md5。
  - `ctl.sh check-greeze-allow`：md5 变化时重新执行 `LM add`；`service.sh` 每 600 s 调用一次。
  - 包列表：`settings global op13_fix_greeze_allow`，默认 `com.tencent.mm com.tencent.mobileqq`；设为 `none` 表示不加任何包。
  - 修复后实测（14:01–14:09，息屏，用户没在用手机）：这段时间 Greeze 历史里**没有任何 10314 的 FZ/THAW**（微信全程未被冻结）。`14:06:38.769 notification_enqueue com.tencent.mm` 是息屏时实时收到的，之前没有闹钟解冻；这条通知在 14:06:39 点亮屏幕，随后的 `LM FZ [1000] uid = [ 10293 99910277 10193 10218 10129 10105 10176 10297 10295 10305 ]` 也不含微信和 QQ。修复前，微信通知总是紧跟在 `THAW ... reason : alarm` 之后成批出现。
  - 验证：执行后亮屏，`14:00:50 LM FZ [1000] uid = [ 10293 99910277 10193 10218 10129 10176 10305 ]`，已不含 10314、99910314、10313；修改 `.greeze_cloud_sig` 后，`check-greeze-allow` 会重新执行，签名不变时不执行。
- 根治：把 Xiaomi 开源内核中的 millet 驱动（`millet_core/binder/pkg/sig`，netlink 31）移植为 GKI 外部模块，与 `rmx5010_fod_bridge.ko` 一起由模块加载。属于独立的较大任务，未在本次完成。

## 息屏实测

测试脚本 `/data/local/tmp/gmswatch.sh` 每 25 s 记录 `mWakefulness`、`mGmsLimitEnabled`、GMS 主进程（pid 6667）、GcmService 连接状态和 Greeze 冻结列表。

关闭 GMS 限制之后（13:52:43–13:56:32 连续 Dozing，近 4 分钟）：
```
13:52:43 wake=Dozing limit=false gms=6667 wchan=do_epoll_wait [Is client connected: true] Frozen processes:[12969, 17709, 20268, 26044]
13:53:09 wake=Dozing limit=false gms=6667 ... [Is client connected: true] Frozen processes:[3261, 12969, 16957, 16998, ...]
...
13:56:32 wake=Dozing limit=false gms=6667 ... [Is client connected: true]
```
这段时间内 6667 和 14303 都不在冻结列表里，Greeze 历史也没有 `FZ uid = 10277`。修复前，同样的息屏时长会在 60 s 时出现 `quick freeze`。GcmService 一直是 `connected=mtalk.google.com:5228`、`Is client connected: true`。

还没做：用另一台设备给 Telegram 等 FCM 应用发消息，测息屏下的实际到达延迟（需要用户操作）。
