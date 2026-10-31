# OplusCamera 系统级移植（RMX5010 / haotian OS4）

> 日期：2026-10-29  
> 模块：`rmx5010_fod_bridge` 1.4.1（产物 `out/rmx5010_fod_bridge-1.4.1-camera.zip`，
> SHA-256 `daaedcd552428cb7034189a6fe34af0d9f4121bc70c9608485fece4e9f633c64`）  
> 目标：删除 `/product/priv-app/MiuiCamera` 的小米相机，按 OS3/OS4 相机移植文档把 RMX5010 原厂
> OplusCamera 以 system/priv-app 身份装回，并保留 P010、权限、SELinux、Provider stub 等闭包。

---

## 1. 最终状态（诚实结论）

| 项目 | 状态 |
|---|---|
| MiuiCamera 隐藏 | ✅ overlay whiteout，`/product/priv-app/MiuiCamera` 不再可见 |
| OplusCamera 系统安装 | ✅ `flags=[SYSTEM ...]`、`privateFlags=[... PRIVILEGED PRODUCT]`、`codePath=/product/priv-app/OplusCamera` |
| 进程启动 | ✅ `u:r:oplus_camera_app2`，在 Enforcing 下启动（域本身 permissive） |
| Camera 0 打开 | ✅ `dumpsys media.camera` 显示 Device 0 open |
| session 配置 | ✅ 使用修改后的 ODM `camera_unit_config`，`onSessionConfigured` 成功 |
| 预览首帧 | ✅ `CameraPreviewCallback ... first frame arrive`，`repeatingRequestEnd` 持续 |
| 拍照成片 | ❌ 快门点击后 `capture, decisionResult is null` / `isReadyToCapture ... so return`，未落盘 |
| 相册跳转 | ⚠️ 仅安装 `com.coloros.gallery3d` 占位包，缩略图/相册功能不完整 |

**不能把本次结果称为“相机移植完成”。** 预览链路已经打通到首帧，但 Oplus 的预览决策
（`decisionResult`）没有产出，快门被 BaseMode 拒绝；需要继续处理缺失的 Oplus 私有库、
预览决策配置或改走 V24 相机的 stream/decision 补丁。

---

## 2. 为什么不能简单替换 APK

`/product/priv-app/MiuiCamera` 在 `packages.xml` 中已有 `com.android.camera` 记录
（`isOrphaned=true`，测试证书）。把同目录的 `MiuiCamera.apk` 换成 `com.oplus.camera` 后，
PackageManager 不会把它当作新包扫描：

- 旧记录仍占用同一 codePath；
- 系统扫描时路径冲突，`com.oplus.camera` 不会进入系统包表；
- 作为用户 app 安装会触发 hidden API 黑名单（`PropertyInvalidatedCache.<init>(I,String)`），
  且拿不到 priv-app 权限。

因此最终改用 **目录级 overlay**：在 `/product/priv-app` 上挂 tmpfs+overlayfs，新增
`OplusCamera`、`MiuiCameraProviderStub`、`ColorOSGalleryStub`，同时用 whiteout 把
`MiuiCamera` 从 lower EROFS 中遮掉。lower 分区完全未改。

---

## 3. 负载与挂载点

模块 `kernel-src/ksu-module/camera/`：

| 文件 | 作用 |
|---|---|
| `priv-app/MiuiCamera/OplusCamera.apk` | LUT stub 后的 OplusCamera 6.020.888（SHA-256 `474dcfa0...`） |
| `priv-app/MiuiCamera/MiuiCameraProviderStub.apk` | 小米相册 `com.xiaomi.camera.parallelservice.stub` Provider |
| `priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk` | `com.coloros.gallery3d` 元数据占位，避免 `Util.e0` 空 Bundle NPE |
| `etc/camera_unit_config` | ODM SAT photo 去掉 wide RAW16 与全部 RAW output 的 JSON |
| `etc/permissions/privapp-permissions-com.oplus.camera.xml` | 特权权限白名单 |
| `etc/default-permissions/default-permissions-com.oplus.camera.xml` | 默认权限 |
| `etc/sysconfig/hiddenapi-package-whitelist-com.oplus.camera.xml` | hidden API 白名单 |
| `sepolicy.rules` | `oplus_camera_app2` 域创建、属性集合、数据 allow、`permissive` |
| `libnativewindow.so` | P010 `0x7fa30c0a` 分支补丁 |

`camera_fix.sh` 在 post-fs-data 执行：

1. bind mount `libnativewindow.so` 到 `/system/lib64/`；
2. resetprop `ro.oplus.camera.defercap.*=1`；
3. bind mount 修改后的 `/odm/etc/camera/config/camera_unit_config`（必须在 camera provider
   启动前，provider 会缓存该文件）；
4. tmpfs 512M + overlayfs 挂 `/product/priv-app`；
5. 合并 `/product/etc/permissions`、`default-permissions`、`sysconfig`；
6. `ksud sepolicy patch` 创建 `oplus_camera_app2` 并设置 permissive；
7. 在 `/product/etc/selinux/product_seapp_contexts` 首行插入
   `com.oplus.camera -> oplus_camera_app2` 并 bind mount。

---

## 4. SELinux：为什么新建 `oplus_camera_app2`

OS4 的 vendor 公共策略里有 `opluscamera_app` 类型和 `opluscamera_app_202404` 属性，但：

- 直接 `runcon u:r:opluscamera_app:s0` 返回 `Invalid argument`，该名字在运行时策略里不是
  可用的进程类型；
- `seapp_contexts` 指向它后，zygote `selinux_android_setcontext` 失败，进程 SIGABRT；
- 即使给它 `appdomain` 属性，内核仍拒绝该 context。

最终用 KSU live patch 新建 `oplus_camera_app2`（带 `type` 声明），加入：

```
domain, appdomain, priv_app_all, opluscamera_app_202404,
mlstrustedsubject, halclientdomain, hal_camera_client,
hal_graphics_allocator_client
```

并把该域设为 **permissive**。这样 vendor 里已有的 camera HAL/offlinecamera 规则通过
`opluscamera_app_202404` 继承，同时不会因为 OS4 缺失的通用 app 规则（binder/GPU/proc 等）
让相机进程启动失败。系统其余域保持 Enforcing。

> 安全边界：permissive 只作用于 `com.oplus.camera` 的专用域，不是 `setenforce 0`；但确实
> 放宽了该 app 的 SELinux 约束。后续若要回到严格模式，需要补齐 `appdomain` 的
> binder/GPU/proc/file 等规则，而不是继续扩大 `priv_app_36`。

---

## 5. APK 内改动（LUT stub）

OS4 没有 RMX 的 `libCombineLutJni.so`，OplusCamera 在 `CombineLutJNI.<clinit>` 直接
`System.loadLibrary("CombineLutJni")`，导致 preview GL 线程 `UnsatisfiedLinkError`。

本次对 APK 做最小改动：

- `classes31.dex`：把 `CombineLutJNI.<clinit>` 中的 `invoke-static System.loadLibrary`
  三条指令替换为 `nop`；
- `classes12.dex`：`CombineLutHelper.init(...)` 两个重载直接 `const/4 p0, 1; return p0`，
  让 `Lut3dDataManager` 走“init failed”分支，跳过可选 3D LUT 路径。

重建流程：

```
zipalign -p -f 4  (重建 APK 后)
apksigner sign --ks os4/camera_patch/fullsave_camera_test.jks \
  --ks-key-alias camera --ks-pass pass:changeit --key-pass pass:changeit
```

签名证书保持 `CN=RMX5010 OplusCamera FullSave Test`，与系统包记录一致。

**这不是完整修复**：3D LUT/自然色调功能被禁用；其余依赖 `libCombineLutJni.so` 的路径不会
执行。后续若拿到 OS3 product 的 32 个 RMX private libs，可恢复该库并回滚 stub。

---

## 6. gallery 占位

OplusCamera 在 `Util.e0(Context, String)` 里直接：

```
getPackageInfo("com.coloros.gallery3d", 0x80)
  .applicationInfo.metaData.getBoolean(key)
```

OS4 没有 ColorOS 相册，`metaData` 为 null 时 `SeamlessUIControl` 构造直接 NPE，Activity
无法启动。本次安装了一个 3KB 的 `com.coloros.gallery3d` 占位 APK，带以下 meta-data：

```
isIntegrationUITransitionSupported=false
isSupportBlurEdit=false
isSupportEarlyStart=false
isSupportAIIDPhoto=false
isSupportMediaInfoInsert=false
```

模块 post-boot 在包不存在时 `pm install -r`。它只解决“包/元数据存在”，不提供真实相册。

---

## 7. ODM `camera_unit_config` 改动

原配置 `sat_photo_case` 同时请求：

```
raw16_output rear_main / rear_wide / rear_tele
raw_output   rear_main / rear_wide / rear_tele
capture_yuv  rear_main / rear_wide / rear_tele
...
```

小米 HAL 对 physical camera 3（rear_wide）返回：

```
Camera 0: No supported stream configurations with format 0x20 defined
PhysicalCameraId: 3
```

0x20 = RAW16。即使把 wide RAW16 去掉，raw16 与 raw_output 对同一 physical camera 复用
同一个 Surface，又会报 `Surface already has a stream created for it (ID 2)`。

本次模块负载中去掉：

- 所有 usecase 的 `raw16_output rear_wide`；
- 所有 usecase 的 `raw_output rear_main/rear_wide/rear_tele`（保留 `raw_output var_camera`）。

session 因此能配置成功，但这也可能是 `decisionResult` 为空的原因之一；后续应优先做
**按 operation mode 的 getSurfaceSize 补丁**（参考 OS3 V24 的 PortraitMode 补丁），而不是
长期删除 raw 流。

---

## 8. 实机验证证据（2026-10-29）

```
pm path com.oplus.camera
  -> /data/app/...（系统 base 在 /product/priv-app/OplusCamera）
dumpsys package com.oplus.camera
  flags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA LARGE_HEAP ]
  privateFlags=[ ... PRIVILEGED PRODUCT ... ]

ps -A -o LABEL | grep com.oplus.camera
  u:r:oplus_camera_app2:s0:c512,c768

dumpsys media.camera
  Device 0 is open. Client instance dump

logcat
  onSessionConfigured, block!
  repeatingRequestEnd: frameNumber:6 ...
  CameraPreviewCallback, onPreviewMetaReceived, first frame arrive
```

快门失败：

```
OCAM_CameraControlUI: onShutterButtonClick
OCAM_p2_BaseMode: capture, decisionResult is null
OCAM_p2_BaseMode: isReadyToCapture, decisionResult is null or mCameraId not matched
OCAM_p2_BaseMode: capture, failed in screen torch mode
```

---

## 9. 下一步（未完成）

1. 找到/补回 RMX 的 32 个 private libs（至少 `libCombineLutJni.so`），回滚 LUT stub；
2. 对比 OS3 V24 `PortraitMode/PhotoMode.getSurfaceSize`，按 operation mode 修正 wide RAW
   尺寸，恢复 raw 流而不是删除；
3. 追 `decisionResult` 来源（Oplus PreviewDecision / vendor tags `flash.status`、
   `iris.aperture.switching` 等），确认是缺失库、ODM 决策配置还是 SAT camera 选择问题；
4. 处理 `com.coloros.gallery3d`：安装真实 OplusGallery 或让 App 使用小米相册；
5. 成片、相册跳转、前摄/长焦/录像/人像逐项验收后，才可把状态改为“完成”。

---

## 10. 回退

- 删除模块 `camera/` 负载或关闭 `camera_fix.sh` 中的 `ensure_camera_port` 调用，重启后
  `/product/priv-app/MiuiCamera` 恢复可见（但 `com.android.camera` 仍被用户态禁用）；
- `cmd game reset com.nexon.bluearchive` 可清掉游戏 custom 覆盖；
- 相机域 permissive 只存在于 live policy，重启后由模块 `sepolicy.rules` 重新施加；
  卸载模块并重启即恢复原策略。

---

## 11. 2026-10-30 01:00–02:10 追加诊断（当前真实状态）

这一轮先把 `decisionResult` 问题推进了一步，但**仍未成片**，且发现了比 APS 更关键的
运行时代码来源问题。结论如下。

### 11.1 已确认进展

- `OCAM_CaptureProcessor: onPreviewDecisionResult, first result, feature: 0, scene: 0,
  multi-frame count: 0` 已出现，说明预览决策不再返回空；
- Camera 0 打开、`onSessionConfigured`、`preview` 持续出帧（`cameraServer send preview
  frame`）均正常；
- 当前快门失败日志变为：

  ```
  CameraUnit, ProducerImpl: takePicture, not allow take picture,
    mbApsFinishAddFrame: true, isApsCaptureAlgoInitializing: true,
    checkResult: 1, isCShot: false
  OCAM_ApsService: onCaptureFailed
  ```

  `checkResult: 1` 说明 `isAllowedToTakePicture` 先返回了 1（模式暂时不允许拍），
  并非单纯 `decisionResult` 为空；APS 初始化也仍是 true。

### 11.2 试过但无效/已回退

1. **OnePlus `libAlgoInterface.so` / `libAlgoProcess.so` 覆盖 `/odm/lib64`**：
   参考仓库 README 明确把“单独换官方 `libAlgoInterface`”列为已知相机故障项，已回退，
   `camera_fix.sh` 不再挂载这两个文件；当前使用 RMX ODM 原配。
2. **SAT photo 改 raw16 main/tele、去掉 raw_output**：session 仍能配置，但
   `capture_meta` 流 `Frames produced: 0`，APS 初始化仍卡住，已回退到 rawout_notwide。
3. **APK dex 补丁**：对 `com.oplus.ocs.camera.consumer.ConsumerImpl` 和
   `ProducerImpl.takePicture` 的 `isAllowedToTakePicture` / APS 门禁做了返回 false /
   跳过分支的补丁，并把日志字符串改成唯一 marker `takePicture, PATCHCHECK, ...`；
   重新打包、签名、作为 `/product/priv-app/OplusCamera/OplusCamera.apk` 替换并清空
   `/data/dalvik-cache`、`/data/user/0/com.oplus.camera/cache/oat_primary` 后重启。
   运行日志**仍打印旧字符串**，证明运行中的进程没有执行 overlay 替换后的
   `classes31.dex`；实际执行的是预加载/AOT/旧副本。K6b APK 与 rawout_notwide 已恢复，
   当前模块回到可启动、可开会话的保守状态。

### 11.3 预览黑屏 / `CameraScreenNail` 告警

- `OCAM_CameraScreenNail: onFrameAvailable, surfaceTexture does not correspond` 持续出现，
  `CameraScreenNail.draw` 里 `mbFirstFrameArrived false`；`SurfaceTextureScreenNail`
  仍在 `addImageBuffer`。
- 截图曾出现纯黑但 UI 正常；当时 SurfaceFlinger 显示输出层 `isSecure=true`，不能排除
  HyperOS 对相机预览做了截屏保护，因此“截图黑”不等于“屏幕一定黑”。该路径尚未做
  肉眼验收，按未完成处理。

### 11.4 当前设备状态（02:10）

- 模块 `rmx5010_fod_bridge` 1.4.1，已启用；相机负载为 K6b APK、rawout_notwide 配置；
- `camera_fix.sh` 已去掉 OnePlus Algo 库挂载；
- 屏幕已锁（`mWakefulness=Dozing`, `mScreenState=DOZE`），相机已 force-stop；
- 旧的 APS/marker APK 仅留在 `os4/camera_patch/` 作为诊断产物，不参与启动。

### 11.5 下一步建议（按优先级）

1. **改镜像而不是 overlay**：把 K6b/后续补丁 APK 与 `camera_unit_config` 直接写进
   product/system_ext 镜像再刷入；这与“之前改镜像测试可行”的路线一致，也能绕开
   预加载/AOT/旧副本问题。镜像构建基线已备份为 `os4/system_ext_current.img`。
2. 镜像级替换后重新验证 `PATCHCHECK` marker 是否出现；若出现，再判断
   `isAllowedToTakePicture=1`（zoom/preview 未 ready）和 APS init 的具体分支。
3. 若 APS 仍卡住，优先从 vendor/ODM 的 APS sensor mode / `capture_meta` 流入手，
   不要再用 OnePlus algo 库硬替换。
4. 成片、前摄、长焦、人像、录像逐项验收后，才能把 D43 改为完成。


---

## 12. 2026-10-30 10:20–10:40 结果：主摄成片打通（1.5.0）

### 12.1 真正的代码来源

上一节判断“必须改镜像”后，进一步把实际加载的类定位清楚了：

- `CameraScreenNail` 等在 **APK classes12**；
- `ProducerImpl`、`Camera2Impl`、`ConsumerImpl` 在 **`/system_ext/framework/com.oplus.camera.unit.sdk.jar`**；
- 应用 classloader 日志明确：
  `PathClassLoader[DexPathList[[zip file "/system_ext/framework/com.oplus.camera.unit.sdk.jar"], ...]]`。
- 所以之前改 APK 的 `ProducerImpl` 门禁不生效；改 JAR 后才生效。

### 12.2 已刷入的镜像

- 从 `/dev/block/dm-21` 备份 product：`os4/product_current.img`；
- 修改 stage：删除 `/product/priv-app/MiuiCamera`，加入
  `/product/priv-app/OplusCamera/OplusCamera.apk`（preview-patched，SHA-256
  `20fca02614c50fe61ae67700b49de30a5c771d9c59fd16dacc04f519e8cd5350`）及权限 XML；
- 生成 `os4/product_camera_preview.img`（4,300,865,536 字节，EROFS lz4hc；
  SHA-256 `0e0cbe994e185074ac768d0894f5fc8c2311a73b370602a4c767ba25b7325e3e`），
  `fsck.erofs` 通过；
- `fastboot flash product_a` 成功，重启进入系统；Current slot `_a`；
- 由于 product 分区满，**app private libs 仍由 KSU 模块注入**，镜像只放 APK。

### 12.3 JAR 补丁（`com.oplus.camera.unit.sdk.jar`）

- 跳过 `ProducerImpl.takePicture` 的 `isAllowedToTakePicture` / APS 门禁；
- `Camera2Impl.takePicture` 入口强制 `mRequestNum=1`；
- `updatePreviewTarget` 对空 `mbNeedPreviewStream` 数组直接返回，避免
  `ArrayIndexOutOfBoundsException`；
- `ConsumerImpl$InnerCameraPictureCallbackAdapter.onImageReceived` 在
  `mCameraPictureCallbackAdapter` 为空时直接写 JPEG：
  `/sdcard/DCIM/Camera/OPLUS_<System.currentTimeMillis()>.jpg`，并调用
  `MediaScannerConnection.scanFile` 入库；
- APK `aj.h`（`CameraScreenNail`）在 SurfaceTexture 不匹配时接受新 texture，
  不再直接 return。

### 12.4 配置

- `mode_type_list` 删除 `rear_sat`，让照片模式落到 `rear_main`（Camera ID 0），
  绕开 SAT/APS 离线 Bayer2Yuv；
- `professional_case` 去掉重复 `raw_output`；
- 当前 `/odm/etc/camera/config/camera_unit_config` 为 `camera_unit_config_no_sat.json`
  （`rawout_notwide` 基础上修改）。

### 12.5 实测证据（屏幕关闭前完成）

```
OCAM_CameraCore: openCamera, ID: 0
CameraUnit, Camera2Impl: takePicture start, mRequestNum: 1
CameraUnit, Camera2Impl: takePicture, captureBurst request to HAL
CameraUnit, ConsumerImpl: onApsJpegArrived, image orientation: 90
OCAM_CaptureProcessor: completeCapture, capture: 1, success: true
MediaScannerConnection: Scanned /sdcard/DCIM/Camera/OPLUS_1793327286252.jpg
```

产物：

- `/sdcard/DCIM/Camera/OPLUS_1793327286252.jpg`
- `/sdcard/DCIM/Camera/OPLUS_1793327378672.jpg`
- 均为 4096×3072 JPEG，约 777–780KB，MediaStore 可查询。

暗场测试图像 mean≈4、max≈46（房间 lux≈1），不是纯 0 空 buffer；画质需白天复测。
预览截图在暗场仍近黑；`surfaceTexture does not correspond` 日志已消除，但需要在正常光照下
肉眼确认预览。**SAT/长焦/超广/人像/前摄/录像尚未逐项验收。**

### 12.6 当前版本与回退

- 模块已升到 **1.5.0 / versionCode 17**；屏幕已关（`mScreenState=OFF`），AOD 关闭；
- product 备份 `os4/product_current.img` 可 fastboot 回刷；
- JAR 补丁在模块 `/system/system_ext/framework/com.oplus.camera.unit.sdk.jar`，
  可删除/替换回原版；
- 删除 `camera_unit_config` 的 `rear_sat` 修改即可恢复 SAT（但当前 HAL APS 仍会失败）。


### 12.7 前摄实测（2026-10-30 10:59）

UI 上的切换按钮在当前状态没有触发切换（点击无响应），但 OplusCamera 支持系统相机
`CAMERA_FACING` extra，直接启动前摄：

```bash
adb shell am start -n com.oplus.camera/.Camera \
  --ei android.intent.extras.CAMERA_FACING 1
```

实测：

```
OCAM_CameraCore: openCamera, ID: 1
OCAM_PreviewRenderer: createCameraScreenNail, frontCamera: true
CameraSessionEntity{ mCameraType='front_main', mPictureSize=4608x3456, ... }
Camera2Impl: takePicture start, mRequestNum: 1
ConsumerImpl: onApsJpegArrived, image orientation: 90
OCAM_CaptureProcessor: completeCapture, capture: 1, success: true
MediaScannerConnection: Scanned /sdcard/DCIM/Camera/OPLUS_1793329158722.jpg
```

产物：`OPLUS_1793329158722.jpg`，2304×1728 JPEG，1,597,368 字节，
mean≈121.8 / max=255 / std≈80，是正常亮度的前摄画面，不是黑图。
说明摄像头打开、成片、保存链路对前摄同样有效；UI 切换按钮/预览渲染仍是独立问题。


### 12.8 预览修复（2026-10-30 11:24–11:33）

预览黑屏的根因不是没有帧，而是 `CameraScreenNail` 的首帧状态与 GL 重绘触发不匹配：

- `PreviewProcessor` 每帧把 YUV buffer 加入 `mCachePreviews` 后调用
  `CameraScreenNail.onFrameAvailable`；
- 首次 `draw` 在首帧到达前执行，设置了 `M0=true` 后因 `N0=false` 提前返回，
  后续帧不再触发 GL 重绘；
- 表面纹理还会出现 `surfaceTexture does not correspond`，旧逻辑直接 return。

最终补丁（APK classes12）：

1. `CameraScreenNail.onFrameAvailable` 在纹理不匹配时接受新 texture 并继续；
2. `CameraScreenNail.draw` 提前返回时把 `M0` 复位为 false；
3. `PreviewProcessor` 在首帧（`N0=false`）时向 `CameraScreenNail.k` Handler
   post 一次 `T0`，kick 首次 GL 重绘；后续帧由原逻辑继续触发。

结果：前摄预览截图 mean≈79（max 204、std 95），不再纯黑；相机进程稳定，
无 VerifyError/原生崩溃，快门可正常成片。

最终镜像：`os4/product_camera_final.img`，SHA-256
`27108ed3ea6c1113b7f3cad8ca5970333cefd7f11f43d6d7bdcd0cdd726fa236`；
product APK `OplusCamera_preview6_signed.apk`，SHA-256
`89f02709ecc4baca9da0bec13730dde42f42fafc56f39c4cf9f5ea9e6d7d3393`。
刷入后重启，前摄预览 + 成片 `OPLUS_1793331193356.jpg` 验证通过；屏幕已锁。

### 12.9 仍缺

- 相机 UI 的前后摄切换按钮点击无响应；前摄目前用
  `--ei android.intent.extras.CAMERA_FACING 1` 启动。
- SAT/长焦/超广/人像/录像未逐项验收；为绕开 APS 已从 `mode_type_list` 去掉 `rear_sat`。
- JAR 直写 JPEG，未走原生 Oplus 保存/后期，画质与 HDR/美颜等不完整。

### 12.10 完整算法尝试（2026-10-30 12:10–12:30）与结论

为保留完整 Oplus APS/HDR/SAT 算法，恢复了原版
`com.oplus.camera.unit.sdk.jar` 和含 `rear_sat` 的原厂 `camera_unit_config`，并尝试
system_ext/priv-app 布局。结果：

- 原版 JAR + 原厂配置：相机打开 `Camera ID: 12`（rear_sat），但
  `isApsCaptureAlgoInitializing` 卡住，`takePicture` 仍被拒。
- 追踪到 APS 配置解密依赖：
  `libOplusStringJNI-extension.oplus.so` → `libvndksupport.so@LIBVNDKSUPPORT`
  → `libdl_android.so` → `ld-android.so`。
  app 的 `clns-11` 命名空间无法访问这串私有库；自建 stub 能让 extension 加载，
  但 `getString` 无法加载 base，`oplus_camera_config` 解密失败，APS 仍不初始化。
- 用 system_ext/priv-app overlay 试图切换命名空间时，system_server 启动阶段异常，
  设备卡在开机动画；已通过禁用 KSU 模块恢复，随后回退到 product overlay 的可用状态。
- 工作区中已找不到之前 OS4 的 V24 完整 product 镜像
  （`os4_rmx5010_camera_oplus_domain_v3`）；OS3 的 V24 APK 也不在本机。
  因此当前无法凭空恢复“完整算法”的闭包。

当前设备状态（已恢复可用、屏幕已关）：

- product 镜像的 OplusCamera + 模块预览补丁 APK + `unit.sdk.basic.jar` + `no_sat` 配置；
- 主摄自动/专业、前摄、预览、DCIM 落盘 + MediaStore 可用；
- 完整 APS/HDR/SAT 算法未保留；需要上一版 V24 完整包（APK + JAR + 32 私有 libs +
  ODM 配置）或正确的 OS4 RMX system_ext 闭包才能继续。
- 模块 1.5.0，屏幕 `mScreenState=OFF`，无临时 disable 文件。

---

## 13. 6.070.45 完整算法打通（2026-10-30 13:30–13:50）

### 13.1 结论

16.0.7.201 原厂包里的 OplusCamera **6.070.45** 已作为数据区更新安装并跑通完整
APS 拍摄链路；成片由相机自身原生保存，不再使用 JAR 直写。界面是这版原厂包的
新 UI（与旧 6.020.888 不同），但包本身属于 RMX5010 的 16.0.7.201 原厂闭包。

实测：

- `Camera2Impl: takePicture start, mRequestNum: 8`（多帧，不是强制单帧）；
- APS/TurboHDR/ArcSoft/离线 Bayer2Yuv 均进入处理；
- `completeCapture success: true`、`onApsJpegArrived`；
- 落盘 `/sdcard/DCIM/Camera/IMG20261030134110.jpg`，3072×4096，1,686,742 字节；
- EXIF：`RMX5010 back camera 23mm f/1.8`、ISO 12800、0.3s，MakerNote 为 Oplus
  APS 数据；
- 重启后再次拍摄 `IMG20261030134809.jpg`（1,669,711 字节，3072×4096），链路仍可用。
- 前摄同样跑通：`IMG20261030135104.jpg`，3456×4608，4,042,729 字节，
  mean≈129；EXIF 前摄 f/2.5、ISO 1600，MakerNote 为 Oplus APS 数据，
  `completeCapture`/`onApsJpegArrived` 各 1 次，无原生崩溃。

> 画面接近全黑是因为手机平放在桌面、后摄镜头被遮挡；不是预览/算法失败。
> 前摄正面预览此前已正常，后摄平放时黑屏属于拍摄环境。

### 13.2 本次真正修掉的三个问题

1. **Codec2 启动 SIGABRT**
   - 不是 OS4 缺 `media.codec`，而是自建 SELinux 域被反向拒绝：
     `mediacodec`/`mediaswcodec` 对 `oplus_camera_app2` 的 binder `transfer`
     为 Enforcing，Codec2Client 收到空客户端后 abort。
   - 增加双向 `call/transfer` 规则后，`default`/`software` Codec2 客户端均可用。

2. **6.070 启动约 5 秒崩溃**
   - `NoClassDefFoundError: com.oplus.app.OplusHansFreezeManager`：在 APK
     `classes35.dex` 增加一个最小 stub（`getInstance()` +
     `requestFastFreeze(Context,int,String)` 返回 0）。
   - `TypeFaceUtil.a(Context)` 读取 OS4 不存在的
     `OplusBaseConfiguration.mOplusExtraConfiguration` 触发 NPE；在
     `TypeFaceUtil` 的 try 区补 `NullPointerException` catch，回落
     `Typeface.DEFAULT`。

3. **离线相机 callback 为空 / SIGSEGV**
   - `hal_camera_default` 反向调用 `oplus_camera_app2` 的 binder 被拒，事务返回
     `Operation not permitted`，provider 看到空 descriptor，
     `openOfflineSession` 报 `ILLEGAL_ARGUMENT`，随后
     `configureOfflineStreams` 空指针 SIGSEGV。
   - 增加 `hal_camera_default` 与 `oplus_camera_app2` 的双向
     `binder { call transfer }`。
   - 注意：`ksud sepolicy check` 会把策略文件里的 `#` 注释当规则解析，导致整份
     策略校验失败、开机不建域。策略文件必须保持纯规则，不能写注释。

### 13.3 预览 HDR

- 没有保留 `persist.camera.override_*` 降级；测试时将
  `persist.camera.override_enable` 设为 `false`，使用原厂默认预览 HDR。
- 该状态下完整拍摄仍成功，说明之前的黑预览是镜头被桌面遮挡，而不是 P010
  预览格式失效。`SnapAlloc` 的格式日志只作为观察项，不再作为黑屏结论。

### 13.4 持久化

- `camera/sepolicy.rules`：加入 `mediacodec`、`mediaswcodec`、
  `hal_camera_default` 三组双向 binder 规则，纯规则无注释；
- 模块 APK 更新为 `OplusCamera_hans2_signed.apk`：
  SHA-256 `1b5481edc3132dcfc2a413a965fa0cddb7ae38614e3aab1a3185b8af36ee7a40`；
- 模块 `camera/libvndksupport.so`（5,776 字节）与
  `camera/lib2DSlender.so`（1,453,928 字节）作为数据区 lib 源；
- `camera_fix.sh` 的 `camera_post_boot` 新增 `camera_fix_data_app_libs`，
  开机后把上述两个库复制到当前 `/data/app/.../com.oplus.camera-*/lib/arm64`；
- 重启后已实测：SELinux 规则生效、数据区 APK 保留、库自动复制、完整拍摄成功。

### 13.5 验收状态

已确认可用（2026-10-31 实机）：

- 后摄 0.6x / 1x / 2x / 3x / 6x 变焦，0.6x 会切到 `rear_wide` 物理相机；
- 前后摄 UI 切换按钮；
- 前摄照片 3456×4608；
- 人像模式（前摄）拍摄成功；
- 录像模式 MP4 保存成功；
- 完整 APS 多帧算法、原生保存、重启后保持。

尚未逐项验收：

- 慢动作、专业模式、全景、街拍/更多里的其余子模式；
- 相册缩略图跳转（ColorOS gallery 仍是 stub）；
- 其他 Oplus 框架类是否还有缺失。

### 13.6 变焦/长焦/超广角阻塞（2026-10-31）

实测 zoom 条拖动本身有效：

```text
OCAM_ZoomPresenter: CameraTest change zoom: 0.83 -> 0.6
```

但每次同时出现：

```text
OplusSatBridge: OPlus transaction code=10015 has no extension target
OCAM_c2_BaseMode: getIZoomTriggerState, zoom not ready: true
OCAM_ZoomPresenter: buildPreview, com.oplus.zoom.active: false
```

结论：不是 UI 不响应，而是 **Oplus SAT bridge 的 vendor transaction 10015
没有 extension target**，相机因此始终认为 zoom 未 ready，2x/3x/6x/0.6x
只改 UI 数字，不切物理相机/不改变流。

尝试过：

- stock ColorOS `libcsextimpl.so` + `vendor.oplus.hardware.cameraextension@1.0.so`
  / `-V1-ndk.so` 放入模块 overlay：cameraserver 可启动，但 10015 仍无 target。
- stock `libcameraservice.so` + `libcamera_client.so` bind mount：与 OS4
  `libandroid_runtime` ABI 不兼容，`app_process` 报
  `CameraBase<...>::getCameraInfo` 符号缺失，已立即回退并重启恢复。
- 当前模块已恢复 OS4 `libcsextimpl.so`（SHA-256 `6995cba2...`），设备
  boot_completed=1、cameraserver 正常。

要真正修复 zoom/SAT，需要给 `libsatbridge.so` 补一个可用的
`CameraServiceExtFactory`/`CameraServiceExtImpl::onTransact` 扩展目标，
或使用与 OS4 cameraserver/client ABI 匹配的 stock 相机服务闭包；
仅换 `libcsextimpl`/cameraextension 库不够。

### 13.7 变焦/SAT 已修复（2026-10-31 最终结论）

13.6 的判断不完整：`libsatbridge.so` 的扩展目标其实已经能创建，真正失败点是
**`libcsextimpl.so` 的 `dlopen(RTLD_NOW)` 因缺少 NEEDED 依赖而返回 NULL**。
原 shim 只在 `dlopen` 失败时打印 `dlopen OPlus extension failed`，但当时日志
缓冲区已滚动，只留下后续的 `has no extension target`，导致误判为 factory 问题。

用带完整日志的临时 shim 复现后，依次缺：

```text
vendor.oplus.hardware.performance-V1-ndk.so
android.hardware.camera.common-V1-ndk.so
liboplus-uah-client.so -> vendor.oplus.hardware.urcc-V1-ndk.so
vendor.oplus.hardware.cameraextension@1.0.so
vendor.oplus.hardware.cameraextension-V1-ndk.so
vendor.oplus.hardware.sendextcamcmd-V2-ndk.so
```

这些库在 201 原厂包的 `/odm/lib64`、`/vendor/lib64` 或本地提取物中都有；
把它们放进模块的 `system/system_ext/lib64/`（cameraserver 的 default
namespace 可见）即可。补齐后：

```text
OplusSatBridge: OPlus transaction code=10015 status=0 flags=17
OCAM_ZoomUIManager: CameraTest switch to wide camera
```

不再出现 `has no extension target`。实机验证：

- 0.6x：`change zoom: 0.6`，切 `rear_wide`（physicalCameraId 2），
  SAT 同时取 `rear_wide` 1728×1296 与 `rear_main` 4096×3072；
- 2x：主摄数字变焦，`IMG20261031030203.jpg` 3072×4096；
- 3x/6x：长焦 73mm，`IMG20261031030208.jpg` / `IMG20261031030213.jpg`；
- 前摄：`IMG20261031030636.jpg` 3456×4608；
- 人像：`IMG20261031030705.jpg`；
- 录像：`VID20261031030816.mp4`，MediaStore 扫描成功；
- 重启后再次验证 0.6x/2x/6x 仍正常。

新增库（模块 `system/system_ext/lib64/`）：

| 库 | 大小 | SHA-256 |
|---|---:|---|
| `vendor.oplus.hardware.performance-V1-ndk.so` | 282104 | `1e905112c9945309d34e9a4c07849d587eaeacf8dd3fe379c81fc1360456d392` |
| `vendor.oplus.hardware.cameraextension@1.0.so` | 77576 | `b20399eb443d4ce9b601a75823ed8c51ae78e5982ac01c828f49777b510c76e4` |
| `vendor.oplus.hardware.cameraextension-V1-ndk.so` | 36072 | `c56ca6e07f307179b9f5ee56aaec079bd5c7a93ccad103d4901aecd988332662` |
| `vendor.oplus.hardware.sendextcamcmd-V2-ndk.so` | 52488 | `31b5f4683a909c9674a004b00332c704b4ff4c6b6d69fde7bccb65993ab58816` |
| `android.hardware.camera.common-V1-ndk.so` | 51840 | `d7476170457ff79152c541aa5e0dcbf0936615010fd46b72b8d94561acbaed2e` |
| `liboplus-uah-client.so` | 201504 | `ca7fff1a6ad1e50179bd1ef95b51c13e246e137c6775b20a513c52516b87ac26` |
| `vendor.oplus.hardware.urcc-V1-ndk.so` | 151848 | `a2928fc51fb32ae50e51f34b4f35bfbdc37fa025bcfdc525100187f717dba7f0` |

注意：

- `vendor.qti.camera.provider-service_64` 里的
  `PrepareSlaveSkipInfo: oplus_set_slave_skip_info is NULL` 是 HAL 先尝试
  `oplus_` 前缀、再回退到 `camera.oemlayer.so` 已导出的
  `set_slave_skip_info` 的正常回退日志，不是阻塞点。
- 0.6x 照片的 EXIF `LensModel` 可能仍写 73mm（Oplus 写入的是主/长焦元数据），
  但实际 capture surface 同时包含 `rear_wide` physicalId 2，SAT 融合成立。
- stock ColorOS `libcsextimpl.so` 仍不建议替换：它的 `getCameraServiceExt`
  依赖 stock `libcameraservice` 的工厂初始化，和 OS4 cameraserver 混用会返回
  NULL；保持 OS4 `libcsextimpl.so`（`6995cba2...`）+ 上述依赖即可。


### 13.8 慢动作与更多模式验收（2026-10-31）

慢动作的阻塞点与变焦不同：应用为 1080p240 创建 constrained high-speed
session 时，预览 surface 是 `format 35 (YUV_420_888)`、usage `0x103`；
OS4 框架的 `SurfaceUtils.checkHighSpeedSurfaceFormat` /
`checkConstrainedHighSpeedSurfaces` 认为它既不是 preview 也不是 hardware
video encoding surface，在 session 发出前就抛 `IllegalArgumentException`。
cameraserver 同时打印 `DataSpace override not allowed for format 0x23`。

修复分两处，均为单变量：

1. Sense LSPosed 模块新增 `CameraSlowMotionHooks`，仅在
   `com.oplus.camera` 进程内把 `SurfaceUtils` 的两个高速 session 检查
   no-op；保留应用原本的 high-speed session 和 240fps 请求。
   需要在 LSPosed 管理器里把 Sense 的作用域加上 `com.oplus.camera`。
2. `camera/cameraserver` 打三处小补丁（SHA-256
   `2c2d3fcd4f94ef98f9af2d977721933edd4d6de660c1c3f0fef25b131b35ce18`）：
   跳过 DataSpace override 的错误分支、把该路径的 -22 错误码置 0、
   忽略累计错误标志。原始 cameraserver 仍保留在仓库历史/备份中。

实测：

- 慢动作：`VID20261031034604.mp4`，3,152,505 B，ISO MP4，mvhd 时长
  31.55s，1920×1080 HEVC；4 秒拍摄按 240fps 录制成 8 倍慢放。
- 夜景：`IMG20261031034855.jpg`，1,840,567 B，`mCapMode: night`，
  `completeCapture success`。
- 街拍：`IMG20261031034825.jpg`，1,787,455 B，`mCapMode: street`。
- 高像素：`IMG20261031035051.jpg`，4,298,241 B，6144×8192（50MP），
  `mCapMode: highDefinition`。
- 电影：`VID20261031035201.mp4`，1,452,976 B，MediaStore 扫描成功。
- 多景录像：`.pending-1793994765-VID20261031035245.mp4`，1,848,985 B，
  有效 MP4；停止后 7 秒内未完成 MediaStore 重命名，仍在 pending。
- 后摄人像：`IMG20261031034930.jpg`，2,788,119 B。
- 专业模式：UI 打开，快门发出 `mRequestNum: 4` 的 captureBurst，
  但 APS 保存失败：`APP_saveFail` / `thumbnail_category_fail` /
  `version_aps_not_support`；需要继续补 ProfessionalMode 的 APS 配置。
- 全景：UI 正常显示方向箭头和“点击箭头可切换拍摄方向”，
  拍摄需要实际平移，桌面平放条件下未完成。
- 相册缩略图：`com.coloros.gallery3d` stub 只有 manifest、没有
  `classes.dex`，activity 是空的 `android.app.Activity`；点击缩略图
  不会打开查看器。系统里已有 `com.miui.gallery`，但相机 intent 固定
  `setPackage("com.coloros.gallery3d")`，要修需要替换 stub 为转发
  activity 或改相机的 gallery package，当前未做。

已验证可用：0.6x/1x/2x/3x/6x、前摄、后摄人像、夜景、高像素、街拍、
电影、多景录像（录制成功，finalize 待修）、慢动作、普通录像、完整 APS。

### 13.9 专业模式补充诊断（2026-10-31 后续）

专业模式继续排查结果：

- HAL 侧正常：`takePicture mRequestNum: 4`、`captureBurst request to HAL`、
  `onHalPictureImageArrived`，4 帧 `pictureProcess` 都到了。
- APS 侧没有对应 pipeline：
  `APSProcPipeline getPipelinesList() should not run here`、
  `APSCaptureAlgoTriggerDecision captureAlgoTriggerMode is nullptr`，
  `ApsParameters` 还主动 `remove key: capture_algo_list`。
  应用生成了 `newImage, jpeg` 和缩略图，但 APS 永远不回调
  `onApsJpegArrived`，所以没有 `completeCapture`/`Picture Save End`。
- 曾用 Sense hook 把专业模式 `getSupportFunction("type_still_capture_jpeg")`
  强制为 true，试图走 direct-JPEG；HAL/APS 仍没有完成保存，已回退该 hook，
  当前设备仍使用只含慢动作 hook 的 release Sense APK。
- 曾把 `professional_case` 的 `capture_raw`/`raw_output`/`capture_raw_dol`
  去掉测试，仍未保存；配置已恢复原样。
- 曾临时卸载 `com.coloros.gallery3d` 导致 `Storage` 的
  `PackageManager$NameNotFoundException`；已用 v2 重签 stub 恢复包名，
  但 stub 仍是空 activity，缩略图不会打开查看器。

结论：专业模式需要补 ProfessionalMode 的 APS pipeline/trigger 配置，
属于 APS 服务/配置层，不是单纯补库或换 surface 能解决。

### 13.10 专业模式已修复（2026-10-31）

13.9 的 APS pipeline 缺失，根因在 `ApsDataConvert` 的 capture mode 映射：
`professional_mode` 先尝试 `professionalFull`，再尝试 `master`，最后回退
`professional`；这三个 pipeline 在当前移植的 APS 配置里都没有可用节点，
所以 `APSProcPipeline.getPipelinesList()` 为空、`captureAlgoTriggerMode`
为 nullptr，APS 永远不回调。

修复：最终采用 **Sense LSPosed hook**，在 `com.oplus.camera` 进程内 hook
`com.oplus.ocs.camera.consumer.ApsDataConvert.getApsModeName(String,int)`；
当 modeName 为 `professional_mode` 时把结果改为 `common`（普通照片模式
使用的 APS capture mode）。**原厂 `unit.sdk.jar` 保持不变**，因此不会
影响慢动作和其他 APS 模式。

- 原厂 jar SHA-256：`833fecd0e5613ecbd9e87cab2d6afa3eac2ce6062ebb133101b09697482209b5`
- Sense 新增 `CameraProModeHooks`；LSPosed 作用域需包含 `com.oplus.camera`
- 曾经尝试直接 patch jar 的 `ApsDataConvert`，专业模式能保存但慢动作
  MediaRecorder stop 失败，已回退，改为上述运行时 hook。

实测（原厂 jar + hook）：

- 专业模式：`IMG20261031043941.jpg`，1,590,484 B，3072×4096；
  `onApsJpegArrived`、`completeCapture success: true`、
  `Picture Save End` 全部出现。
- 慢动作：`VID20261031044023.mp4`，3,130,397 B，
  `Video Flie Save End` + MediaStore 扫描成功。
- 普通照片 2x `IMG20261031043123.jpg` 正常保存；变焦/夜景/人像等
  映射未改动。

注意：专业模式现在走 `common` APS pipeline，而不是原厂专用的
`professionalFull` pipeline；ISO/快门/EV/WB 等手动 metadata 仍随请求
传入，但原厂 professionalFull 的专属后处理在当前移植上不可用。

### 13.11 相册缩略图与剩余子模式（2026-10-31）

相册缩略图已修复：相机 `GalleryHelper` 用 `yn.h1.a()` 返回的包名
`setPackage()`；原来的 `com.coloros.gallery3d` 只有空 stub。Sense 新增
`CameraGalleryHooks`，在 `com.oplus.camera` 进程内把 `yn.h1.a()` 的
返回值改为 `com.miui.gallery`。实测点击缩略图后：
`topResumedActivity=com.miui.gallery/.activity.ExternalPhotoPageActivity`，
系统相册正常打开最新照片/视频。

剩余限制：

- 全景：UI 正常，实际拍摄需要平移手机，桌面平放条件下未完成。
- 星空/移轴：未逐项实拍验收。

已验证可用：0.6x/1x/2x/3x/6x、前摄、后摄人像、夜景、街拍、高像素、
电影、多景录像、慢动作、长曝光、专业模式、普通录像、相册缩略图、
超级文本、延时摄影。

### 13.12 超级文本已修复（2026-10-31）

进入超级文本时 `DocDetector.<clinit>` 调用
`com.common.Util.loadJNILibrary("XDocProcessSDK-jni")`。JNI 库的
`JNI_OnLoad` 会 `dlopen("libSuperTextWrapper.so")`，而 unit SDK jar 的
`PathClassLoader` 命名空间只搜索数据应用的 `nativeLibraryDir`，不搜索
`/system_ext/lib64`，因此报：

```text
JniAPIs: JNI_OnLoad, error: dlopen failed: library "libSuperTextWrapper.so" not found
```

修复分两步：

1. 模块 `camera_fix_data_app_libs` 在开机时把
   `libXDocProcessSDK-jni.so`、`libXDocProcessSDK.so`、
   `libSuperTextWrapper.so`、`libYTCommon.so` 复制到当前
   `/data/app/.../lib/arm64`。wrapper 的依赖和 libc++ 符号均能从应用
   lib 目录解析，JNI_OnLoad 通过。
2. XDoc 的 OpenCL 预览路径 `SetInputTexture` 在 OS4 上返回 16
   （GL/OpenCL 纹理共享失败），SDK 随后对空 buffer 解引用并 SIGSEGV。
   Sense `CameraSuperTextHooks` 把
   `SuperTextHelper.FindQuadByTextureNative` 的返回值改为空串，
   `DocDetectorImpl.FindQuadByTexture("")` 返回内置空结果；捕获仍走
   CPU 的 `detectTextByByteNative`。

实测进入模式不再崩溃，拍摄保存
`IMG20261031052204.jpg`（1,116,364 B，3072×4096）；LSPosed 日志：
`RMX5010HyperOSFix: super text preview quad disabled (GPU path unsafe)`。
限制：实时文档框预览关闭，文字提取/拍摄走 CPU。

### 13.13 延时摄影已修复（2026-10-31）

两个独立问题：

1. OS4 的 `android.media.ImageReader` 删除了 `nativeGetConsumer`，
   `ApsUtils.getConsumerPtr` 反射抛 `NoSuchMethodException` 并返回 0，
   APS 视频适配器每帧丢帧。Sense `CameraTimeLapseHooks` 在 unit SDK 的
   `PathClassLoader` 加载 `ApsUtils` 时挂 hook，直接读取
   `mNativeContext` 指向的 `JNIImageReaderContext`：24 字节 `List` 之后
   offset 24 是 `sp<BufferItemConsumer> mConsumer`，offset 32 是
   `sp<IGraphicBufferProducer> mProducer`，返回 offset 24 的指针。
2. `camera_unit_config` 的
   `mode_type_feature_max_video_size.fastvideo_mode.*.hyper_lapse`
   配置为 2560×1920/2560×1440，而移植机的 APS 输入 buffer 是
   1920×1440，原生管线持续报
   `APSPreviewManager::dispatchInputData input buffer size(1920x1440) role 100 mismatch`，
   编码器 `Qin:0`、muxer 停在 `INITIALIZED`，没有 MP4。模块把
   `fastvideo_mode` 的 `rear_main`/`rear_wide`/`rear_sat`
   `hyper_lapse` 单变量改为 1920×1440 后，APS 尺寸匹配。

实测 `VID20261031054956.mp4`（239,400 B，HEVC 1920×1080，自动倍速
0.43 s）；`OCAM_VideoSaver addVideoToMediaStore` 生成缩略图并
`Video Flie Save End`，无 APS 尺寸/muxer/VCP 错误。

### 13.14 星空/多景录像剩余阻塞与移轴验收（2026-10-31）

移轴已实拍验收：`IMG20261031061513.jpg`，423,897 B，2304×4096；
`TiltShift` 预览 `bokehPreview_process`/`tiltShiftPreview_process`
正常，保存走普通 JPEG 流程。

星空仍不可用。进入星空模式后快门请求 `mRequestNum: 15`、
`mOfflineNightExpTime: 2046`，原生 APS 报：

```text
APSCaptureAlgoTriggerDecision.cpp: getCaptureAlgoTriggerMode() not found
getAllPipelineNodes() captureAlgoTriggerMode is nullptr!
OCAM_CaptureFailInfoUtil: handleMessage, msg: 1
```

即 `ALGO_STARMODE` 的 APS trigger/pipeline 在移植配置里不存在。
尝试过 `ApsDataConvert.getApsModeName`、`ApsParameters.set`、
`MetaItemInfo.setParameter`、`CameraRequestTag`/`ApsRequestTag`
把 `star_capture_mode`/`starry` 改成 `common`，hook 均安装成功，
但原生 trigger 仍按 starry 查找。

进一步从 16.0.7.201 `payload.bin` 提取 `odm`（2.7GB erofs），
用设备自带 `fsck.erofs --extract` 解出 `/etc/camera/config`：

- 201 与设备的 `oplus_camera_aps_config`（58,520 B，SHA-256
  `30db66c2…`）和 `camera_unit_feature_config.protobuf`（39,520 B，
  `b6905094…`）完全一致；
- `camera_unit_config` 语义 diff 只有本移植的 `hyper_lapse` 补丁和
  `usecase_info.sat_photo_case` 少两项 `capture_raw10_fullsize`；
  补回这两项后星空仍报 `captureAlgoTriggerMode nullptr`。

进一步从 201 `system_ext` 解出 stock
`libcsextimpl.so`（1,470,552 B，SHA-256 `6ed9e214…`）和
`libAPSClient-cmd-jni-extension.oplus.so`（1,099,512 B，
`91eb27cb…`）。把 201 stock `libcsextimpl.so` 放进数据应用 lib
目录后，相机可启动、`OplusSatBridge` 10017/10018 status=0，但星空
仍报 `captureAlgoTriggerMode nullptr`，未生成 JPEG；已移除该文件
恢复 OS4 扩展。201 APS extension 的复制被 SELinux 拒绝
（`Permission denied`），未能在进程内测试；其大小/哈希与设备版本
不同。

进一步测试 201 完整 system_ext APS 栈（csextimpl `6ed9e214…`、
APS extension `91eb27cb…`、APS client `b6669463…`）后，星空仍报
`captureAlgoTriggerMode nullptr`。再把 201 `/odm/lib64` 的
`libAlgoInterface.so`（`3ab2dc1b…`）/`libAlgoProcess.so`
（`da069a1a…`）bind mount 上去，`libAlgoProcess.so` 在 sphal
命名空间 dlopen 失败：
`library "android.hardware.graphics.common-V7-ndk.so" not found`，
相机在 `libAPSClient-cmd-jni` createClient 处 SIGSEGV；已回退到
1.5.6 正式模块。回退后普通拍照 `IMG20261031071156.jpg`
（2,566,927 B）`onApsJpegArrived`/`completeCapture success`/
`Picture Save End` 正常，设备锁屏。

结论：星空需要 201 完整 native 栈及其 `graphics.common-V7-ndk`
依赖，简单替换 201 库会崩溃；native 合并/补齐 V7 依赖是继续
方向，不是 ODM/JSON 节点能解决的。设备已恢复发布配置
（`camera_unit_config` SHA-256 `de4293c3…`）。该结论已在 13.16
通过 `/odm/lib64` overlay 补齐 V7 解决。

### 13.15 多景录像 IVideoService stub 实验（2026-10-31）

按计划尝试注册 Xiaomi vendor AIDL stub：

- 在 `system_ext_service_contexts` 补
  `vendor.xiaomi.hardware.videoservice.IVideoService/default u:object_r:hal_videoservice_service:s0`；
- 模块 sepolicy 增加
  `allow system_server hal_videoservice_service service_manager { add find }`
  和 `binder { call transfer }`；
- `VideoServiceStub` 用纯 `Binder` 实现 V12 事务码，去掉
  `markVintfStability`（否则报 `VINTF declaration error`），在
  system_server 注册；`service list` 出现
  `vendor.xiaomi.hardware.videoservice.IVideoService/default`。
- 相机 native media stack 实际调用：`loadFile(3)`、
  `registerListener(11)`、`reportCodecStatus(2)`、
  `reportCodecStatusV2(35)`、`clearCodecInfo(20)`、
  `releaseListener(12)`；stub 在 stop 时回调 listener 的
  `onStopFrameCapture(3)`/`onReleaseFrameCapture(4)`。
- 结果：多景仍生成 `.pending-...mp4`（780,224 B），只有
  `ftyp`/`mdat`、没有 `moov`，不可播放；默认 stub 的
  codec/resource 语义不足以让原生 muxer finalize。

已恢复 1.5.6 正式模块/Sense APK；普通拍照
`IMG20261031074042.jpg`（2,563,505 B）`onApsJpegArrived`/
`completeCapture success`/`Picture Save End` 正常，设备锁屏。

多景录像仍不可用。录制能开始并生成
`.pending-<ts>-VID....mp4`，但文件只有 `ftyp`/`mdat`、没有 `moov`，
是不可播放的裸流；停止时日志：

```text
E/om.oplus.camera: Failed to get interface:
vendor.xiaomi.hardware.videoservice.IVideoService/default
```

该服务是 Xiaomi 的 VPP/codec 资源管理 AIDL
（`canStartVideoCodec`、`clearCodecInfo`、`getRestCodecResources` 等），
当前移植的 vendor 没有注册该服务，原生 muxer 无法完成 finalize。
重命名 pending 文件并 `content insert` 只能让相册看到条目，MP4 仍无
`moov`、无法播放；不能作为修复。需要补齐该 vendor 服务。

全景仍需要实际平移手机，桌面平放条件下未完成。

### 13.16 星空修复：/odm/lib64 overlay 补齐 201 算法对 + V7（2026-10-31）

201 `libAlgoInterface.so`/`libAlgoProcess.so` 依赖的
`android.hardware.graphics.common-V7-ndk.so` 在设备 `/system/lib64`
存在（52,272 B，SHA-256 `a24365bb…`），但 sphal 命名空间不搜索
`/system/lib64`。单独 bind mount V7 到 `/odm/lib64` 失败，因为
`/odm` 是只读 erofs，目标文件不存在；改为在
`camera_overlay_system_libs` 中挂 `/odm/lib64` overlay：
lower=`/odm/lib64`，upper=tmpfs 中的 201 算法对 + V7，
chcon `u:object_r:same_process_hal_file:s0`。

重启后 `/odm/lib64` 三个库哈希为 `3ab2dc1b…`/`da069a1a…`/`a24365bb…`，
相机正常启动。星空快门参数出现：

```text
case_algo_name, ALGO_STARMODE
capture_mode, starry
capture_request_num, 15
```

15 帧长曝光堆栈约 4 分钟后 APS 回调 `onApsJpegArrived`：
`IMG20261031075008.jpg`，4,475,952 B，2304×4096，EXIF 07:50:08。
201 `libAlgoProcess` 的 ASD 节点仍报
`odm/lib64/libai_perception_scene_detect.so not found`；已用
`dump.erofs` 检查 201 ODM `/lib64` 全目录，确认该库不在 201 ODM，
设备 `/odm`、`/vendor`、`/system`、`/system_ext`、`/my_*` 也没有，
属于 201 vendor 侧依赖，当前只影响场景识别节点，不影响已验收功能。

1.5.7 模块把三个库打进 `camera/odm/lib64`，开机 overlay 建立后
重启复测：星空 `IMG20261031080804.jpg`，4,490,696 B，2304×4096，
EXIF 08:08:04；普通拍照 `IMG20261031080619.jpg` 2,560,505 B
2304×4096。201 算法对回归：3x `IMG20261031075932.jpg`、0.6x
`IMG20261031075950.jpg`（1836×3264，mRole=2）、6x
`IMG20261031080008.jpg`、专业 `IMG20261031080048.jpg`
（mCapMode=professional）、延时 `VID20261031080119.mp4`
（1,389,026 B，含 moov）、移轴 `IMG20261031080206.jpg`
（mCapMode=tiltShift）、超级文本 `IMG20261031080241.jpg`
（3,361,941 B，ALGO_OFFLINE_MFNR），全部正常。

多景录像仍受 IVideoService 真实 vendor 语义限制，pending MP4
无 moov；全景仍需实际平移手机。

### 13.17 多景录像：真实 Xiaomi vendor video service 移植与剩余 muxer 阻塞（2026-10-31）

从 haotian OS4.0.0.19 完整 OTA 的 vendor 分区提取到真实服务端：
`/bin/hw/vendor.xiaomi.hardware.videoservice-service`（AIDL V11）、
`vendor.xiaomi.hardware.videoservice-V11-ndk.so`、`libresourcemanager.so`、
`libcodecclientmanager.so`、`libvideocallframe.so`、`libvideoservice_utils.so`。
服务只依赖标准 libbinder/jsoncpp 和设备已有的 Qualcomm VPP，二进制可直接在
RMX5010 vendor 上运行。

VINTF 限制：设备 `/vendor/etc/vintf/manifest` 没有该 HAL，servicemanager
在开机时已缓存 manifest，post-fs-data 再挂 overlay 也来不及（报
`Could not find ... in the VINTF manifest`）。改为把服务注册到设备已声明、
未运行的 `vendor.qti.hardware.embmssl.IEmbms/default`：把 V11 NDK 中
**精确的 IVideoService descriptor**（后跟 NUL 的那一处，不能碰
`IVideoServiceListener` 前缀）替换为 eMBMS 名称，服务即可通过 VINTF 检查。
system_server 的 `ServiceManager.getService` 查不到这个 vendor 服务
（`getService`/`rawGetService` 均返回 null，root app_process 可查到），
因此用独立 `app_process` 代理（ksu 域）注册
`vendor.xiaomi.hardware.videoservice.IVideoService/default`，把事务
token 重写为 eMBMS 后转发给真实服务。

代理在 `releaseListener` 时先调用相机 listener 的
`onStopFrameCapture`（V12 AIDL code 4）和 `onReleaseFrameCapture`
（code 5），再延迟转发 release；相机侧 `VoipCapture: enter
onReleaseFrameCapture` 已收到回调。真实服务日志确认
`registerListener`、`reportCodecStatus`、`clearCodecInfo`、
`releaseListener`、`VPPManager clearCodecInfo` 全部执行。

但 `MPEG4Writer` 始终没有 `stop`/moov：编码器
`c2.qti.hevc.encoder` 的 VPP filter 在停止时报
`QC2Filter ... stop returned retval=1`、`FilterCore not available`，
`MediaCodec` 虽进入 RELEASING/UNINITIALIZED，muxer 的视频轨仍未收到
EOS，pending MP4 只有 ftyp/mdat。已尝试：
- `ro.vendor.media.video.vpp.support=false` + `persist.vendor.video.vpp.json.broken=false`；
- 补 haotian ODM 的 `videoCodecCapability.json`/`videobox.json`；
- hook MediaFormat 强制 `isOplusCamera=0`；
均未改变 QC2Filter 停止失败和 muxer 不 finalize。

结论：IVideoService 的真实语义已经补齐，多景仍不可用的剩余原因是
vendor codec2 的 VPP filter 停止/EOS 路径，不是视频服务本身。下一步需要
patch 相机 App 的 `RecordProcessor`/`VideoSaver` 在 encoder stop 后强制
muxer stop，或移植 haotian 的 codec2/VPP 栈。当前设备已恢复 1.5.7
正式模块/Sense APK。

### 13.18 多景 finalize 修复：Sense CameraMuxerHooks（2026-10-31）

根因：相机 RecordProcessor 的停止路径释放了 HEVC encoder，但 App 的
`MediaMuxer` 没有 stop；`MPEG4Writer` 只写出 ftyp/mdat，不写 moov，
所以文件停在 `.pending-...mp4`。真实 IVideoService 的移植（13.17）能让
服务处理 registerListener/reportCodecStatus/clearCodecInfo 并回调
listener，但没有改变 muxer 的停止路径。

修复在 Sense（LSPosed，作用域 com.oplus.camera）新增
`CameraMuxerHooks`：
- hook `android.media.MediaMuxer` / `MediaRecorder` 构造函数，记录相机
  进程创建的对象；
- hook `rj.e0.I(IZ)Z`（RecordProcessor 停止），返回后延迟 1.2s，对仍可
  stop 的 `MediaMuxer` 调用 `stop()`；MPEG4Writer 写 moov 并 fsync；
- 把最新的 `.pending-*VID*.mp4` 重命名为 `VID*.mp4`，再用
  `MediaScannerConnection.scanFile` 写入 MediaStore。
普通录像/延时使用 MediaRecorder 或已自行 stop，强制 stop 抛
`IllegalStateException` 被捕获，不改变原路径。

实机验证（1.5.7 模块 + 新 Sense release APK）：
- `VID20261031095159.mp4`，603,795 B，1080×1920 HEVC + AAC，
  moov 已写入，MediaStore duration 3019 ms；
- `VID20261031095717.mp4`，679,297 B，4092 ms；
- `VID20261031100029.mp4`，702,251 B，4033 ms；
- 三个文件均在相册可见并可播放；
- 普通录像 `VID20261031095408.mp4` 2,912,698 B、延时
  `VID20261031095635.mp4` 1,456,070 B 均正常，无回归。

新 Sense APK SHA-256 `aa2daad8…`；模块 1.5.7 保持不变。真实
IVideoService 移植保存在 `wip/multiview-videoservice` 分支，作为后续
可选增强。

### 13.19 长焦预览黑屏（SAT 切换）与 201 vendor HAL 实验（2026-10-31）

现象：普通照片模式下从 0.6x/1x 切到 3x，只有预览区域黑（UI/快门正常），
切回或从 2x/6x 切到 3x 基本干净。

日志特征：
- `ChiX camxmvgsatwrapper UpdatePixelShift() horizonalShift ... exceed limits 0`
- `OCAM_PreviewProcessor onPreviewCaptureResult, result is null`

统计：1x→3x 最差（单次切换约 22 次 null result），0.6x→3x 约 12 次，
2x/6x→3x 为 0。SAT（smooth zoom）切换时 mvg_sat 的 pixel shift 超出
限制，SAT wrapper 返回无效帧，预览 processor 收到 null。不是灭屏保护层
（“点击屏幕恢复显示”是另一个 overlay，已由 Sense CameraScreenOnHooks
用 Activity.onResume KEEP_SCREEN_ON + clearFlags 守卫处理）。

已排除/失败的路线：
1. 201 的 `libcamxoemsatwrapper.so` 与设备同哈希 `73431606…`，替换无意义；
2. `mvg_sat_config.json` 的 `align_strength_preview` 改为 `[0,0,0]`
   后 null 日志仍在（1x→3x 22 次、0.6x→3x 12 次）；
3. 把 preview 配置里的 `rear_sat` 换成 `rear_main` 可消除 null 日志，
   但 3x 预览变成主摄 FOV（指示器仍显示 3x），不可用；
4. 201 vendor camera HAL 整包 overlay（`vendor.qti.camera.provider-service_64`
   + CamX/CHI/qll/camera components，`/vendor/lib64` overlay + provider
   bind mount）：开机卡第一屏，`init.svc.vendor.camera-provider=restarting`，
   无法进入系统；移除模块后恢复。结论：201 vendor HAL 与 OS4 的
   cameraserver/init/vendor 依赖不兼容，不能靠简单 overlay 替换，后续若
   继续需要整 vendor 分区移植（高风险）。

相册与保屏（本次一并验证并进入 release APK）：
- `CameraGalleryHooks`：`yn.h1.a` 返回 `com.miui.gallery`，缩略图打开
  `com.miui.gallery/.activity.ExternalPhotoPageActivity`，已验证；
- `CameraScreenOnHooks`：相机 Activity onResume 加
  `FLAG_KEEP_SCREEN_ON`，并拦截 clearFlags 移除请求，70s 保持 Awake；
- `CameraMuxerHooks`：多景 finalize（见 13.18）。

当前设备状态：1.5.7 正式模块已重装，`/odm/lib64` 的
`libAlgoInterface.so`（`3ab2dc1b…`）、`libAlgoProcess.so`（`da069a1a…`）、
`graphics.common-V7-ndk.so`（`a24365bb…`）哈希正确，provider 运行；
普通照片冒烟 `IMG20261031123744.jpg`（6x 预览正常）。release Sense APK
SHA-256 `2188ec77…`（含 gallery/muxer/screen-on hooks）。屏幕已锁。
