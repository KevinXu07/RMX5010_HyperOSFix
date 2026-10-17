# 相机全套成像与多摄落盘闭包修复方案（RMX5010 HyperOS4 nezha 主线）

## 1. 根因剖析与架构策略

在 Realme GT7 Pro（RMX5010，骁龙 8 至尊版 SM8750 底包）上移植小米 HyperOS4（基于 Redmi nezha OS4.0.2.0.XPACNXM，Android 15 / SDK 35）时，原装小米相机（`MiuiCamera`，`com.android.camera`）存在架构级失配：

- **MiuiCamera 拍照超时不落盘**：小米相机通过标准 Camera2 API 能够正常获取预览流，但在执行主快门拍照时，强制依赖小米专有的 MIVI / MiAlgo 后台图像处理管线与厂商专有元数据（如 `pApsSensorMode`、小米 Remosaic 与 `video.rectify.flag`）。高通 Oplus Camera Provider HAL（`ChiX`）缺失这套私有 Vendor Tags，导致底层无法返回全尺寸图像缓冲，相机会在挂起 12 秒后抛出 `Oops, capture timeout later release timeout!`，照片无法保存到磁盘。
- **全功能相机解决方案（OplusCamera）**：采用已在 RMX5010 深度适配并经过 4096 字节页对齐、移除 MediaStore 私有列 `_camera_quick_uri` 的欧加定制相机（`com.oplus.camera`），作为系统级特权应用置入 `/product/priv-app/OplusCamera/`。该相机直接与底层 `vendor.qti.camera.provider-service_64` 和 `ChiX` 通信，完美驱动欧加定制的三摄硬件（IMX906 主摄、LYT-600 潜望长焦、超广角与 16MP 前摄）。

---

## 2. 七个关键技术坑与闭环修法

1. **P010 厂商格式崩溃（`libnativewindow.so`）**：
   - 载体：`/system/lib64/libnativewindow.so`
   - 根因：欧加相机 HAL 传输 10-bit raw 厂商私有格式 `0x7fa30c0a` 时进入 `lockAsyncYCbCr`，原版小米动态库缺少此分支导致跨步步幅计算越界触发 SIGSEGV。
   - 修法：在 `0xac78` 植入跳转代码蹦床（Trampoline），扩展识别厂商格式 `0x7fa30c0a`（SHA-256 `1dc76b92d7bdfdf9162841f6b51feb0d7b21b692be3b4297411fbc4698faf9d3`）。

2. **拍照不落盘（MediaStore 私有列 `_camera_quick_uri`）**：
   - 载体：`OplusCamera_fullsave_pagealigned.apk`
   - 根因：OplusCamera 原始保存路径向 Android MediaStore 写入私有列 `_camera_quick_uri`，Android 15 原生 MediaProvider 抛出 `IllegalArgumentException: Invalid column _camera_quick_uri` 并清除 pending 项。
   - 修法：smali 补丁抹除 `xi/q.smali` 中对 `_camera_quick_uri` 的读写与查询依赖，并在 `ii/l$b.c` 中保证缺列时不提前 return。

3. **第三方应用闪退与安装失败（fake camera jar 污染）**：
   - 载体：`odm.img`
   - 根因：原 odm 分区混入假冒 Kotlin 相机扩展库 `/odm/framework/androidx.camera.extensions.impl.fake.jar` 与 `/odm/etc/permissions/fake_camera_extensions.xml`，劫持了第三方应用的 classpath。
   - 修法：在重构 odm 分区时彻底剔除该 jar 与声明，净化第三方应用运行时环境。

4. **相机黑屏无流（ODM 16 路拓扑冲突）**：
   - 载体：`/odm/etc/camera/config/camera_unit_config`
   - 根因：合包时若采用旧 16 路配置，包含两路 `capture_raw10_fullsize`，导致 CameraService 抛出 `CS_STREAM_CREATE_FAIL` / `UNCONFIGURED` 引起黑屏。
   - 修法：刷入验证通过的 14 路 `camera_unit_config`（SHA-256 `c2fc5ae64eea41016b50cb46f0a0d4e7172f99785b03e57911100acc0b1c23c1`），移除两项全尺寸 raw10 冲突流。

5. **动态库加载异常（4096 字节页对齐）**：
   - 载体：`OplusCamera.apk`
   - 根因：Android 15 / 16 KiB 页面要求 APK 内 `STORED` native 库按 4096 字节对齐，否则运行时 mmap 报 `dlopen failed`。
   - 修法：执行 `zipalign -p -f 4` 对齐全量 native 动态库并采用 v3 方案重新签名。

6. **特权权限缺失异常（`SUBSCRIBE_TO_KEYGUARD_LOCKED_STATE`）**：
   - 载体：`/product/etc/permissions/privapp-permissions-com.oplus.camera.xml`
   - 根因：普通应用无法获取 `signature|privileged|role` 级别权限，启动即抛出 `SecurityException: Permission android.permission.SUBSCRIBE_TO_KEYGUARD_LOCKED_STATE permission required` 致命崩溃。
   - 修法：将 OplusCamera 作为系统级应用置入 `/product/priv-app/OplusCamera/`，并通过 privapp-permissions 白名单授权。

7. **SELinux 访问阻断（`opluscamera_app` 专用域闭环）**：
   - 载体：`product_seapp_contexts` + `product_sepolicy.cil`
   - 根因：OplusCamera 需要与底层相机 HAL、ORMS 调度和私有数据目录通信，通用 priv_app 域存在 AVC 拦截。
   - 修法：
     - `product_seapp_contexts`:
       ```text
       user=_app isPrivApp=true name=com.oplus.camera domain=opluscamera_app type=privapp_data_file levelFrom=user
       ```
     - `product_sepolicy.cil`:
       ```cil
       ;; RMX5010 OplusCamera dedicated domain and retained HAL/data access.
       (typeattributeset domain (opluscamera_app))
       (typeattributeset appdomain (opluscamera_app))
       (typeattributeset priv_app_all (opluscamera_app))
       (typeattributeset opluscamera_app_202404 (opluscamera_app))
       (typetransition opluscamera_app tmpfs file appdomain_tmpfs)
       (allow opluscamera_app appdomain_tmpfs (file (read write getattr map execute)))
       (allow opluscamera_app appdomain (memfd_file (read write getattr map execute)))
       (typeattributeset halclientdomain (opluscamera_app))
       (typeattributeset hal_camera_client (opluscamera_app))
       (typeattributeset hal_graphics_allocator_client (opluscamera_app))
       (allow opluscamera_app vendor_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
       (allow opluscamera_app vendor_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
       (allow opluscamera_app app_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
       (allow opluscamera_app app_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
       (allow opluscamera_app privapp_data_file (dir (ioctl read write create getattr setattr lock rename open watch watch_reads add_name remove_name reparent search rmdir)))
       (allow opluscamera_app privapp_data_file (file (ioctl read write create getattr setattr lock append map unlink rename open watch watch_reads)))
       (allow opluscamera_app privapp_data_file (lnk_file (read getattr open)))
       ```
     - 搭配极简占位包 `/product/priv-app/MiuiCameraProvider/`，提供小米相册所依赖的 `SpecialTypesProvider`，完美替换原有冲突的 MiuiCamera。

---

## 3. 实机验证结果（设备序列号：`acbefdc7`）

1. **SELinux 状态**：`Enforcing`（全程强制安全模式，无宽容运行）。
2. **后置主摄拍照（Sony IMX906）**：
   - 成片路径：`/sdcard/DCIM/Camera/IMG20261018062719.jpg`
   - 文件大小：`1,720,946 bytes (1.72 MB)`
   - 图像分辨率：`3072 x 4096 (12.5 MP 四合一全尺寸像素)`
   - EXIF 标识：`Make: Xiaomi, Model: RMX5010, DateTime: 2026:10:18 06:27:19`
3. **前置自拍拍照（1600万像素高清前摄）**：
   - 成片路径：`/sdcard/DCIM/Camera/IMG20261018062858.jpg`
   - 文件大小：`3,959,813 bytes (3.96 MB)`
   - 图像分辨率：`3456 x 4608 (15.93 MP 硬件原生满血分辨率)`
   - EXIF 标识：`Make: Xiaomi, Model: RMX5010, DateTime: 2026:10:18 06:28:58`
4. **后置 3x 潜望长焦拍照（Sony LYT-600）**：
   - 成片路径：`/sdcard/DCIM/Camera/IMG20261018062941.jpg`
   - 文件大小：`1,758,162 bytes (1.76 MB)`
   - 图像分辨率：`3072 x 4096 (12.5 MP 潜望光学变焦四合一)`
   - 测光与夜景：支持长曝光合成，离开前台即时完成后台 deferred 增强并成功落盘。
5. **镜头切换与稳定性**：
   - 支持前后摄瞬间切换（`CONNECT device 0` <-> `CONNECT device 1` 无缝交接）。
   - 0.6x 超广角、1x 主摄、3x 潜望长焦变焦平滑稳定，无崩溃闪退。
