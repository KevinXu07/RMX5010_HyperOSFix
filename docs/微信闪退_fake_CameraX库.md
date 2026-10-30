# 微信闪退：ODM fake CameraX 库

日期：2026-10-28
载体：KSU 模块 `rmx5010_fod_bridge` 1.3.9（`wechat_fix.sh`）

## 根因

ODM 镜像里有：

```text
/odm/framework/androidx.camera.extensions.impl.fake.jar   2371022 bytes
/odm/etc/permissions/fake_camera_extensions.xml          197 bytes
```

XML 把该 jar 注册为共享库 `androidx.camera.extensions.impl`。微信的 manifest
带 optional `uses-library`，启动时会加载这个 jar；jar 里的旧 Kotlin/AndroidX
类型与微信 APK 混淆后的类型冲突，崩溃堆栈为：

```text
NoSuchMethodError: No interface method getContext()Loa6/l;
in class Lkotlin/coroutines/Continuation;
... /odm/framework/androidx.camera.extensions.impl.fake.jar
```

OS4 交接文档 12.16 的 clean ODM v2 删除这两个文件后，微信进入欢迎/登录页，
用户确认能打开。当前 HyperOS 4.0.0.19 的 `/odm` 仍是同版本 fake jar，且为只读
EROFS，不能直接 `rm`。

## 修复

`wechat_fix.sh` 在 `post-fs-data`（PackageManager 扫描 `/odm` 之前）把一份最小的

```xml
<permissions/>
```

bind mount 到 `/odm/etc/permissions/fake_camera_extensions.xml`。共享库不再注册，
微信的 optional `uses-library` 不会加载 fake jar；jar 本身留在只读 ODM 上但不被
使用，不需要重刷 ODM 或改分区。

日志：

```text
wechat: fake camera library declaration hidden
wechat camera fix: 0
```

重启后验证：

```text
cat /odm/etc/permissions/fake_camera_extensions.xml
  <permissions/>

cmd package list libraries | grep camera
  library:camerax-vendor-extensions.jar
  library:com.xiaomi.hardware.camera.companion-V1
  library:miui-cameraopt
  # androidx.camera.extensions.impl 不再出现
```

当前设备没有安装 `com.tencent.mm`，所以本轮只验证到“库不再注册”；安装微信后
应不再加载 fake jar。若某个 ROM 版本把 jar 通过别的 XML 再次注册，再把 jar
本身 bind mount 成空 jar 即可。

## 回退

删除模块或移除 `post-fs-data.sh` 中的 `ensure_wechat_camera_fix` 调用，重启后
恢复原 XML。不要为了回退而修改 `/odm` 分区。

## 注意

- 只屏蔽声明，不删除 jar；原 ODM 的相机算法载荷未动。
- 微信数据、登录态、APK 均未修改。
- OS4 文档里的“删一个文件”实际对应两个对象：jar 和注册它的 XML；这里用最小的
  单文件声明屏蔽达到同样效果，jar 不需要动。
