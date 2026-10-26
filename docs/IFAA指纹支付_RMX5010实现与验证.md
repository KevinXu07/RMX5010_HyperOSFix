# IFAA / 支付宝指纹支付：RMX5010 实现与验证

状态（2026-10-26）：

- 本地链路、IFAA Binder 事务、Oplus `IFingerprintPay` HAL 转发、真实支付宝
  登录页发出的 `processCmd` 均已实测通过。
- **最终“指纹支付”扣款流程尚未验证**：设备当前已录入指纹数为 0，且支付宝在这台
  机器上要求“新设备登录身份验证”（短信/密码），只能由用户本人完成。
- 型号默认 `ONEPLUS-R23821`（与 Oplus HAL 匹配），可通过
  `settings put global op13_fix_ifaa_model <型号>` 覆盖。

## 1. 设备事实

```text
IFAA 包：/product/app/IFAAService/IFAAService.apk
package：org.ifaa.aidl.manager   targetSdk 35   21 KB
service：org.ifaa.aidl.manager.IfaaService
action ：org.ifaa.aidl.manager.IfaaManagerService
exported=true，未声明任何权限
```

haotian OS4 的 IFAA APK 是瘦 Binder 桩，不是 OS3 小米的完整实现。smali 的
packed-switch 确认事务号：

| 事务 | 方法 | 原始行为 |
|---|---|---|
| 1 | `getSupportBIOTypes` | 由 `ifaaProp`/`fpVendor` 计算 |
| 3 | `getDeviceModel` | `"Xiaomi-" + Build.DEVICE` → `Xiaomi-haotian` |
| 4 | `processCmd` | 转发给小米 `IMlipayService` |
| 9 | `getIDList` | 指纹 ID 列表 |

Oplus 支付 HAL：

```text
service    : vendor.oplus.hardware.biometrics.fingerprintpay.IFingerprintPay/default
descriptor : vendor.oplus.hardware.biometrics.fingerprintpay.IFingerprintPay
进程        : vendor.oplus.hardware.biometrics.fingerprintpay@1.0-service
域          : u:r:hal_fingerprintpay_oplus:s0
```

事务码 6 由反汇编 `BpFingerprintPay::ifaa_invoke_command` 交叉确认：

```asm
93c8: 528000c1  mov w1, #0x6
93d0: 94000a64  bl AIBinder_transact@plt
```

所以模块中的 `OPLUS_TRANSACTION_INVOKE_COMMAND = 6` 不是猜的。

## 2. 模块实现

作用域必须同时包含 `system`（system_server）和 `org.ifaa.aidl.manager`。

### 2.1 IFAA 进程（`IfaaHooks`）

- Hook `IfaaService.onBind`，保留 Service Context，对返回的 Binder 安装
  `onTransact` 钩子。
- 事务 1：返回 `IFAA_FINGERPRINT | IFAA_FOD = 1 | 16 = 17`。
- 事务 3：返回可配置型号，默认 `ONEPLUS-R23821`。
- 事务 4：把字节数组原样转发到 Oplus HAL 事务 6；HAL 异常时回退原服务。
  AIDL 老接口是 `inout`，因此回复写 `response` 后再写回 `request`。
- 事务 9：`authType == 1` 时读取
  `FingerprintManager.getEnrolledFingerprints()` 并返回 ID；失败回退原服务。
- 首次安装时通过 `ServiceManager.getService()` 做一次 HAL 探测
  （AIDL `getInterfaceVersion`，事务 `0x00FFFFFF`），日志确认 descriptor 和
  SELinux 放行。

### 2.2 system_server（`SystemServerHooks`）

IFAA APK 没有任何 `<uses-permission>`。Android 17 的
`FingerprintService.canUseFingerprint(...)` 会校验 `USE_FINGERPRINT` /
`USE_BIOMETRIC` / AppOps，直接调用会被拒绝。

模块只对以下条件返回 `true`：

- 调用包严格等于 `org.ifaa.aidl.manager`；
- 当前 Binder 调用 UID 确实拥有该包。

其他应用、其他人脸/指纹调用保持系统原逻辑。日志：

```text
IFAA fingerprint permission hooks=1
IFAA fingerprint enrollment access granted for uid=10165
```

### 2.3 SELinux

Android 17 平台的 `seapp_contexts`：

```text
user=_app minTargetSdkVersion=37 seinfo=platform domain=platform_app
user=_app                   seinfo=platform domain=platform_app_36
```

IFAA 的实际进程域是 `platform_app_36`（不是 targetSdk 35 推导出的
`platform_app_35`）。`ksud sepolicy patch` 的规则：

```text
typeattribute platform_app_36 hal_fingerprintpay_client
```

`service.sh` 不再写死域名：

1. IFAA 进程已启动时，从 `ps -AZ` 读取真实域；
2. 未启动时，按 `targetSdk` 与 `ro.build.version.sdk` 计算
   （`targetSdk >= sdk` → `platform_app`，否则 `platform_app_<sdk-1>`）；
3. 只允许 `platform_app[_数字]` / `system_app[_数字]`；
4. 已有补丁标记放在 `/dev/ifaa_policy_domains`（tmpfs，重启自动清空）；
5. 开机先打一次，之后每 30 秒在 IFAA 进程首次出现时补一次。

实测开机日志：

```text
ifaa policy patched: typeattribute platform_app_36 hal_fingerprintpay_client
```

### 2.4 一个必须记录的回归：service.sh 的 CRLF

用 Windows Python 直接改写 `service.sh` 时写入了 CRLF，shebang 变成
`#!/system/bin/sh\r`，KSU 启动时直接不执行，导致：

- `rmx5010_fod_bridge.ko` 没有 insmod；
- LPWG 手势没有使能；
- IFAA SELinux 补丁没有应用；
- `boot.log` 停留在上一次开机。

已改为 LF 并重启验证。**所有推送到设备的 shell 脚本必须保持 LF**：

```bash
python - <<'PY'
from pathlib import Path
p = Path("service.sh")
s = p.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
p.write_text(s, encoding="utf-8", newline="\n")
PY
```

## 3. 探针与实测结果

`app_process` 不是已安装应用，AMS 无法为它找到调用包，`bindService` 会抛：

```text
SecurityException: Unable to find app for caller ... when binding service
Intent { act=org.ifaa.aidl.manager.IfaaManagerService pkg=org.ifaa.aidl.manager }
```

因此改用最小 APK（`tools/ifaaprobe`）安装后 bind。探针结果：

```text
bindService returned true
T1 getSupportBIOTypes=17
T3 getDeviceModel=ONEPLUS-R23821
T9 getIDList(authType=1)=[]
T9 getIDList(authType=16)=null
T4 processCmd(empty)=[-1,-1,-1,-1,-1,-1,-1,-1]
```

解释：

- `T1=17`：指纹 + FOD，正确。
- `T3`：模块已生效。
- `T9=[]`：`dumpsys fingerprint` 当前 `count=0`，`/data/system/users/0/fpdata`
  不存在，确实没有已录入指纹，不是 hook 失败；`readEnrolledFingerprintIds`
  返回空数组。录入指纹后应返回实际 ID。
- `T4` 空命令返回 8 字节 `0xFF`，说明已经到达 Oplus HAL；没有异常、没有
  `avc denied`，HAL 进程未重启。
- HAL 探测日志：
  `IFAA Oplus HAL access ok descriptor=vendor.oplus.hardware.biometrics.fingerprintpay.IFingerprintPay version=0`
  （`version=0` 是 HAL 未覆盖 `getInterfaceVersion` 的默认返回值，不影响
  事务 6）。

真实业务流量（打开支付宝登录页时，由支付宝自己发起）：

```text
IFAA processCmd req=0100000014000000840f...636f6d2e65672e616e64726f69642e41...(169B)
               resp=00000000820000000210f7dc... (138B)
IFAA processCmd req=0100000014000000840f...636f6d2e65672e616e64726f69642e41...(63B)
               resp=00000000300000000400010006000100... (56B)
```

两条请求都包含 `com.eg.android.AlipayGphone` 包名，回复状态为 0 且带有效
payload，证明“支付宝 → IFAA 桩 → Oplus HAL” 全链路已经通。

## 4. 剩余验证（需要用户本人）

1. **录入指纹**：设置 → 指纹、面部与密码 → 指纹。当前为 0 枚。
2. **登录支付宝**：这台机器被识别为新设备，要求短信/密码验证，无法由
   ADB 代做。
3. 支付宝 → 我的 → 设置 → 支付设置 → 生物支付 → 指纹支付，打开并完成一次
   真实支付；同时观察：

```bash
adb logcat -s LSPosedFramework:* | grep -E 'IFAA|processCmd'
```

预期看到 `IFAA processCmd req=... resp=...`，无
`IFAA Oplus command failed, using original service`。

如果支付宝提示型号/设备不匹配，尝试：

```bash
adb shell settings put global op13_fix_ifaa_model REALME-RMX5010
adb shell am force-stop org.ifaa.aidl.manager
```

（默认 `ONEPLUS-R23821` 已能让 HAL 正常处理支付宝的登录期命令，优先保留。）

## 5. 复现

```bash
# 构建模块
cd lsposed-src && bash build_apk.sh

# 探针
cd tools/ifaaprobe && bash build.sh
adb install -r ifaaprobe.apk
adb shell am start -W -n local.mio.ifaaprobe/.ProbeActivity
adb shell su -c 'cat /sdcard/Android/data/local.mio.ifaaprobe/files/probe.txt'
```

LSPosed 作用域：

```text
system (android)
com.android.systemui
com.xiaomi.finddevice
org.ifaa.aidl.manager
com.android.bluetooth
```

## 6. 结论

IFAA 指纹支付的**本地技术闭环**已经完成：权限、事务号、型号、支持类型、
HAL 转发、SELinux 全部实测。剩下的是账号与指纹录入这类用户侧动作，以及
最后一步真实扣款；在完成之前不应宣称“支付宝指纹支付已完全修复”。
