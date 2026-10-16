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
