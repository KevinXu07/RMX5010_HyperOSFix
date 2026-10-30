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
