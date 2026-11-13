# 游戏 24fps 诊断记录（laohu / Blue Archive / 全局策略）

日期：2026-10-28
状态：**已定位并修复**（实测 60Hz / 约 69 帧每秒）

## 结论

不是系统帧率上限，也不是 Game Turbo 的 24fps 锁。根因是 **GameManager 把该游戏的
当前模式重置回了 `standard`**：per-game 的 custom 配置（`Fps:60`）还在，但没有生效，
SurfaceFlinger 就按游戏实际提交的 24 帧走。

```text
cmd game list-modes com.hottagames.yh.laohu
  current mode: standard, available: [standard,custom]
```

在游戏运行时执行：

```text
cmd game set --fps 60 com.hottagames.yh.laohu
dumpsys SurfaceFlinger
  GameFrameRateOverrides={10310, 60 120}
  setFrameRate={10310, 60.00 Hz}
  renderRate=60.00 Hz
```

实测帧计数从约 24 帧/秒变成约 69 帧/秒，24Hz 累计时间停止增长。

## 第二例：Blue Archive（com.nexon.bluearchive）

2026-10-28 01:33 用户前台游戏变成《蔚蓝档案》，仍然 24Hz。检查发现：

```text
cmd game list-modes com.nexon.bluearchive
  current mode: standard
SurfaceFlinger:
  GameFrameRateOverrides={10328, 0 120}
  setFrameRate={10328, 24.00 Hz}
```

这次是 **Blue Archive 自己调用了 `Surface.setFrameRate(24)`**，而 GameManager
没有该游戏的 custom 规则，default override 120 不会覆盖 app 的显式请求。执行：

```text
cmd game set --fps 60 com.nexon.bluearchive
```

后变为：

```text
current mode: custom
GameFrameRateOverrides={10328, 60 120}
setFrameRate={10328, 60.00 Hz}
renderRate=60.00 Hz
```

## 不再维护游戏名单，也不压 120Hz

KSU 1.3.9 的 `game_fps.sh` 改成自适应策略，不再需要手动列包名：

1. 每 5 秒看一次前台包，用 `cmd game list-modes` 识别它是不是游戏；
2. 如果游戏当前是 custom，直接不动；
3. 如果游戏已经通过 `Surface.setFrameRate` 请求了 **30/60/90/120Hz**，
   直接放过，不改它的模式；
4. 只有请求 **24Hz 或启动 3 秒内没有任何请求** 时，才应用 fallback 60；
5. 新安装的游戏第一次打开就自动处理，不需要改名单。

因此支持 120Hz 的游戏不会被压到 60；会被处理的只有“本来就只请求 24Hz”或
“GameManager 没给帧率”的那一类。个别游戏如果启动时先请求 24、几秒后才切
120，仍然可以在 `/data/adb/rmx5010_game_fps.conf` 写 `package:120` 覆盖。

验证（把 Blue Archive 手动切回 standard，SF 报告 24Hz）：

```text
01:48:00 apply com.nexon.bluearchive fps=60 (requested 24.00Hz)
cmd game list-modes -> current mode: custom
renderRate=60.00 Hz
```

如果 SF 报告的是 `requested 120.00Hz`，日志会是 `leave ...: requested 120Hz`，
不会写 custom 60。

## 根因

`GameManagerService.updateConfigsForUser()` 在开机时会对每个已安装游戏调用
`getNewGameMode(gameMode, GamePackageConfiguration)`。这里的
`GamePackageConfiguration` 是基础配置，不包含 custom 模式；custom 的
`Fps:60` 只存在于单独的 config override 里。于是：

```text
getGameMode()        -> 4 (custom，来自 XML)
getNewGameMode(4, baseConfig) -> 1 (standard，因为 baseConfig 没有 custom)
setGameMode(pkg, 1)  -> 当前模式改写为 standard
writePersistentDataLocked() -> XML 里 gameMode 写成 1
```

`cmd game list-configs` 仍显示 `Fps:60`，因为 `mConfigOverrides` 还在；但
`cmd game list-modes` 已经是 standard，实际不生效。XML 字节可以确认：
修复前 `gameMode` 属性是 `00 00 00 01`，执行一次
`cmd game set --fps 60` 后才是 `00 00 00 04`。

GameManager 的 `writePersistentDataLocked()` 还有 10 秒延迟和
`chmod ... ENOENT` 警告；如果在 10 秒内重启，custom 状态连 XML 都来不及写。
这也是为什么“设完 60 马上重启”会丢。

## 自动修复（KSU 1.3.9）

- Sense 的 `SystemServerHooks` hook 了 `GameManagerService.getNewGameMode`，
  用于保留已有 custom 模式；但 LSPosed 在 system_server 的注入时间晚于
  GameManagerService 的首次 `updateConfigsForUser`，不能依赖它处理第一次开机。
- `game_fps.sh` 不再维护包名列表，也不在开机时把所有游戏改成 60：
  - 前台 5 秒轮询，只有识别为游戏且当前模式不是 custom 时才继续；
  - 读取该游戏 UID 在 SurfaceFlinger 的 `(uid, frameRate)` 请求；
  - `>=30Hz` 直接放过（30/60/90/120 都保留游戏自己的选择）；
  - 只有 `24Hz` 或 3 秒内无请求时，才应用 fallback（默认 60）；
  - 新装游戏第一次打开自动纳入；`/data/adb/rmx5010_game_fps.conf` 只用于
    特殊覆盖，不写也能工作。

验证 Blue Archive：

```text
01:48:00 apply com.nexon.bluearchive fps=60 (requested 24.00Hz)
cmd game list-modes -> current mode: custom
renderRate=60.00 Hz
```

如果请求是 120Hz，日志会是 `leave ...: requested 120Hz`，不会写 60 覆盖。
回退单个游戏：`cmd game reset <package>`。彻底停用：删除模块或注释
`service.sh` 里启动 `game_fps.sh` 的两行。

## 已排除

### 1. 不是 Game Turbo 的 24fps 锁

```text
/data/data/com.miui.securitycenter/shared_prefs/game_box_ve_helper.xml
  gamebooster_perf_cache_frame_com.hottagames.yh.laohu = 23
```

反编译 `MIUISecurityCenter.apk`（classes3.dex）：

- `h1.a(pkg)` 只负责生成 key；
- `newpanel.b.m()` 读取该值作为面板默认显示；
- `newpanel.b.h()` 在 `onFpsSample` 后把实测帧率写回该 key。

它只是测量缓存；修复后实际 60Hz，但该缓存仍可能停留在 23，需等 Game Turbo
重新采样/面板刷新。

### 2. 不是显示模式上限

`activeMode` 一直是 120Hz；24 是 SF 的 `renderRate`，由游戏提交的帧节奏决定。
标题页曾实测约 66 帧/秒，24Hz 计数不增长，说明系统本身能跑 60+。

### 3. 不是 QESDK/QAPE 崩溃导致

QESDK/QAPE 的 seccomp 问题确实存在并已修复（见
`docs/QESDK_QAPE_seccomp修复.md`），但它不是本次 24 的直接原因；修复 QESDK 后
游戏仍可能因 GameManager 模式回退而锁 24。

### 4. ACE 反作弊

游戏带 ACE：

```text
/data/data/com.hottagames.yh.laohu/files/ace_shell_di.dat
/sdcard/Android/data/com.hottagames.yh.laohu/files/UnrealGame/HT/HT/Saved/Config/Android/GameUserSettings.ini（加密）
```

用户明确警告：Frida 注入会被反作弊检测。实测多次 Frida spawn/attach 后，
游戏进程约 9~20 秒无 crash 日志退出（`am_proc_died reason=2`），
与 ACE 主动退出特征一致。**已停止并删除 Frida server、端口转发和临时文件，
后续不再注入该游戏。**

### 5. 游戏配置不可直接读

- `GameUserSettings.ini` / `Engine.ini` 均为 ACE 加密（base64 样式，非明文）。
- `configrules.cache` 是 Java 序列化 HashMap，能看到设备画像：
  `SRC_DeviceModel=2410DPN6CC`、`SRC_DeviceMake=Xiaomi`、`SRC_GpuFamily=Adreno (TM) 830`、
  `SRC_AndroidVersion=17`、`targetSdkVersion=30`、`configRulesVersion=0`、
  `OverrideProfile=true`。
- 游戏 APK 内 `libMFRCConfig.so` 只有 `VK_MFRC_CONFIG` / 版本字符串，未发现 24 的明文配置。

## 同时发现并已修复的系统问题

QESDK/QAPE/syshealthmon 的 seccomp allow-list 缺 `lseek`，导致三者每 5 秒
SIGSYS，qseelogd 空转 110% CPU，swap 7.1GB。该问题会让 QAPE 游戏性能策略
完全失效，已由 KSU 1.3.9 修复。详见 `docs/QESDK_QAPE_seccomp修复.md`。

## 当前系统侧保留项

- KSU 1.3.9 的 `game_fps.sh` 会在游戏进程存活时自动维持 custom 60。
- 当前会话已实测 60Hz / 约 69fps；24Hz 计数不再增长。
- 未修改游戏数据、未改 `GameUserSettings.ini`、未注入游戏。
- 回退当前游戏：`cmd game reset com.hottagames.yh.laohu`。

## 2026-10-29 追加：游戏内静置 24Hz（1.4.1 连续采样）

旧 1.3.9 策略在游戏加载时看到 `(uid, frameRate)=120` 后把状态标成 `native` 并停止处理，
同一个前台会话里游戏静置改为 24Hz 时就不再管；实测 Blue Archive：

```text
01:46:33 leave com.nexon.bluearchive: requested 120.00Hz
（静置后）
(uid, frameRate)={10328, 24.00 Hz}
cmd game list-modes -> standard
```

1.4.1 改为**连续采样**，不再把 `native` 当成终态：

- 前台游戏每 2 秒重新读取 SF `(uid, frameRate)`；
- ≥30Hz 只记录本会话峰值，不写 GameManager；
- 24Hz 或没有请求持续 5 秒后，按 `max(fallback 60, 峰值)` 应用 custom，峰值最高 120；
- 应用后 `cmd game list-modes` 变 custom；若被系统/用户清回 standard，会自动重新判断；
- 仍无包名名单，新装游戏自动纳入；`/data/adb/rmx5010_game_fps.conf` 可覆盖单包 floor。

实测日志：

```text
02:?? observe com.nexon.bluearchive: requested 120.00Hz (peak 120.00Hz)
02:?? apply com.nexon.bluearchive fps=60 (requested 24.00Hz, peak 24.00Hz):
     Set custom mode ... fps-override: 60
cmd game list-modes -> custom
(uid, frameRate)={10328, 60.00 Hz}
```

说明：若采样期间焦点短暂切到通知栏/桌面，峰值会按新前台会话重置，此时静置 24 会回落到
60 而不是 120；这是有意的，避免把一次瞬时 120 请求永久固化成 120Hz 待机。用户若要某游戏
固定 120，可在 `/data/adb/rmx5010_game_fps.conf` 写 `包名:120`。

## 2026-11-13 追加：群友反馈"部分游戏十几 Hz"——24Hz 不是游戏申请的，1.4.1 的抬帧一直失败

### 现象（Blue Archive 主界面，游戏内只有 30/60 两档）

```text
mode=standard
(uid, gameModeOverride, gameDefaultOverride)={10312, 0 120}
setFrameRate=
    (uid, frameRate)={10312, 24.00 Hz}
renderRate=24.00 Hz   activeMode vsyncRate=120.00 Hz
timestats: SurfaceView[com.nexon.bluearchive/...](BLAST)  averageFPS = 23.810
```

触摸后由 SF 触摸升帧拉回 120Hz（游戏实测 62.5fps），触摸定时器到期（`touchTimer=3000.000 ms`）后又掉回 24。

### 24Hz 来自系统，不是游戏

- 24Hz 时游戏的所有图层都没有 `requestedFrameRate`，HWC 图层表 `Frame Rate (Explicit)` 一栏为空，即游戏没有调用 `setFrameRate`。
- system_server 记录的是**整屏**渲染档降到 24，并且不是按 uid 覆盖：
  ```text
  20:06:16.452 DisplayDeviceRepository: Display device changed render timings: "内置屏幕",
    renderFrameRate=24.000002, ... frameRateOverrides=[]
  ```
- AOSP SurfaceFlinger 在 `ContentDetection=false`（`ro.surface_flinger.use_content_detection_for_refresh_rate=false`）下不会按内容降帧。
  小米改过的 `/system_ext/lib64/libmisurfaceflinger.so` 里有按内容平均帧率 / 视频帧率调档的逻辑，相关字符串：
  `isPrimary=%d, avgFrameRate=%d, mInSmallDamageInfo=%d ... touchHint=%d`、`setVideoFps ...`、
  `updateVideoDecoderInfo mVideoFrameRateSnapshot`。Blue Archive 主界面同时在用 `c2.qti.vp9.decoder` 播放背景视频。
  所以结论是 MiSF 的动态帧率策略把游戏当成了低帧内容。具体是视频分支还是平均帧率分支触发的，还没有反汇编确认。
- 降到 24 后，游戏的 Choreographer 每秒只收到 24 个 vsync，出帧不可能超过 24，形成自锁，只有触摸能暂时解开。

### 十几 Hz 的来源（推断，这台机上没有直接复现）

SF 只会使用档位表 `20/24/30/40/60/120` 里的渲染档，最低 20Hz。实测用 GameManager 设 15/12 时，SF 不接受，改给 60/120；
设 20 时游戏实测 `averageFPS = 20.000`。所以不会存在 10–15Hz 的显示档位。十几帧应该是较重的游戏被锁在 24Hz/20Hz
的 vsync 上，赶不上某个 vsync 就只能隔一个出一帧（24→12、20→10）。

### 1.4.1 为什么没把它抬起来

```text
19:47:22 apply com.nexon.bluearchive fps=120.00 (requested 24.00Hz, peak 120.00Hz): Invalid frame rate: '120.00'
```

1. SF 打印的帧率是 `120.00`，脚本原样传给 `cmd game set --fps`；GameManager 只接受整数，`120` 可以，`120.00` 会被拒绝。
   只要游戏本会话出现过 120（触摸升帧时**任何**游戏都会显示 120），掉到 24 后的抬帧就一直失败。
2. 即使改成整数 120 也没有用：GameManager 设成 120（等于面板刷新率）时 SF 视为"不限制"，实测仍是 `renderRate=24`。
   GameManager 设 60（或 90，SF 取 60）才有效：`gameModeOverride=60` → `renderRate=60`，实测 62.5fps。
3. SF backdoor（`service call SurfaceFlinger 1039 i32 <uid> f 120`）可以强制到 120Hz，实测 Blue Archive 58fps；
   `f 0` 只清除该 uid 的覆盖。

### 修复（game_fps.sh，KSU 1.7.20）

- 删除"本会话峰值"逻辑，因为触摸升帧让它失去意义；自动下限固定为 `default`（60），走 GameManager custom。
- 写入前取整（最高 120），GameManager 不会再因为带小数而拒绝。
- conf 里 `包名:90`/`包名:120` 这类大于 60 的下限改走 SF backdoor（uid 覆盖），游戏离开前台时用 `f 0` 清掉。
- 代价：自动下限为 custom 60 的游戏会全程封顶 60；真正支持 120 的游戏需要在 conf 里写 `包名:120`。

实机验证（重置为 standard 后回到主界面）：

```text
20:13:36 renderRate=24.00Hz  gameModeOverride=0   averageFPS = 23.815
20:13:39 apply com.nexon.bluearchive fps=60 (was 24.00Hz): ... fps-override: 60
20:13:40 renderRate=60.00Hz  gameModeOverride=60  averageFPS = 61.830
20:13:44 ~ 20:14:31 averageFPS = 62.4 ~ 62.6（静置 + 触摸都不再低于 60）
```

conf 写 120 的 backdoor 分支：这次测试中游戏没有再掉到 24，没有走到这条分支；只验证过手动 `1039 ... f 120` 有效。

### 顺带发现（未处理）

Blue Archive 日志每秒刷几千行 `MediaCodec: Invalid to call at Released state` / `Unity AndroidVideoMedia::GetNextVideoFrameRaw bad buffer index: -10000`。
背景视频的 VP9 解码器已经被释放，Unity 仍在轮询，`logd` 因此被拖到 40%+ CPU。原因待查，可能和 MiSF 认为视频一直在播放有关。

## 2026-11-13 晚：120 帧游戏被 1.7.20 压到 60 → 按实测帧数自动选档

群友反馈：游戏本身是 120 帧，装 1.7.20 后被压到 60。原因是 1.7.20 在锁 24 时写入 GameManager custom 60，
这个设置会持久保存，而且对该 uid 是上限，此后游戏每一局都封顶 60。

### 各种抬帧手段实测（Blue Archive，先确认已锁在 24Hz）

| 手段 | 结果 |
|---|---|
| GameManager `--fps 60` / `61` | renderRate 60，62.5fps ✅ |
| GameManager `--fps 90` | SF 取 60 |
| GameManager `--fps 100` | renderRate 120，uid 120（游戏不被限到 100），62.5fps ✅ |
| GameManager `--fps 119` / `120` | 被忽略，仍是 24Hz / 23.8fps（与 `ro.surface_flinger.game_default_frame_rate_override=120` 相同或几乎相同） |
| SF backdoor `1039 i32 uid f 60/120` | 只能**限制**该 uid 的帧率，整屏被锁 24 时设 60 仍是 24；成功时返回 `Result: Parcel(NULL)` |
| Joyose 广播 `com.xiaomi.joyose.OVERRIDE_GAME_FRESHRATE` | 无效果 |
| `display` 私有事务 `0xfffff8`（`appRequestChangeSceneRefreshRate`，接口名 `android.view.android.hardware.display.IDisplayManager`，参数为包名 + fps，uid<10000 可调） | `mRefreshRatePackages` 能写入，但要等窗口有变化才生效，13 秒内仍是 24，不可靠 |

结论：能把帧率**抬上去**的只有 GameManager 的覆盖值（它作为游戏图层的投票）。最高档要投"最高档 − (最高档 − 次高档)/3"
（60/120 机型上是 100），SF 会取到最高档，且不会把游戏限在这个值。

### 新策略（game_fps.sh）

- 渲染档位从 SF 的 `mAppRequestFrameRates` 读取，不写死 60/90/120。
- 游戏没被锁且渲染档在最高档时，用 `dumpsys SurfaceFlinger --latency <图层>` 按游戏图层的实际呈现时间算帧率，
  每 10 秒最多测一次，最高值记到 `/data/adb/rmx5010_game_fps.learned`。
- 锁到 <30Hz 持续 5 秒后，选"≥ 实测帧数 × 0.9 的最小档"，下限 60：实测 62 → 60，88/90 → 120（本机没有 90 档），118 → 120。
  没测过的游戏先按最高档试测 2 秒。
- 被限在较低档、并且游戏一直顶满这一档时，会放开到最高档试测：先每 30 秒一次，没升档就翻倍间隔，最长 5 分钟。
  这样在菜单里学到 60 的 120 帧游戏，进入实战后能升到 120。试测不写入 managed，进程中途被杀也不会留下临时档位。
- 脚本设置过的游戏记在 `/data/adb/rmx5010_game_fps.managed`，跨重启继续管理；其他 custom 模式视为用户设置，不动。
  1.4.1~1.7.20 留下的 `Fps:60` custom 会对每个包自动重置一次（记录在 `.migrated`）。
- conf：`包名:120` 表示固定档位（按选档规则取档），`包名:off` 表示不管这个游戏，`default:N` 修改下限。

实机（Blue Archive，游戏内上限 60）：

```text
21:23:54 learn com.nexon.bluearchive: 60fps at 120.00Hz (was none)
21:24:01 apply com.nexon.bluearchive 60Hz (learned 60fps; was 24.00Hz)
21:24:29~21:25:15 averageFPS 62.4~62.6；每 30 秒放开到 100 试测一次，仍约 62fps，保持 60 档
11-13 21:11:11 reset legacy GameManager custom 60 for com.nexon.bluearchive
```

未验证：手头没有 120 帧游戏，"试测后升到 120"这条路径没有完整跑过；只单独验证了 GameManager 100 能把锁 24 的游戏抬到 120 档。
