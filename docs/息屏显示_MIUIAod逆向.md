# 小米息屏显示（MIUIAod）完整逆向 + 一加 13 模块 AOD 优化对照（2026-11-11）

反编译对象：`com.miui.aod`（MIUIAod.apk，OS4.0.0.19 提取）
反编译环境：apktool 2.7.0（classes.dex → 10,600 smali）+ baksmali 2.5.2（classes2.dex → 11,023、classes3.dex → 574）
对照对象：`E:/code/modify/os4/external/OP13HyperOSFix`（一加 13 澎湃 OS4 综合修复模块）与本仓库 `lsposed-src/`（gt7profodfix，RMX5010 现行模块）
实机：RMX5010 / haotian / Android 17 / HyperOS OS4.0.0.19；已接实机做过一轮**只读探测**（结果见 §16），仍无法只读确认的项在文中显式标注（§19）

---

## 1. 包体与构建信息

| 项 | 值 |
|---|---|
| package | `com.miui.aod` |
| sharedUserId | `android.uid.system`（system_app，UID 1000） |
| versionCode / versionName | `22446301` / `DEV-2446.3.0.1-09042206` |
| compileSdk / targetSdk / minSdk | 36 / 36 / 33 |
| APK 大小 | 57,598,559 字节 |
| dex | classes.dex 8,953,848（app 主体）；classes2.dex 9,981,628（keyguard editor + maml + miwallpaper）；classes3.dex 484,040（miuix / okio / org，纯第三方） |
| resources.arsc | 11,447,144 |
| 原生库 | `libMiMainColor.so`(362K，取色)、`libfastplayer.so` + `libmiffmpeg_fastplayer.so`(3.5M，MAML 视频播放)、`libmievent.so`、`libmmkv.so` |
| 进程 | 默认 `com.miui.aod`；编辑器 `com.miui.aod:keyguardeditor` |
| Application | `com.miui.aod.AODApplication`，`appComponentFactory=com.miui.aod.AODAppComponentFactory`，`directBootAware=true` |

### 1.1 classes2 的构成（此前 apktool 未解出，本次用 baksmali 补齐）

| 包 | smali 数 | 作用 |
|---|---|---|
| `com.miui.keyguard` | 2,516 | 锁屏/AOD 共用的时钟编辑器（editor）、快捷方式（shortcuts） |
| `com.miui.maml` | 686 | MAML 动态主题引擎 |
| `com.miui.miwallpaper` | 238 | 超级壁纸/壁纸服务侧接口 |
| `com.miui.lockscreeninfo` | 51 | 锁屏信息服务 |
| `com.miui.keyguardtemplate` | 12 | 模板接口 |
| `com.miui.wallpaperglassshader` | 18 | 玻璃/景深 shader |
| 其它 | — | `keyguardeditor`、`videodownload`、`misight` |

关键结论：**classes2 里没有 `com.android.keyguard.fullaod.MiuiFullAodManager`**。全屏 AOD 的"管理器"在 SystemUI 侧，MIUIAod 只是被通知方（见 §7）。

### 1.2 Manifest 组件全表

| 类型 | 组件 | 说明 |
|---|---|---|
| service | `com.miui.aod.doze.DozeServicePluginImpl` | **核心**，实现 `com.android.systemui.plugins.DozeServicePlugin`，action `com.android.systemui.action.PLUGIN_DOZE` |
| service | `com.miui.aod.analy.AnalyticalDataCollectorJobService` | JobScheduler 定时上报 |
| service | `com.miui.aod.theme.ThemeResourceClearJobService` | 清理过期主题资源 |
| service | `com.miui.keyguard.editor.KeyguardEditorService` | action `com.android.systemui.action.KEYGUARD_EDITOR`，进程 `:keyguardeditor` |
| service | `com.miui.keyguard.shortcuts.ShortcutPluginImpl` | `com.android.systemui.action.PLUGIN_MIUI_SHORTCUT` |
| service | `androidx.appfunctions.service.PlatformAppFunctionService` / `ExtensionAppFunctionService` | Android 16 AppFunctions（Gemini） |
| activity | `settings.AodShowModeSettingActivity` | 显示方式设置 |
| activity | `settings.AODStyleActivity` / `AODStyleCategoryActivity` / `AodStyleCategoriesActivity`（action `com.miui.aod.style_list`，OS4 新）/ `AodStyleCategoriesActivityForPad`（`com.miui.aod.style_list_pad`） | 样式列表 |
| activity | `settings.AodStyleSelectActivity` / `AodWidgetComponentActivity` / `HistoryListActivity` / `NotificationAnimationSelectActivity`（`com.miui.aod.notification_animation`） | 选样式 / 组件 / 历史 / 通知动画 |
| activity | `settings.RouterActivity` | `miui.aod.action.router`，深链 `aod://com.miui.aod/style_select/custom_image` |
| activity | `com.miui.keyguard.editor.*`（EditorActivity、EditorActivityForSettings、CommonEditorActivity、CommonDialogActivity、HistoryActivity） | 锁屏编辑器，actions `miui.keyguard.editor` / `.common` / `.common_dialog` / `.history` / `.settings`，进程 `:keyguardeditor` |
| provider | `settings.SettingsProvider`（authority `com.miui.aod.settings`） | call 接口见 §12.1 |
| provider | `db.StyleDataProvider`（`com.miui.aod.StyleDataProvider`） | `content://…/theme`、`/history` |
| provider | `part.PartProvider`（`aod.part`） | `content://aod.part/part`，跨进程提供预览图 |
| provider | `superwallpaper.SuperWallpaperProvider`（`com.miui.aod.superwallpaper`） | 超级壁纸时钟图 |
| provider | `aiaction.AiActionAodProvider` | AI 动作（见 §12.3） |
| provider | `com.miui.aod.SettingsSearchProvider` / `androidx.core.content.FileProvider` / `com.miui.keyguard.editor.data.template.TemplateFileProvider` | 搜索索引 / 文件 / 模板 |
| receiver | `theme.ThemeReceiver` | `com.android.thememanager.AOD_CHANGED` |
| receiver | `androidx.profileinstaller.ProfileInstallReceiver` | baseline profile 安装 |

签名级权限：`com.miui.aod.EDIT_AOD_SETTING`。
受保护广播：`miui.miwallpaper.action.ACTION_AOD_OFFSET`。
关键 meta-data：`os_private_label=PRIVATE_OS040`、`editor_os_version=0x40`、`keyguardtemplate 1.2.0.0/1200`、`clock 1.4.3.7/1437`、`miui.supportFlipFullScreen=0`、`support_wallpaper_stream=true`、`aodPackageChanged=true`、`ignore_rro_relaunch=true`。

---

## 2. Doze 插件与状态机

### 2.1 插件入口

`DozeServicePluginImpl` 实现 SystemUI 的 `DozeServicePlugin`：

```
create()  -> 初始化 AODApplication / SettingsHolder / AodViewManager / MMKV /
             BatteryController / SuperWallpaperReceiver / ThemeResourceClearJobService
             注册 basic / inversion / miui_optimization 观察者、SmartCoverReceiver
onCreate() / onDreamingStarted() / onDreamingStopped() /
onRequestFocusView() / onSystemUIAction() / setDozeRequester()
```

`setDozeRequester(RequestDoze)` 是**双向通道**：AOD 可以主动向 SystemUI 发请求（全屏 AOD、时钟隐藏、屏幕状态等），见 §7。

### 2.2 状态（DozeMachine$State）

枚举序号（ordinal）与 `screenState()` 返回值：

| 状态 | ordinal | `screenState()` |
|---|---|---|
| UNINITIALIZED | 0 | `needKeepScreenOnAtFirst() ? 2 : 1` |
| INITIALIZED | 1 | 同上 |
| DOZE | 2 | 1（OFF） |
| DOZE_AOD | 3 | 4（DOZE_SUSPEND）；`isVideoScreenDevice \|\| isMiuiOptimizationDisabled` 时 3（DOZE） |
| DOZE_REQUEST_PULSE | 4 | 2（ON） |
| DOZE_PULSING | 5 | 2（ON） |
| DOZE_PULSE_DONE | 6 | 0 |
| FINISH | 7 | 0 |
| DOZE_AOD_PAUSED | 8 | 1（OFF） |
| DOZE_AOD_PAUSING | 9 | 4 或 3（同 DOZE_AOD） |
| DOZE_INTO_COVERMODE | 10 | 0 |

`screenState()` 用 `DozeMachine$1.$SwitchMap` 把 ordinal 映射为 1…11 的 case 号（`DOZE=1, DOZE_AOD=2, PAUSED=3, PAUSING=4, REQUEST_PULSE=5, PULSING=6, UNINITIALIZED=7, INITIALIZED=8, FINISH=9, PULSE_DONE=10, COVERMODE=11`），再 `packed-switch`。**注意：`DOZE_AOD=2`、`DOZE_AOD_PAUSED=3` 这类数字是 `$SwitchMap` 的 case 号，不是枚举 ordinal；写 hook 或打日志时两者不能混用。**

### 2.3 DozeFactory 组装（11 个 `DozeMachine$Part`）

> 数组大小 `0xb`=11，由 `DozeFactory` 一次性 `setParts()`。下面按功能列出（寄存器交错较多，**不要假定数组下标等于执行顺序**；要精确顺序请直接看 `DozeFactory` 的 `aput-object` 序列）。

1. `MiuiAodService` — 对外 AIDL/Binder 面
2. `DozePauser` — 无操作超时后 AOD→PAUSED
3. `DozeTriggers` — 触发源（无自身传感器注册，向 Service/Host 转发）
4. `MiuiShowStyleController` — **显示模式核心**
5. `DozeWallpaperState` — 壁纸可见性
6. `DozeUi` — 通知/动画驱动
7. `MiuiFocusNotification2` — 焦点通知
8. `DozeScreenState` — 屏态应用（含 FOD 按压延迟 1s）
9. `MiuiDozeScreenBrightnessController` — 亮度/传感器
10. `MiuiBgController` — 背景
11. `DozeLifecycleOwner`

Service 侧另有 4 个屏态适配器：`MiuiGxzwDozeStatePreventingAdapter`（指纹）、`MiuiAnimDozeStatePreventingAdapter`（动画）、`MiuiDozeBrightnessTimeoutAdapter`、`MiuiFullAodAdapter`（全屏 AOD 时跳过亮度设置）。

---

## 3. 显示模式（`aod_show_style`）

### 3.1 取值

| 值 | 名称 | 行为 |
|---|---|---|
| 0 | temporary（轻触） | 点按/单击后显示 `getTemporaryStyleDuration()` 毫秒，然后熄灭 |
| 1 | scheduled（定时） | 仅在 `[aod_start, aod_end)` 窗口内显示 |
| 2 | always（全天） | 常亮显示 |
| 3 | smart（智能） | 依赖 AON（`com.xiaomi.aon`）的人在看屏幕检测 |

### 3.2 默认值推导（重要，和机型定制强相关）

```
getDefaultShowStyle(ctx):
    if DeviceUtil.isPad():                      return 3
    if isFsAodSameToLock(ctx) && AttentionManager.supportAttention(ctx):  return 3
    return AODSettings.AOD_SHOW_STYLE_DEF
```

```
AOD_SHOW_STYLE_DEF = !isDefaultTemporaryStyle()
isDefaultTemporaryStyle() = onlySupportKeycodeGoto() || FeatureParser("is_default_temporary_style")
onlySupportKeycodeGoto()  = FeatureParser("is_only_support_keycode_goto")
```

RMX5010 的 `haotian.xml`：`is_default_temporary_style=true`、无 `is_only_support_keycode_goto` → `AOD_SHOW_STYLE_DEF = 0`。
**推论：RMX5010 出厂默认是"轻触后显示 10 秒"，而不是定时/常亮。**（§16 实测：`aod_show_style` 在 settings 里未设置，确认走默认 0，推论成立）

### 3.3 轻触模式的时长

`Utils.getTemporaryStyleDuration()`：机型为 `psyche` / `zeus` / `cupid` 且**未使用超级壁纸**时返回 `5000`，其它一律 `10000`。RMX5010 不走前三个机型分支 → 10 s。

`MiuiAodService.dispatchKeyEvent()` 收到 keyCode **354（0x162）** 的 ACTION_DOWN 时，如果 AOD 未 `aodGone` 且当前是 temporary 模式，会重新 `requestDrawWakelock(getTemporaryStyleDuration())` 并刷新 AODView —— 即"再按一次 F4 可续 10 秒"。这条链路正是一加 13 模块注入 354 的落点（见 §13.3）。

### 3.4 定时窗口

- `aod_start` 默认 `0x1a4 = 420`（07:00），`aod_end` 默认 `0x564 = 1380`（23:00），单位分钟。
- `aodDisabledForScheduleMode()` 名字有误导性：**它返回"当前是否在窗口内"**。
- `MiuiShowStyleController.onAodFire()`：style 1 时 `if (!在窗口内) hide`，即在窗口内才显示。
- `checkTime()`：窗口内设 `mHideTime = end - now`；窗口前设 `mHideTime = end - now`；窗口后设 `mShowTime = start - now + 24h`。
- `scheduleTimingStyle()`：用 `mShowTime` 调度 `mShowDozeTimeout→showDoze()`，用 `mHideTime` 调度 `mHideDozeTimeout→hideDoze()`。

### 3.5 其它开关

- `doze_always_on`：AOD 总开关（`isAodEnable`）。
- `aod_mode_user_set`：用户是否手动改过模式（决定首次引导与备份）。
- `aod_mode_time`：设置页里选择的"定时"预设（SettingsHolder 观察）。
- `aod_style_state`、`aod_category_name`：样式/分类选择。
- `power_supersave_mode_open` + `permit_disable_aod_in_power_save_mode`：极限省电下是否关 AOD。

---

## 4. 视图层

### 4.1 AOD 视图层级

`aod_content.xml`：

```
LinearLayout aod_content_container (gravity=center|top，垂直)
├── include clock_content  (@id/content，运行时由 AODView 充入具体时钟布局)
├── ViewStub battery_step_container_vs -> battery_step_layout
│     └── GradientLinearLayout：aod_battery + ViewStub step_widget_layout
├── ViewStub notification_icons_vs -> aod_icons
│     └── NotificationContainer
│          ├── LinearLayout fn_container   (焦点通知)
│          └── LinearLayout icons: first / second / third / forth / more_notification_icon
└── ViewStub image_share_tip -> message_layout
```

- 图标 4 个 + more：`icon_size=26dp`、`icon_margin_start=14dp`、容器左 padding `icon_container_margin_start=10dp`。
- big_time 变体：`big_time_icon_size=28dp`、`big_time_icon_margin_start=16dp`，more 图标默认 gone。
- 有通知时时钟上移：`aod_notification_clock_margin=98dp`，全屏 AOD 时 `aod_notification_clock_margin_full=164dp`；自定义时钟另有 `aod_notification_custom_clock_margin_top(34/46dp)`、`margin_start(12/50dp)`。

### 4.2 布局族（res/layout）

`aod_content` 下按样式切换的布局：`big_time`、`blank_super_wallpaper`、`clock_svg`、`horizontal[_dual|_small|_left|_togother|_p]`、`linkage`、`linkage_flip`、`maml`、`oneline[_dual|_small]`、`scope[_dual|_small]`、`signature[_bitmap|_dual|_small]`、`sun[_dual|_small]`、`super_wallpaper`、`vertical[_dual|_small]`。
`aod_icons` / `aod_icons_big_time` / `aod_icons_flip` 三套通知布局。

### 4.3 样式类别（CategoryConstants）

在线/内置：`my_aod_style`、`signature`（签名）、`panel_clock`、`kaleidoscope`、`digital_time`、`chosen_picture`、`theme`。
本地预设（`CategoryFactory` 构造，`presets` 以 `{"bg"/"color"/"panel"/"is_vertical"/"is_left_gravity"}` JSON 参数区分）：

`white/pink/blue_horizontal`、`paint_horizontal`、`white/pink/blue_vertical`、`paint_vertical`、`shadow_vertical`、`moonlight_vertical`、`tree/spirit/succulent/cactus/ghost/spaceman_oneline`、`sun`、`white_horizontal_left`、`clock_panel_first/second/third`、`horizontal`、`vertical`、`horizontal_left`、`linear_timetext`、`oneline`、`scope`、`animate_clock_panel`、`text_style`、`image_bg_selector`、`maml`、`smart_cover`、`super_wallpaper`、`blank_super_wallpaper`、`Linkage`、`big_time`。

Device 差异：Pad 默认 `big_time`，其它默认 `Linkage`。OS4 样式列表顺序：`Linkage, big_time, animate_clock_panel, clock_panel, oneline, sun, scope, paint_vertical, text_style, linear_timetext, image_bg_selector, smart_cover, super_wallpaper`。

旧类别 `horizontal/vertical/horizontal_left` 已废弃（仅保留兼容）。

### 4.4 时钟视图实现（widget/）

| 类 | 用途 |
|---|---|
| `LinkageClock` / `LinkageClockKt` / `LinkageStyleClockView` | 默认样式，锁屏时钟以"联动"方式缩放到 AOD |
| `FlipLinkageClock` / `FlipILinkageClock` / `FlipLinkageClockKt` | 折叠/翻页联动 |
| `MiuiClockView`（com.miui.clock）、`AODTinyMiuiClockView` | 复用锁屏时钟控件 |
| `BigTimeClock` / `BigTimeAodView` / `BigTimeTopContainerView` | Pad/大字 |
| `ClockSVGTimeView` / `IClockSVGView` | SVG 数字 |
| `MamlClock` / `MamlViewContainer` | MAML 动态主题 |
| `SuperWallpaperClock` / `BlankSuperWallpaperClock` | 超级壁纸 |
| `SmartCoverClock` / `SmartCoverClockBView` | 智能保护套 |
| `SunClock`、`ScopeClock`、`PaintVerticalClock`、`OneLineClock`、`SignatureClock`、`DualClock`、`ImageSelectorClock`、`HorizontalClock`、`VerticalClock`、`ClockPanel` | 各预设 |
| `AnimationView` / `NotificationAnimationView` / `FrameAnimationView` / `FrameAnimationController` | 通知动画帧播放 |
| `GradientLinearLayout` / `GradientTextView` / `GradientImageView` | AGSL/LinearGradient 渐变 |
| `FontWeightAdjustView` | 可变字重（配合 `font_set.xml` 宽度补偿表） |

### 4.5 位置与 FOD 位移（AODUpdatePositionController）

位置模式 `mMode`（AODView 依据样式类型判定）：

| 值 | 触发条件 |
|---|---|
| 0 | 普通 |
| 1 | `SmartCoverStyleInfo` |
| 2 | `isUsingSuperWallpaperStyle()` |
| 3 | `isUsingLinkageStyle()` |
| 4 | `FlipLinkageCategoryInfo` |

核心量：`mGxzwIconX/Y`（指纹图标中心）、`mGxzwIconSize`、`mTranslationY`（AOD 内容当前位移）、`mTranslationYStep`（每步位移，dimen `clock_container_translation_y`）、`mTranslationX`（`clock_container_translation_x`）、`mCutoutHeight`（状态栏挖孔高）、`mTopExtraMargin` / `mBottomExtraMargin`。

`updateTranslateStep()` 计算可用的"上边界"：
- 若 `mGxzwIconY > 0 && mIsGxzwIconShow && mMode == 1` → 用指纹图标 Y；
- 否则用 `mScreenSize.y`；
- `mMode == 0` 时上限再取 `min(, 0.85 * screenHeight)`（0.85f = 0x3f59999a）。

即：**AOD 内容只会在指纹图标上方排布，不会压到 FOD 区域**。指纹图标不显示（`mIsGxzwIconShow=false`）时退化为整屏可用。

`mIsDisplayUpdateModeOn = (Secure aod_display_update_mode == 1)`，默认 1；用于判断当前面板是否处于 AOD 低刷新更新模式（影响位移动画与休眠策略）。

### 4.6 联动时钟起始 Y（LinkageStyleController.getStartY）

| clockTemplateId | dimen | 值 |
|---|---|---|
| classic 系列 | `linkage_start_classic` | 6.0 dip |
| magazine_a | `linkage_start_magazineA` | -25.0 dip |
| magazine_b | `linkage_start_magazineB` | 20.0 dip |
| magazine_c（style==5） | `linkage_start_magazineC1` | 18.0 dip |
| 其它 | 默认 0 | — |

同族资源里还有 `linkage_start_magazineA_notification=-220.0dip`、`linkage_start_magazineC=110.0dip`（本方法未引用，供其它路径使用）。

---

## 5. 亮度与传感器

`MiuiDozeScreenBrightnessController.sensorReactChange(type, …)`：

| type | 含义 | 动作 |
|---|---|---|
| 1 / 2 | Prox NEAR（`log "Prox NEAR"`） | `requestState(DOZE_AOD_PAUSING)`（当前为 PAUSED 时）或 `requestState(DOZE_AOD)`；并 `stopNotificationAnimForSensor()` |
| 3 | 暗 | `getDefaultLowBrightness()` 置低亮度 + `scheduleScreenOff()`（`isSupportFloatBrightness` 时走浮点亮度分支） |
| 4 / 5 / ≥6 | 环境光档位 | 取 `sLightValues`（`aod_brightness_level` 数组）对应亮度；>=6 或越界会打 `valueIndex >= Utils.sLightValues.length` |

口袋模式（pocket mode）下直接 return，不做亮度调整。

`DozeScreenState`：FOD 按压时延迟 1 s 才应用 pending screen state；`mDozeFollowupSample=250ms`；会调 `RequestDoze.onRequestClockHide()`。

---

## 6. 通知

- `NotificationController`（`extends Object`，**不是** NotificationListenerService）是 SystemUI 侧 `content://keyguard.notification` 的**客户端**：`query(.../notifications)` 取列表 + 注册 ContentObserver 监听变化，另用 `call("getKeyguardNotificationSortedKeys")` 取排序键。
- 推送通道 `com.xiaomi.xmsf` 会被特殊处理：从 `Notification.extras` 的 `target_pkg` 还原真实包名，保证显示的是真实应用图标。
- 读取 `status_bar_notification_style`、`theme_product_id`、`progressMax` / `progressIndeterminate`。
- AOD 上最多 4 个图标 + "更多"，另有 1 个焦点通知区（`MiuiFocusNotification2`、`fn_container`）。
- 动画样式（`notification_animation_style`，`NotificationStyleManager`）：`none`、`screen_on`、`blue_wave`、`red_wave`、`particle_wave`、`green_wave`（`green_wave` 在 `createAnimationDrawer` 中存在，但 `getDrawableTitle`/`getStyleList` 未列出，属机型/资源白名单控制）。
- 关键开关：`full_screen_aod_notification`（默认 1）、`wakeup_for_keyguard_notification`、`new_device_after_support_notification_animation`。

---

## 7. 全屏 AOD（Full AOD）

### 7.1 能力位与开关

| 键 | 默认 | 说明 |
|---|---|---|
| `full_screen_aod_support` | AOD 进程 1 / 其它进程 0 | 能力位（`isFullAodSupport`） |
| `full_screen_aod_on` | — | 用户开关 |
| `full_screen_aod_notification` | 1 | 全屏 AOD 是否显示通知 |
| `full_screen_aod_disable_reason` | — | 禁用原因位掩码 |

`FullAodStrategyKt.getToastReason()` 位 → 文案：`1` 第三方壁纸、`2` 超级壁纸、`4` 模板、`8` 视频景深、`0x20` 第三方主题（`0x7f120198/199/19a/19b/19c`）。

### 7.2 与 SystemUI 的协议

1. 熄屏时 `MiuiShowStyleController.updateFullAodStateIfNeed()` 调 `RequestDoze.onAodRequest(1, bundle)`。
2. SystemUI 回包 `screenOffNeedFullAodAnim`。
3. `AODSettings.setNeedFullAod()` 记录本帧是否走全屏。
4. `DozeHost.checkFullAodVisibility()` 在全屏 AOD 时把 AODView alpha 置 0/1。
5. `MiuiFullAodAdapter.setDozeScreenBrightness` 在全屏 AOD 时**跳过**亮度设置（全屏时面板亮度由 SystemUI/显示驱动接管）。

### 7.3 与硬件面板的关系（对照一加 13）

一加 13 模块额外做了 `OplusAodPanelBridge`：通过 `vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default` 的 feature `217`（`FEATURE_LONGRUI_AOD`）设置 `FULL_SCREEN_AOD_MODE = 1<<2`，让**面板驱动**进入全屏 AOD 扫描/刷新模式。MIUIAod 自身不碰这个 HAL —— 它只管"画什么"和"要不要亮"，"面板怎么刷"由厂商侧决定（见 §13.1）。

---

## 8. 设置键总表

### 8.1 实时读取（Settings.Secure / Settings.System / Global）

AOD 显示：`doze_always_on`、`aod_show_style`、`aod_mode_user_set`、`aod_start`、`aod_end`、`aod_mode_time`、`aod_category_name`、`aod_style_state`、`aod_using_super_wallpaper`、`aod_display_update_mode`

全屏 AOD：`full_screen_aod_notification`、`full_screen_aod_on`、`full_screen_aod_support`、`full_screen_aod_disable_reason`

指纹：`gxzw_icon_aod_show_enable`

通知：`notification_animation_style`、`status_bar_notification_style`、`theme_product_id`、`wakeup_for_keyguard_notification`、`new_device_after_support_notification_animation`

时钟/文字：`selected_keyguard_clock_position`、`show_lunar_calendar`、`auto_dual_clock`、`resident_timezone`、`constant_template_editor_info`、`constant_lockscreen_info`

系统联动：`power_supersave_mode_open`、`permit_disable_aod_in_power_save_mode`、`miui_keyguard`、`force_fsg_nav_bar`、`accessibility_display_inversion_enabled`、`miui_dkt_mode`、`linkage_state`、`need_reset_aod_time`、`enable_three_gesture`、`gesture_wakeup`、`force_black_v2`、`color_scheme`、`system_locales`

> 注意：`aod_support_keycode_goto_dismiss` **不是** Settings 键，而是 `AODSettings.isKeycodeGotoEnable()` 里的 FeatureParser 标志（见 §9.4），不要用 `settings put` 去改。

### 8.2 SettingsHolder 观察（变更即触发重算）

`gesture_wakeup`、`aod_mode_time`、`miui_keyguard`、`aod_display_update_mode`、`accessibility_display_inversion_enabled`、`force_black_v2`、`aod_using_super_wallpaper`、`color_scheme`、`auto_dual_clock`、`resident_timezone`、`system_locales`、`power_supersave_mode_open`、`aod_category_name`、`constant_template_editor_info`

### 8.3 仅用于备份/恢复（AodBackupImpl / AodPadBackupImpl）

备份文件 `.aodBackup` 内的 JSON 键（**不是 Settings 键，`settings put` 无效**）：

| 键 | 来源 |
|---|---|
| `setting_aod_enable` | `doze_always_on` |
| `setting_show_mode` | `aod_show_style` |
| `setting_start_time` / `setting_end_time` | `aod_start` / `aod_end` |
| `setting_support_aon` | 设备是否支持 AON |
| `setting_full_aod_enable` | `full_screen_aod_on` |
| `setting_full_aod_notification_enable` | `full_screen_aod_notification` |
| `setting_permit_disable_aod_in_power_save_mode` | 同名 Secure 键 |
| `setting_category_name` / `setting_category_param` | `aod_category_name` 与参数 |
| `history_json` / `theme_entity_json` | 历史与主题数据（整表导出） |

Pad 版 `AodPadBackupImpl` 是同样的键去掉 AON/全屏两项。`AodFullBackupAgent` + `TinyKeyguardBackupUtil` 参与系统备份/换机迁移。

---

## 9. FOD / GXZW 细节

### 9.1 图标位置读取（`Utils.getGxzwIconPosition()`）

```
persist.sys.fp.fod.location.X_Y        否则 persist.vendor.sys.fp.fod.location.X_Y     "x,y"
persist.sys.fp.fod.size.width_height   否则 persist.vendor.sys.fp.fod.size.width_height "w,h"
缩放：ScreenResolutionUtils.getScreenRatio() = realSize.y / physicalSize.y
失败返回 (-1,-1)，结果缓存到 mGxzwIconPosition
```

RMX5010 实机值（已有文档核实）：`persist.vendor.sys.fp.fod.location.X_Y=540,2054`、`size=184,184`。

### 9.2 图标尺寸更新

`AODUpdatePositionController.updateGxzwIconSize()`：**Y < 0 时只调用 `updateTranslateStep()`，不更新 X/Y** —— 即位置读不到时 AOD 内容不做横向位移，只用整屏高度作为下边界。

### 9.3 图标显隐开关

`gxzw_icon_aod_show_enable`（`Utils.isFodAodShowEnable`）：AOD 上是否绘制指纹图标。关闭时 `mIsGxzwIconShow=false`，AOD 内容可下移占满。

### 9.4 设备特性

`Utils` 静态初始化读取的 FeatureParser 标志：

| 标志 | 作用 |
|---|---|
| `support_aod_aon` | AON（`com.xiaomi.aon`）支持，智能 AOD 前提 |
| `support_aod_outer_screen_aon` | 外屏 AON（折叠） |
| `support_aod_fullscreen` / `inner_screen_support_aod_fullscreen` | 全屏 AOD |
| `support_low_brightness_fod` / `fod_solution`（==1 视为低亮度 FOD） | 低亮度指纹 |
| `aod_brightness_level` | int 数组 → `sLightValues` |
| `ro.vendor.fod.dimlayer.enable` / `ro.fod.dimlayer.enable` | `SUPPORT_DIMLAYER` |
| `ro.hardware.fp.fod` | `GXZW_SENSOR` |
| `ro.vendor.touchfeature.type` bit4（`>>4 & 1`） | keycode 进入 AOD 能力（`isSupportKeycodeByProperty`） |
| `aod_support_keycode_goto_dismiss`（FeatureParser） | `isKeycodeGotoEnable()`：属性位或该标志任一为真即启用；决定"轻触 AOD 可按 F4 立即消失/续期" |
| `is_default_temporary_style` / `is_only_support_keycode_goto`（FeatureParser） | 默认显示模式（见 §3.2） |

RMX5010 `haotian.xml`：`support_aod=true`、`support_aod_fullscreen=true`、`support_aod_aon=true`、`aod_support_keycode_goto_dismiss=true`、`support_low_brightness_fod=false`、`fod_solution=3`、`is_aod_need_grayscale=false`、`is_default_temporary_style=true`；**无** `support_aod_outer_screen_aon`。

---

## 10. 主题 / 模板 / 字体 / Shader

### 10.1 主题加载（仅国行）

`ThemeUtils.supportAodTheme()`：`!IS_INTERNATIONAL_BUILD && com.android.thememanager versionCode >= 0x3d8(984)`。
`ThemeDataManager.loadTheme(path, identity, name, list, …, …)` 走 RxJava，结果落 `theme.db`（GreenDAO：`THEME_ENTITY` = `THEME_DIR_NAME/THEME_NAME/THEME_DESCRIPTION`），资源目录由 `ThemeUtils.getRootDir()` 管理。
`ThemeReceiver` 监听 `com.android.thememanager.AOD_CHANGED`；`ThemeResourceClearJobService` 定时清理。

### 10.2 模板族（TemplateDataFactory / template.data.template）

`classic`、`classic_plus`、`classic_max`、`all_in_one`、`magazine_a/b/c`、`eastern_a/b/c`（`TraditionalChina`）、`pad_exclusive_a/b/c`、`rhombus`、`doodle`、`smart_frame`。
预设模板配置在 `assets/preset_clock_template_config.json`（classic 组下 all_in_one 的 style 1/4/5/6 变体，`classicLine1=103`、`clockWeight 420~700`、`fontStyle 21/22`）。

### 10.3 锁屏编辑器联动（classes2 / com.miui.keyguard.editor）

- `AodViewFactory` 支持类型：`rhombus`、`classic`、`classic_plus`、`classic_max`、`smart_frame`、`magazine_a/b/c`、`doodle`。
- `TemplateApplyController.checkOrAskAodApply()`：锁屏应用模板时**询问是否同时应用到 AOD**；`AodDialogViewManager` + `applyToAodAlertDialog` 负责预览与回调。
- `assets/config/` 内置 45 个 keyguard editor 模板 JSON：`kg_os4_classic/doodle/eastern/magazine/pad/rhombus`、`kg_all_in_one_*`、`kg_pets_*` 等。

### 10.4 字体

- `assets/fonts/`：`MiClock-{Extralight,Light}.otf`、`MiClockMono-{Extralight,Light,Normal,Regular}.otf`、`MitypeRoundedNormal.otf`、`misymbol_vf.ttf`、`BebasNeue-Book.otf`。
- `assets/`：`MiSansRCFVF`、`MiSansRoundedFVF`、`MiSansSquareFVF`、`MiSerifFVF`、`MiHausVF`、`C800.ttf`、`ChronicleDisplayCompressed-Semibold`、`Cursive-Regular`、`DelaGothicOne-HZ`、`InterMono-SemiBold`、`NeuRounded`、`ShadowsIntoLightchinese-CHN`。
- `assets/font_set.xml`：以 `ratio = bounds.width / bounds.height` 为键的**字宽补偿表**（`wdth,hght,boundsWidthDp`），供可变字重排版时避免奇数位抖动。

### 10.5 Shader

- `assets/shader_code.glsl`：AGSL `RuntimeShader`，`uDigitTL/TR/BL/BR` 四角纹理 + `uHue` + `MAX_STOPS` 渐变，用于渐变数字时钟。
- `res/raw/`：`wave_frag/vs`、`wave_noise`、`ripple`、`rain`、`zoomblur`、`moru_prism_*`、`music_player_tracker*`、`square_fragment_shader` 等 —— 通知波纹/超级壁纸/MAML 效果。

### 10.6 MAML / FastPlayer

`com.miui.maml`（686 个 smali）+ `libfastplayer.so`、`libmiffmpeg_fastplayer.so`：MAML 主题的动画/视频播放。`MamlClock` + `MamlViewContainer` 承载在线 MAML 息屏。`assets/rss.xml`(92K) 实测是 MAML 的 **RSS 示例数据**（Bola.net 印尼足球新闻，2017 年），属于 MAML 示例资源遗留，**不是**样式市场缓存——排查 MAML 主题时不要被它误导。

---

## 11. 数据、诊断与统计

| 组件 | 说明 |
|---|---|
| `history.db` | GreenDAO，`HISTORY_ENTITY(_id, TIMESTAMP, CATE_NAME, JSON_PARAMETER)`，记录用过的样式；`AodOpenHelper` 带 `PRAGMA table_info` 的增量 ALTER TABLE 迁移 |
| `theme.db` | `THEME_ENTITY(THEME_DIR_NAME, THEME_NAME, THEME_DESCRIPTION, …)` |
| `StyleDataProvider` | 暴露 `content://com.miui.aod.StyleDataProvider/theme` 与 `/history` |
| `AodViewMonitor` + `VisibilitySampler` | **OS4 新增自检**：进入 AOD 时（300 ms 去抖）按 `VisibilityPolicyRegistry` 逐视图采样 visibility/alpha/size/scale，异常即上报。策略覆盖 `classicGeneric/classicMax/classicPlus/classicStyle21/25/26/doodle/easternA/B/C/magazineA/B/C/oversizeA/B/rhombus` 共 16 套，每套列出应可见的 view id（如 `text_area`、`time_view`、`tv_hour`、`eastern_art_b_h_aod_time_below_view_hour1`） |
| `AnalyticManager` + `AnalyticalDataCollectorJobService` | 事件名：`aod_style_page`、`aod_history_page`、`aod_style_select_page`、`aod_style_click_action`、`aod_apply_click_action`、`aod_mode_switch`、`aod_mode_user_switch`、`aod_visible_event`、`aod_on_status`、`aod_date_status`、`aod_energy_status`、`aod_notification_status`、`batterysaver_aod_off`、`charging_aod_off`、`aod_step_to_image_community_action` |
| `MiSight.KeyguardDFXErrorEvent` | 上报到 MiSight 的 DFX |

---

## 12. 外部接口

### 12.1 SettingsProvider `call()` 方法

`getThumbnail`、`getNotifyThumbnail`、`getShowModeTip`、`getAodThumbnail`、`getAodModeTip`、`getThumbnailForWallpaper`、`getClockImageForSuperWallpaper`。设置页/AOD 列表页通过它拿缩略图 URI（`com.miui.aod.fileprovider`）与文案。

### 12.2 PartProvider（`aod.part`）

`call("provideFile")` 返回 `bitmap` / `fileExist`；`getString` / `putString` 键值；`openFile` 支持 `/themes/…` 与 `/select_image/…`。

### 12.3 AI Action（aiot-spec-v3）

| URI | 功能 |
|---|---|
| `…action:[com.miui.aod/aod/getaodstatus]:0:1.0` | 查询息屏状态 |
| `…action:[com.miui.aod/aod/setaodstatus]:0:1.0` | 开/关息屏（返回 0 成功 / -11 不支持 / -1 失败 / -10 已是该状态） |
| `…action:[com.miui.aod/aod/openaodsettings]:0:1.0` | 打开息屏设置（-10 表示已在该页） |

权限：`hyperos.permission.READ_AIACTION`；调用方白名单含 `com.xiaomi.aicr`。声明文件 `res/raw/aod_ddf.json`。

### 12.4 AppFunctions（Gemini，Android 16）

`assets/app_functions.xml` 声明 3 个：

| function_id | 作用 |
|---|---|
| `com.miui.aod.gemini.AodStateManager#getUncategorizedDeviceState` | 读状态类别 `ALWAYS_ON_DISPLAY`（`AOD_SWITCH` / `AOD_FULLSCREEN` / `AOD_CHARGING_ALWAYS` / `AOD_BATTERY_SAVER`） |
| `com.miui.aod.gemini.AodMetadataManager#getDeviceStateMetadata` | 读元数据与可选值 |
| `com.miui.aod.gemini.AodDeviceStateSetter#setDeviceStateItem` | 写状态；引擎编辑类走 `launchEditorScreen`（返回 `available`），锁屏时拒绝执行 |

另有 `AodDisplayModeScreen`（`AOD_DISPLAY_ITEMS`：`STYLE` / `SCHEDULED`（`aod_start`/`aod_end`）/ `AOD_BATTERY_SAVER`）与 `AodNotificationAnimationScreen`（`AOD_NOTIFICATION`）。
`assets/app_functions_v2.xml`(41K)、`app_functions_schema.xsd` 为完整 schema。

### 12.5 步数组件

`other/step/StepLiveData`、`GoalLiveData` 读 `content://com.mi.health.provider.main/widget/steps/simple` 与 `/widget/steps/goal`；`StepWidget` 用 `AnimationDrawable` 播放步数进度动画。

---

## 13. 一加 13 模块（OP13HyperOSFix）的 AOD 相关优化

代码位置：`os4/external/OP13HyperOSFix/app/src/main/java/local/mio/op13hyperosfix/`

### 13.1 OplusAodPanelBridge（面板级全屏 AOD）

`OplusAodPanelBridge.java`（139 行）：

- 服务名 `vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default`（HIDL/AIDL 直取）。
- feature `217` = `FEATURE_LONGRUI_AOD`；值 `FULL_SCREEN_AOD_MODE = 1 << 2`。
- `getFeature` = `FIRST_CALL_TRANSACTION`（写 feature + writeInt(1)，读 exception/result/int[]）；`setFeature` = +1（写 feature + writeIntArray([value])）。
- 仅当能力位含 `1<<2` 时下发 `setFeature(217, 4)` / `setFeature(217, 0)`。
- 注册 `linkToDeath`，服务死亡时重置状态。

**意义**：让面板驱动真正进入全屏 AOD 模式（低刷新、局部扫描），这是 MIUIAod 完全不管的一层。

### 13.2 SystemUiHooks

| Hook | 目标 | 行为 |
|---|---|---|
| `hookAodDoubleTapPocketGuard` | `com.android.systemui.shade.PulsingGestureListener#onDoubleTapEvent()` | 双击前查 `AodPocketGate.allowsWake()`，口袋内 `setResult(false)` |
| `hookFullScreenAodPanelMode` | `com.android.keyguard.fullaod.MiuiFullAodManager` 构造、`updateFullAodEnable`、内部类 `$1..$8#onDozingChanged` | 状态变化时 `fullAodEnable()`（失败则回退 `isDeviceSupport && mAodEnable && mAodFullScreenEnable && isFullAodSupport`）→ `OplusAodPanelBridge.setFullScreenAodEnabled()` |
| `AodPocketGate` | 自身 | SCREEN_OFF 注册 `TYPE_PROXIMITY`，SCREEN_ON 注销；`allowsWake() = !known \|\| !near`；阈值 `min(1.0, max(0.1, maxRange))`；无传感器时 fail-open（放行） |

### 13.3 SystemServerHooks

- `AOD_SINGLE_TAP_KEY_CODE = 354`（0x162）。
- 在 `PhoneWindowManager#interceptKeyBeforeQueueing` 拦截触摸面板 F4（scanCode 62 / keyCode 134），状态机在 `F4State.handle()`：
  - `DOUBLE_TAP_WINDOW_MS = 280L`：第一下按下后 `postDelayed(280ms)`；窗口内没有第二下才判定为单击 → `injectAodSingleTap()` 通过 `InputManager.injectInputEvent` 注入 keyCode **354** down/up → 进入/续期低功耗 AOD；
  - 窗口内第二下 → 取消 pending，`DOUBLE_TAP_COOLDOWN_MS = 500L` 冷却，`wakeFully()`（`wakeUpFromWakeKey` → `mWindowWakeUpPolicy.wakeUpFromKey` → `PowerManager.wakeUp` 三级回退）；
  - 两条路径都先过 `pocketGate.allowsWake()`，交互态（`isInteractive()`）直接忽略。
- PocketGate 在 `startedGoingToSleep` 注册、`finishedWakingUp` 注销。
- `systemReady` 时按 `isInteractive()` 决定是否先注册。

### 13.4 SettingsHooks

- `AodAndLockScreenSettings#isSupportPickupWakeup` → true（让"抬起亮屏"开关可见）。
- SystemUI / Settings 侧强制 `support_gesture_wakeup` 为 true。

### 13.5 文档侧

`一加13澎湃OS4综合修复方法.md` 第 5 章（5.1–5.4：F4/AOD、280 ms、距离门控、AOD 双击防误触）与第 18 章测试矩阵（F4/AOD、LTPO、抬起/步数、指纹/FOD、指纹速启）。

---

## 14. OP13 优化 ↔ MIUIAod 逐项对照

| # | OP13 优化 | MIUIAod 内的对应机制 | 是否同一层 | RMX5010 现状 |
|---|---|---|---|---|
| 1 | F4 单击 → keyCode 354 | `MiuiAodService.dispatchKeyEvent()` 只认 354；`Utils.isShowTemporary()` 为真时才续期 `getTemporaryStyleDuration()` | **应用层协议**，OP13 是"补造按键" | **已有**（`SystemServerHooks` 同款，含 354 注入） |
| 2 | F4 双击 → 完整唤醒 | AOD 侧无双击逻辑，由 SystemUI `PulsingGestureListener`/PhoneWindowManager 处理 | 框架层 | **已有** |
| 3 | AOD 双击防误触（PocketGate） | MIUIAod 有 pocket mode（`MiuiDozeScreenBrightnessController` 直接 return），但**不做双击门控** | SystemUI 层 | **已有**（`AodPocketGate`，与 OP13 同源） |
| 4 | 抬起亮屏开关可见 | `SettingsHooks` 侧强制 `isSupportPickupWakeup`；MIUIAod 侧 `gesture_wakeup` 观察 | 设置层 + SystemUI 传感器注册 | **已有**，且 RMX5010 版本更保守（只"暴露能力"，不强制开启） |
| 5 | `support_gesture_wakeup` 强制 true | FeatureParser 标志 | 设置层 | **已有** |
| 6 | 全屏 AOD 面板模式（feature 217） | MIUIAod 只到 `RequestDoze.onAodRequest(1,…)` + alpha 控制，**不碰面板 HAL** | 厂商 HAL 层 | **缺**（模块内无 `OplusAodPanelBridge`） |
| 7 | 默认显示模式 | `AOD_SHOW_STYLE_DEF = !isDefaultTemporaryStyle()` | 应用层 | `is_default_temporary_style=true` → 默认轻触 10 s |

### 14.1 结论

1. **OP13 与 RMX5010 的差距只有第 6 项**：面板级全屏 AOD（`OplusAodPanelBridge` + `MiuiFullAodManager` hook）。其余四项在 RMX5010 模块里已经存在且更成熟。
2. 第 6 项是否可移植，取决于两点：**两点均已在 §16 得到肯定回答**。
   - ~~面板 feature 服务是否存在~~ → `vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default` 存在且 `running`，HAL 导出 `SetDisplayLongruiAOD` 等一整套 AOD 接口，内核 OFP 读到的面板能力属性为 `0x6`；
   - ~~SystemUI 内是否存在 `MiuiFullAodManager`~~ → 存在，`fullAodEnable` / `updateFullAodEnable` / `mAodFullScreenEnable` / `isFullAodSupport` 四个成员齐全。
   - 仍在的唯一未知项：**feature ID 217 与 transaction 号在本机是否一致**，只能靠代码里的写调用确认（§19）。
3. 需要注意的是：`support_aod_fullscreen=true` 只说明**应用层愿意画全屏**；没有面板模式时，全屏 AOD 仍然是"以普通 AOD 刷新率画一整屏"，功耗会明显高于 OP13。

---

## 15. 对 RMX5010 的建议（按性价比排序）

1. ~~先验证 HAL/类是否存在~~ —— **已由 §16 只读探测确认：服务在跑、HAL 有 Longrui AOD、SystemUI 有 `MiuiFullAodManager`，前提全部成立。**
2. **下一步只能在代码里做**：在模块中加一个默认关闭的只读探测入口，用 `OplusAodPanelBridge` 同款裸 Parcel 调 `getFeature(217)`，把返回的 int[] 写日志；确认能力位含 `1<<2` 之后，再打开 `setFeature` 的开关。`service call` 走不通（§19.1）。
3. 移植时必须保留三件事：`linkToDeath`、写前存原值、能力位不含 `1<<2` 就不写。写入用 4 / 0 成对回滚，**回读一律走 `getFeature`，不要依赖 sysfs**（本机 sysfs 在 ksu 域下不可读，见 §16）。
4. **不建议**改 `is_default_temporary_style`：那会把默认交互从"轻触 10 秒"改成"定时/常亮"，与 F4 单击进入 AOD 的整套设计冲突，且会显著增加功耗。
5. **本机 AOD 开关当前是关的**（`doze_always_on` 未设置）。验证任何 AOD 行为前，先在设置里打开"息屏显示"，否则复现不出任何现象。
6. 与 AOD 相关的既有风险点（本轮未改动）：
   - `gxzw_icon_aod_show_enable` 关闭后 AOD 内容会下移，若 RMX5010 的 FOD 图标位置读不到（`(-1,-1)`），内容不会横移，视觉上会偏 —— 与 §9.2 一致，不是缺陷。
   - 全屏 AOD 下 `MiuiFullAodAdapter` 跳过亮度设置，若面板模式未生效，可能出现"全屏 AOD 亮度不受控"。

---

## 16. 实机只读探测结果（2026-11-11，RMX5010 已连接）

原本的"未验证项"表格已替换为探测结论：

| 项 | 结论 |
|---|---|
| RMX5010 上 `aod_show_style` | **未设置**（`settings list secure` 里没有该键）→ 走默认，按 §3.2 推导为 **0（轻触 10 秒）**，与预测一致 |
| `doze_always_on` | **未设置** → `Utils.isAodSettingsEnabled()` 默认取 0 → **当前息屏显示是关闭的**（非折叠机，无其它覆盖分支） |
| `aod_category_name` / `aod_style_state` / `aod_using_super_wallpaper` | `Linkage` / `1` / `0` |
| 锁屏模板 | `constant_template_editor_info` 里是 `kg_all_in_one_magazine_style1`、`templateId=all_in_one`、`style=6`、`clockWeight=700` |
| `ro.vendor.touchfeature.type` | **未设置** → `isSupportKeycodeByProperty()` 为 false；但 `aod_support_keycode_goto_dismiss=true`，`isKeycodeGotoEnable()` 仍为 **true** |
| `persist.vendor.sys.fp.fod.location.X_Y` | `540,2054`（存在；shell 读不到，root 可读） |
| `persist.vendor.sys.fp.fod.size.width_height` | `184,184` |
| `ro.hardware.fp.fod` / `.c` | `true` / `true` |
| Oplus 面板 feature 服务 | **存在且运行**：`vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default`，`init.svc.displaypanelfeature-service=running`，二进制 `/odm/bin/hw/vendor.oplus.hardware.displaypanelfeature-service`（223,104 B） |
| 面板 HAL 的 Longrui AOD | **有**：`SetDisplayLongruiAOD` / `GetDisplayLongruiAOD`、`SetDisplayUltraLowPowerAOD` / `GetDisplayUltraLowPowerAOD`、`SetDisplayFakeAOD` / `GetDisplayFakeAOD`、`SetDisplayPanelAodArea` |
| 面板能力属性 | 内核 OFP 打印 `oplus_ofp_get_longrui_aod_config_attr:5271 longrui_aod_config(20064): 0x6`；`ultra_low_power_aod_mode(20068): 0`；`aod_light_mode(20069): 0` |
| 对应 sysfs | `/sys/kernel/oplus_display/{longrui_aod, ultra_low_power_aod_mode, aod_light_mode_set}` 三个节点都存在（readdir 可见）。**注意：节点当前被 SELinux 保护** —— 以 `u:r:ksu:s0` 执行 `cat` 与 `ls -l` 都返回 `Permission denied`（`-?????????`，getattr 就被拒），所以"6 / 0 / 0"这类读值不可复现，后续验证不能依赖 sysfs |
| 面板型号 | `panel_id = 08 05 00`，qdcm 配置为 `qdcm_calib_data_AB849_*`（BOE AB849） |
| `MiuiFullAodManager`（SystemUI） | **存在**，且 `fullAodEnable`、`updateFullAodEnable`、`mAodFullScreenEnable`、`isFullAodSupport` 四个成员都在 —— OP13 hook 的目标一个不缺 |
| `com.xiaomi.aon` | 已安装 → 智能 AOD 前提具备 |
| **feature 217 是否被接受** | **仍未验证**。这是唯一剩下的未知项，且只能靠写调用确认（见 §19） |

## 17. 结论摘要

- MIUIAod 是**纯 SystemUI Doze 插件**（`PLUGIN_DOZE`），进程 `com.miui.aod`，UID 1000；它决定"什么时候显示、显示什么、显示多久"，**不决定面板怎么刷新**。
- 显示模式四选一（轻触/定时/全天/智能），默认值由 `is_default_temporary_style`、`isFsAodSameToLock`+AON 决定；RMX5010 落在"轻触 10 秒"。
- FOD 只影响**内容排布**（`AODUpdatePositionController`，指纹图标上方排布，读不到位置时退化整屏），不影响显示开关。
- 全屏 AOD 是"应用愿意画 + 面板愿意刷"两件事，MIUIAod 只负责前者。
- 一加 13 模块的 AOD 优化里，只有**面板级全屏 AOD（feature 217）** 是 RMX5010 尚未具备的；F4/AOD、双击防误触、抬起亮屏三项 RMX5010 已实现且实现更保守。
- 实机只读探测（§16）确认：RMX5010 的面板 HAL **有** Longrui AOD 能力（内核 OFP 读到的面板能力属性 `0x6`），SystemUI 的 `MiuiFullAodManager` 也在，**移植的前提条件全部成立**；只剩"feature 217 这个 ID 与 transaction 号在本机是否一致"这一项无法靠只读方式确认。
- 另外一个被忽略的事实：本机**息屏显示开关目前是关的**（`doze_always_on` 未设置，代码默认 0）。任何 AOD 侧现象的复现都要先打开它。

---

## 18. 附录

### 18.1 包清单（classes.dex，`com/miui/aod`，10,600 个 smali）

| 包 | smali | 职责 |
|---|---|---|
| `widget/` | 215 | 所有时钟/通知/动画视图 |
| `components/` | 211 | 样式选择器、裁剪/导出、组件控件 |
| `doze/` | 138 | DozeMachine、11 个 Part、亮度、屏态 |
| `util/` | 115 | 工具（Shader、MMKV、wakelock、电池、折叠、ScreenResolution、MiSight…） |
| `settings/` | 96 | 设置页与各 Provider |
| `template/` | 57 | 模板配置（classic/magazine/eastern/pad/rhombus/all_in_one） |
| `stylelist/` | 51 | 样式列表（含 Pad 专用） |
| `theme/` | 46 | 在线主题加载 |
| `gemini/` | 44 | AppFunctions（Gemini） |
| `history/` | 34 | 历史记录列表 |
| `other/` | 29 | 步数组件等 |
| `notification/` | 25 | 通知数据 |
| `category/` | 25 | 样式类别与预设 |
| `utils/` | 19 | 次级工具（UserHandleUtils、CommonUtils、MiuiSettingsUtils…） |
| `db/` | 17 | GreenDAO（history.db / theme.db） |
| `common/` | 16 | BaseActivity、StyleInfo、线程封装 |
| `analy/` | 15 | 埋点 |
| `linkagestyle/` | 14 | 联动时钟动画与起始 Y |
| `attention/` | 13 | AON 智能显示 |
| `monitor/` | 12 | AodViewMonitor 自检 |
| `superwallpaper/` | 12 | 超级壁纸联动 |
| `flip/` | 12 | 折叠/翻页时钟 |
| `resource/` | 10 | DrawableCache、FontCache、CachedSettings |
| `aodannotation/` | 10 | 注解处理器（FrameRes/JsonString） |
| `icu/` | 8 | 时区名（`resident_timezone` 双时钟） |
| `backup/` | 7 | 备份/恢复 |
| `autodensity/` | 4 | AOD 独立密度 |
| `aiaction/` | 3 | AI Action Provider |
| `aidl/` | 3 | AIDL |
| `fullaod/` | 2 | 全屏 AOD 策略 |
| `part/` | 2 | PartProvider |

### 18.2 超级壁纸

`SuperWallpaperReceiver`：
- 读 `super_wallpaper_bean`、`super_wallpaper_linkage_state`；
- 默认时钟位置 JSON：`clock_position_x=0.34`、`clock_position_y=0.12`、`dual_clock_position_x_anchor_right=0.65`、`dual_clock_position_y=0.6`；
- JSON 非法/缺省时 `fallbackDefaultAod()` 退回 `Linkage` 样式；
- 通过受保护广播 `miui.miwallpaper.action.ACTION_AOD_OFFSET` 与壁纸侧同步偏移，`AODUpdatePositionController.onSuperWallpaperPositionEvent()` 接收 `PositionEvent`。

### 18.3 折叠 / 翻页

`flip/`：`FlipLinkageStyleClockView`、`FlipLinkageStyleController`、`FlipClockInfo`、`FlipLinkageTemplateId`、`AnimationExtKt`、`ConstraintSetExtKt`。
`util/foldchange/FoldDisplayChangeUtils` 处理内外屏切换；Manifest 声明 `miui.supportFlipFullScreen=0`（本机型/本版本不启用翻盖全屏）。

### 18.4 AOD 独立密度

`autodensity/AutoDensityControllerImpl`：通过反射改 `ResourcesManager`、遍历 `ActivityThread.mAllApplications`，插入 `DummyApplication` 并覆盖 display metrics —— 因为 AOD 作为 SystemUI 插件运行时与 SystemUI 共享进程，需要独立的 density 才能让 `dp` 布局在 AOD 上按预期渲染。这是"改 AOD 布局尺寸不生效"类问题的关键点。

### 18.5 时区与双时钟

`icu/ICUManager` + `GetZoneNameTask`：为 `resident_timezone` 提供本地化时区名；配合 `auto_dual_clock`（双时钟）与 `selected_keyguard_clock_position`。

### 18.6 唤醒锁

`util/wakelock/`：`WakeLock`、`DelayedWakeLock`、`SettableWakeLock`。`AODUpdatePositionController` 用 `WakeLock.wrapForAnimation(ctx, TAG, 800ms)`（0x320），`MiuiAodService` 在 354 按键时 `requestDrawWakelock(getTemporaryStyleDuration())`。

---

## 19. 只读探测的边界：为什么无法只读确认 feature 217

### 19.1 服务注册形态

```
$ adb shell service list | grep displaypanel
415  vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default: []
```

方括号里是空的 —— 该服务注册时没有对外暴露 interface descriptor。

实测更直接：**`service call` 根本找不到这个服务**。

```
$ adb shell service call vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default 9999
service: Service vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default does not exist
```

（`adbd` 侧的 `service list` 能看到它，但 `service call` 的查找路径拿不到 —— 这类 HAL 服务注册在 vendor 的 servicemanager 上下文，且没有 Java 侧可见的 descriptor。）

即便能查到，AIDL 的 token 校验也会先于方法分发：descriptor 为空 → `writeInterfaceToken("")` → HAL 侧 `checkInterface()` 判 `BAD_TYPE`，方法不会执行。**结论：`service call` 不是探测这个 HAL 的可用工具，无论读写。**

### 19.2 正确的调用方式（OP13 已验证）

`OplusAodPanelBridge` 不走 AIDL stub，而是自己 `new Parcel()` 并显式写 token：

```java
data.writeInterfaceToken("vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature");
data.writeInt(feature);      // getFeature
data.writeInt(1);
service.transact(FIRST_CALL_TRANSACTION, data, reply, 0);
```

`setFeature` 是 `writeInt(feature)` + `writeIntArray([value])`，transaction = `FIRST_CALL_TRANSACTION + 1`。

### 19.3 剩余风险与验证方式

| 风险 | 说明 | 怎么验（非只读） |
|---|---|---|
| transaction 号 | `FIRST_CALL_TRANSACTION` 假设 `getFeature` 是接口第一个方法；RMX5010 的 AIDL 版本可能不同 | 先只调 `getFeature`（读），看是否返回 int[] 且不抛 `TransactionTooLarge`/`BAD_TYPE` |
| feature ID 217 | OP13 上 217 = `FEATURE_LONGRUI_AOD`；本机 HAL 有 `SetDisplayLongruiAOD`，但 ID 映射未证实 | `getFeature(217)` 返回的能力位里若含 `1<<2`，基本可确认 |
| 值语义 | OP13 用 `4`（`1<<2`）表示全屏 AOD 模式 | 用 `getFeature` 回读确认值已生效。**不要指望 sysfs**：本机 `/sys/kernel/oplus_display/*` 在 `u:r:ksu:s0` 下 getattr/read 全部 `EACCES`（§16），`dmesg` 也读不到 |
| 回滚 | 写错值可能让面板停在异常模式 | 任何写入都必须成对：写前先 `getFeature` 存原值，异常时立刻写回；并加 `linkToDeath` |

### 19.4 结论

只读探测已经把"能不能做"回答到 90%：**HAL 有 Longrui AOD、内核报告面板能力 `0x6`、SystemUI 有 `MiuiFullAodManager`**。剩下 10%（feature 217 的 ID 与 transaction 号）本质上无法只读确认——AIDL 的接口表不在任何可读配置里，只存在于 HAL 二进制内部。

下一步要么：

1. 在模块里加一个**默认关闭**的探测入口：`getFeature(217)` 只读调用 + 把结果写日志，不调用 `setFeature`；确认能力位后再打开写入开关；
2. 或者接受 OP13 的常量直接移植，但必须保留"能力位不含 `1<<2` 就不写"的门禁和 `linkToDeath` 回滚。

两种都需要动代码，已经超出"只读"的范围。
