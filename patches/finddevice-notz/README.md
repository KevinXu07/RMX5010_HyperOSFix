# patches/finddevice-notz — 查找设备改包修复（不依赖 LSPosed）

把已验证的 `FdNoTzFix` LSPosed 模块逻辑**直接打进 `MIUIFindDeviceCN.apk`**，让"查找设备"在没有
root / 没有 LSPosed 的机器上也能工作，从而通过开机引导（Provision）。

> 适用对象：**RMX5010 × nezha OS4**（本仓库主线底包）。目标 APK 身份必须匹配：
> `com.xiaomi.finddevice`，versionCode `201575`（20.15.75），
> 原始 APK SHA-256 `c110e03f6b613362475ca35f39076a5a14057a8cb8e0a2c906b1e3a6bc69eb57`。
> 换 finddevice 版本后，混淆名与字段可能变化，需重新按本文件"定位方法"一节核对。

## 为什么需要它

Realme 的 QTEE 拒绝小米 cardapp trustlet → TZ 凭证不可用。finddevice 的 TZ 凭证面
（`DeviceCredentialTZ`）会去调 TZ 服务并失败，`gf.s0.a()` 抛 `empty TZ id`；
`FindDeviceStatusManagerInternal` 因此阻塞，Provision 向导在"协议与声明 → 同意并继续"处 ANR 退回首页。
（根因链见 [docs/历史验证记录_OS3小米账号.md](../../docs/历史验证记录_OS3小米账号.md) 与
[docs/小米账号MTD依赖_修复方案.md](../../docs/小米账号MTD依赖_修复方案.md)）

模块方案（LSPosed hook）已验证可用，但需要 root；本机型当前包没有 root 通道，于是改为改包。

## 补丁内容（策略 A：保持 `dx.i.e()==TZ`）

| 位置 | 改动 | 作用 |
|---|---|---|
| `classes.dex` → `gf/s0.a()` | 直接 `return ""` | 不再调用拒绝服务的小米 TZ 服务，消除 `empty TZ id` |
| `classes3.dex` → `DeviceCredentialTZ.getFId/getHost/getOwnUserId/sign` | 取 `Application.r()` 作 Context，`new DeviceCredentialManagerNoTZ(ctx).get(ctx)` 后**按接口委托同名方法**（无 Context 时回退原实现） | 用真实可用的 NoTZ 凭证提供 fid/签名 |
| `classes3.dex` → `DeviceCredentialTZ.isProvisioned()` | 有 NoTZ 凭证时返回 `true` | 让调用方认为凭证就绪 |
| `classes3.dex` → `DeviceCredentialTZ.provision(...)` | 无条件 `return false` | 不再驱动不可用的 TZ 预置流程（与模块行为一致） |
| 镜像 `etc/permissions/privapp-permissions-rmx5010-finddevice-resign.xml` | 新增白名单 32 条 | 见下节 |
| 镜像 `priv-app/MIUIFindDeviceCN/oat/**` | 删除 | 重签后旧预编译产物失效 |

**`dx.i.e()` 故意不动**：小爱真机校验的门槛要求 `e()==TZ`（策略 B 改 NONE 需要额外补门槛，且未实机验证）。
模块源码（对照来源）在工作区 `os4/work_aiasst/xposed_fdnotz/`。

## 重签的连锁影响（已离线核对，结论见下）

本仓库配套的 RMX5010 镜像 `ro.control_privapp_permissions=enforce`，因此"重签导致纯签名授权失效"
这件事必须按特权权限白名单补回来，否则会在启动时报特权权限未白名单并抛异常。

| 项 | 核对结果 | 处理 |
|---|---|---|
| `sharedUserId=android.uid.finddevice` | 仅 finddevice 使用 | 无影响 |
| finddevice 请求的**平台**特权权限 | 原厂白名单已覆盖 14 项（product 15 + system_ext 16 条目合集） | 无需处理 |
| finddevice 请求的 **MIUI 私有**特权权限（`miui.cloud.finddevice.*`、`com.xiaomi.permission.*` 等） | **19 项缺口** | 已在白名单补齐（走特权路径授予，功能不丢） |
| 别包请求、finddevice 声明的特权权限 | 10 个特权消费包共 13 对 | 已补齐（含 `com.android.settings` / `com.miui.securitycenter` / `com.miui.voiceassist`） |
| **纯 signature** 权限（无法白名单） | finddevice 5 项：`BROADCAST_SMS`、`NETWORK_SETTINGS`、`REMOVE_ACCOUNT_AUTHENTICATOR`、`ACTIVATE_SIM`、`BIND_MITRUE_DEVICE_SERVICE`；`com.miui.cloudservice` 2 项 | **接受损失**（不影响账号/激活链路） |
| 非特权消费方（16 个 `product/app` 应用） | 无法白名单 | **接受损失** |
| 运行时自校验签名 | 未发现 | 实机确认 |

## 定位方法（换版本时如何重找）

1. `baksmali` 全部 dex（注意：**baksmali 2.2.0 不支持 dex 039**，需 2.5.2+）
2. `gf/s0.smali`：含字符串 `empty TZ id`，`a()` 方法里比较 `Ldx/i$d;->TZ`
3. `com/xiaomi/finddevice/v2/DeviceCredentialTZ.smali`：6 个方法 `getFId/getHost/getOwnUserId/isProvisioned/provision/sign`
4. Context 来源：`com/xiaomi/finddevice/Application;->r()`（静态返回 Application，本身是 Context）
5. 委托目标：`com/xiaomi/finddevice/v2/IDeviceCredential` 接口（`getFId/getHost/getOwnUserId/sign`），
   实现类是 `DeviceCredentialManagerNoTZ$DeviceCredentialNoTZ`
6. 白名单计算：`scripts/patch_finddevice_apk.sh --report-perms`（用 aapt 扫全镜像的权限图）

## 应用步骤

```bash
# 1) 从你自己的镜像里取出目标 APK
python3 - <<'PY'   # 或 erofsfuse 挂载 product.img 后直接 cp
...  # 见 ../../scripts/mount_erofs.sh
PY
# 2) 打补丁 + 重签（需要 java + smali/baksmali 2.5.2 fat jar + apksigner + zipalign）
scripts/patch_finddevice_apk.sh \
  --apk  <原版 MIUIFindDeviceCN.apk> \
  --smali-dir smali/ \
  --keystore <你的 keystore.jks> --ks-pass <pass> \
  --out  out/MIUIFindDeviceCN.patched.apk
# 3) 放回镜像：替换 product/priv-app/MIUIFindDeviceCN/ 下的 APK，删除 oat/，
#    把 etc/*.xml 放进 product/etc/permissions/，然后按规范重建 product.img
```

**刷写注意**：签名变了 → 必须清 userdata（`fastboot -w`），否则 PackageManager 会因签名不匹配
忽略新 APK。详见 [docs/SELinux闭包与EROFS重建规范.md](../../docs/SELinux闭包与EROFS重建规范.md) 与包内 README。

## 离线验证（2026-10-16，实测通过）

| 项 | 结果 |
|---|---|
| APK 签名 | `apksigner verify` 通过（v3；专用密钥，密钥不入库） |
| 对齐 | `zipalign -c -p 4` 通过；25 个 STORED 原生库字节未变 |
| dex 往返 | 重编译后反编译对比：除 2 个补丁文件外，仅剩"静态字段默认值省略"的序列化差异（语义等价） |
| 非 dex 条目 | 与原 APK **逐字节一致**（3959 条目，仅 2 个 dex 被替换） |
| 镜像差分 | product.img 相对基线：+1 XML、-oat×2、~APK×1；其余常规文件/符号链接/目录元数据全部一致 |
| 包校验 | `verify_package.ps1 -Strict` 54/54 |
| 实机验证 | **待做**（见下方清单） |

实机清单：

```bash
adb shell 'dumpsys package com.xiaomi.finddevice | grep -A2 signatures'   # 应为我们的证书
adb shell 'logcat -d | grep -iE "empty TZ id|mipccAttestation|finddevice"' | tail -50
# 走一遍引导：协议与声明 → 同意并继续，应进入下一步；设置 → 查找设备 应可用
```


## 实机回归（2026-10-16）：闪退根因与修法（seapp_contexts，免重签）

首版改包（重签）刷入后，finddevice **一启动就闪退**，抓到的现场：

```
Abort message: JNI FatalError called: (com.xiaomi.finddevice)
  ... selinux_android_setcontext(..., "default:privapp:targetSdkVersion=36:partition=product:complete",
  "com.xiaomi.finddevice") failed
```

**根因**：`/system_ext/etc/selinux/system_ext_seapp_contexts` 里有 MIUI 给 finddevice 专设的规则：

```
user=system_finddevice minTargetSdkVersion=37 seinfo=platform domain=platform_app  type=app_data_file levelFrom=user
user=system_finddevice seinfo=platform                domain=platform_app_36 type=app_data_file levelFrom=user
```

finddevice 用的是**专属 Android 用户 `system_finddevice`**，而它的 seapp 规则**强制 `seinfo=platform`**。
重签后 seinfo 降为 `default` → 没有任何规则匹配 → **zygote 特化阶段 setcontext 失败 → SIGABRT**
（进程还没跑任何应用代码就被杀，所以表现为"一打开就闪退"）。

**修法（保留重签，不需要清数据）**：给 `seinfo=default` 补两条**同域**规则
（`product/etc/selinux/product_seapp_contexts`）：

```
user=system_finddevice minTargetSdkVersion=37 seinfo=default domain=platform_app  type=app_data_file levelFrom=user
user=system_finddevice seinfo=default                domain=platform_app_36 type=app_data_file levelFrom=user
```

域的解析结果与原版**完全一致**（platform_app / platform_app_36、app_data_file、levelFrom=user），
只是把匹配键从 `platform` 换成 `default`。

### 另一条路（未采用）：保留原签名块

理论上可以让 seinfo 保持 `platform`（把 dex 打进原 APK、保留原签名块，和 TeleService 同法），
但实机证明：**`/vendor` 分区不接受失效摘要**（CneApp 用同法被 PMS 丢弃：`Unable to find package`），
而 `/system` 可以（TeleService 正常加载、电话进程在跑）。finddevice 在 `/product`，是否接受未验证；
且切换会改变证书、需要再清一次数据。因此本轮采用 seapp 规则方案。

## 实机回归（2026-10-16）：第二层闪退 = hidden-API 拦截（product sysconfig 白名单）

seapp 修好后 zygote 特化不再 abort，但 finddevice 仍然在跑起来之后崩，这次是 **Java 异常**：

```
java.lang.NoSuchMethodError: No static method getBoolean(Landroid/content/ContentResolver;
Ljava/lang/String;)Z in class Lmiui/settings/MiuiSettings$Global;
... declaration of 'getBoolean(ContentResolver,String)' appears in /system/framework/framework.jar
```

**关键点：这个方法并没有丢。** `NoSuchMethodError` 在这里是 ART 对 **hidden API 黑名单**的
报错文案，不是"类里真没有这个方法"。四条独立证据：

| # | 证据 | 结论 |
|---|---|---|
| 1 | 同一 `framework.jar` 里 `MiuiSettings$Global.smali` 第 207 行就是该 `<deep_public>`-less 黑名单成员 | 方法存在，字节一致 |
| 2 | `dumpsys package`：平台签名应用 `hiddenApiEnforcementPolicy=0`，重签后的 finddevice `=2` | 策略被提升为 enforce |
| 3 | logcat：`hiddenapi: ... using linking: deemed denied` | ART 确实在拦 |
| 4 | `settings put global hidden_api_policy 0` 后应用能起、不再崩 | 拦的就是 hidden API |

**根因**：重签丢掉了 **platform 证书** → PackageManager 不再把它当平台签名 →
`ApplicationInfo.hiddenApiEnforcementPolicy` 由平台应用的 `0`（关闭）变成 `2`（强制）。

**修法（免重签、免 root、免清数据）**：把包名挂进 **product 分区的 hidden-API 白名单**。
`SystemConfig.readHiddenApiWhitelistedApp` 接受 `<hidden-api-whitelisted-app package="..."/>`，
而 product 目录以 `flags=-1` 读入（`allowApiWhitelisting=true`），于是置上
`appInfoPrivateFlagsExt` 的 `0x10`（`PRIVATE_FLAG_IS_HIDDEN_API_WHITELISTED`），
`hiddenApiEnforcementPolicy` 被强制回 `0`。

本机自带的 `downloads`/`mtp` 包同样是**非平台证书却按 policy 0 运行**，走的正是这条路径，
可作机制旁证。

载荷（已入库）：[`etc/sysconfig/rmx5010-hiddenapi-package-whitelist.xml`](etc/sysconfig/rmx5010-hiddenapi-package-whitelist.xml)，
落到镜像 `product/etc/sysconfig/rmx5010-hiddenapi-package-whitelist.xml`。

> 诊断期间临时设过 `settings put global hidden_api_policy 0`，已用
> `settings delete global hidden_api_policy` 复原（现为 null）。

**构建与验证**：从已挂载基线 rsync → `mkfs.erofs -zlz4hc -C262144 -b4096 -T0 --mount-point=/product`
+ 由基线 xattr 生成 file-contexts 重建 product.img。`fsck.erofs` 干净；`simg2img` 往返字节一致；
**全镜像 2477 个 inode 标签扫描 0 处 double-wrap / 0 处错标**；属主与权限保留；新 XML 标签
`u:object_r:system_file:s0`。相对基线内容差 = **恰好 +1 文件**（即该 XML）；build.prop /
MIUIFindDeviceCN.apk / DevicesAndroidOverlay.apk / product_seapp_contexts / 亮度 display XML 全部字节一致。

**刷写**：仅 product，**无需清数据**（签名未变）：
`fastboot -S 128M flash product_a images\product.img`。
