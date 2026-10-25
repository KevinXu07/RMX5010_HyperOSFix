# 屏下超声波指纹与 FOD 物理坐标（Ultrasonic In-Display Fingerprint & Accurate FOD Fix）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的原生屏下超声波指纹（FOD）闭包方案。
**全 ROM 镜像级原生内置，100% 免 Root、免 Magisk、免 LSPosed 模块。**

---

## 症状与现象

1. **设置无指纹入口**：系统「设置 -> 密码与安全」中缺少「指纹解锁」选项，框架层检测不到 `android.hardware.fingerprint` 硬件特性。
2. **指纹服务未加载**：`dumpsys fingerprint` 提示 `Can't find service: fingerprint`，BiometricService 无法枚举到任何指纹传感器。
3. **触控与光圈坐标错位**：如果误套用一加 13（OP13，PJZ110）的 2K 屏坐标，指纹提示图标与触控判定区相对物理超声波传感器向右偏 88px、向下偏 358px，导致无法对准传感器录入与识别。
4. **录入秒弹失败（"提示添加指纹失败"）**：走完「设置 → 指纹 → 输 PIN → 录入指纹」流程后，按下手指瞬间报 HW_UNAVAILABLE。HAL logcat 关键行：`[FP_HAL][UltraSonicCore_default]: invalid cali data` → `notifyError(1)` → `onError(code=1, error=1, vendor_code=0)`。

---

## 根因剖析与硬件物理坐标

### 1. 硬件物理传感器真实位置测量（RMX5010 原厂）
- **屏幕物理分辨率**：1264 × 2780（屏幕中心 X = 632）。
- **原厂 UFF HAL 日志证据**：
  ```text
  sensorlocation=632::2146
  iconlocation=633
  ```
  - 屏幕底部向上距离为 633px：`2780 - 633 = 2147`，与 HAL 物理传感器中心 `(632, 2146)` 严格自洽。
- **与一加 13（OP13）的坐标差异对照**：
  | 维度 | 一加 13（OP13，PJZ110） | realme GT7 Pro（RMX5010） | 偏移差值 |
  |---|---|---|---|
  | 屏幕分辨率 | 1440 × 3168（2K） | 1264 × 2780（1.5K 定制屏） | - |
  | 物理中心 (X, Y) | (720, 2504) | (632, 2146) | X 偏 88px，Y 偏 358px |
  | 左上角坐标 (X, Y) | 628, 2412 | **540, 2054** | - |
  | 传感器尺寸 | 184 × 184 | **184 × 184** | - |
  | 超声波 Target 矩形 | 616, 2388, 824, 2616 | **528, 2030, 736, 2258** | - |

### 2. 框架层声明与特性开关缺失
- Android 15 规范下，`SystemServer` 启动时必须由 `PackageManager` 枚举到 `/product/etc/permissions/android.hardware.fingerprint.xml`，才会初始化并注册 `Context.FINGERPRINT_SERVICE`。
- donor 小米底包 `nezha.xml` 原始配置中写死：
  ```xml
  <bool name="front_fingerprint_sensor">false</bool>
  ```
  缺少 `front_fingerprint_sensor=true` 与 `support_fod=true` 导致锁屏与 SystemUI 隐藏 FOD 悬浮图层。

### 3. Treble 规则与 SELinux 避坑指南（关键教训）
- **禁止在 `vendor_sepolicy.cil` 中越权授权**：向 `vendor_sepolicy.cil` 强加 `(allow system_server vendor_fp_prop ...)` 会直接触发 Android 15 Treble CTS neverallow 违规，导致早期 init 的 `secilc` 策略编译致命崩溃（第一屏卡死）。
- **禁止在 `odm/build.prop` 写入系统命名空间属性**：`ro.hardware.*` 属于系统层属性，ODM 强写会导致属性空间解析异常；所有属性均必须收敛在合法的 `persist.vendor.*` 命名空间。

### 4. 录入失败 `invalid cali data` — vendor.fingerprint.cali 属性缺失（2026-10-19 定位）

UFF HAL 在 `UltraSonicCore::enroll` 入口有一道工厂校准状态闸（`fp_hal.elf` vaddr）：

```
0x24d24   bl   #0x4dec8             ; loadFpCaliState() — 读取内部校准标记
0x24e28   bl   #0x4887c             ; getFactoryCaliState():
                                      __system_property_get(
                                         "vendor.fingerprint.cali", buf)
                                      return (buf[0] == '1') ? 1 : 0
0x24e2c   tbz  w0, #0, #0x250c0     ; bit0==0 → fail
0x250c0   "invalid cali data"       ; → notifyError(1) → BiometricsFpSessionV3::onError(1,1,0)
```

- ColorOS 上该 prop 由工厂测试写 `1`；本包 `vendor_property_contexts` 完全没有 `vendor.fingerprint.`/`persist.vendor.fingerprint.`/`oplus.fingerprint.` 前缀映射 → 落到 `default_prop` → `hal_fingerprint_oppo` 对 `default_prop` 无 `property_service set` 权限 → HAL 写不进，永远读到空串 → enroll 秒拒。
- 手动验证：`setprop vendor.fingerprint.cali 1` (root) 后走正常流程，HAL 日志走到 `DEVICE_ENTER_ENROLL success` + `sendCommand 2006 OK`，无 `invalid cali data`，等待手指按压。
- 二进制备用修复（不推荐）：patch `0x24e2c` 的 `tbz w0,#0` 为 `tbnz w0,#0`（反转条件），或在 `bl` 之后立即 `mov w0,#1`。

---

## 实施方案

### 一、`product.img`：补齐框架特性与设备开关

1. **`/product/etc/permissions/android.hardware.fingerprint.xml`**：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <permissions>
       <feature name="android.hardware.fingerprint" />
   </permissions>
   ```
   - 标签：`u:object_r:system_file:s0`（权限 644）。
2. **`/product/etc/device_features/nezha.xml`**：
   - 开启前置指纹传感器：`<bool name="front_fingerprint_sensor">true</bool>`
   - 开启 FOD 屏下指纹支持：`<bool name="support_fod">true</bool>`
   - 保持超声波方案代号：`<integer name="fod_solution">3</integer>`

### 二、`odm.img`：写入真机超声波物理坐标与驱动参数

在 `/odm/build.prop` 与 `/odm/etc/build.prop` 中注入真实参数：
```properties
persist.vendor.sys.fp.vendor=true
persist.vendor.sys.fp.fod.location.X_Y=540,2054
persist.vendor.sys.fp.fod.size.width_height=184,184
persist.vendor.sys.fp.fod.us.target=528,2030,736,2258
persist.vendor.sys.fp.fod.delay.fingerdown.ms=20
```

### 三、`vendor.img`：补 `vendor.fingerprint.*` 属性映射与域授权

**`vendor_property_contexts`** 追加（本仓库 `vendor_property_contexts.diff`）：
```
vendor.fingerprint.          u:object_r:vendor_fingerprint_prop:s0
persist.vendor.fingerprint.  u:object_r:vendor_fingerprint_prop:s0
oplus.fingerprint.           u:object_r:vendor_fingerprint_prop:s0
```

**`vendor_sepolicy.cil`** 追加（本仓库 `cali_prop.cil`）：
```cil
(type vendor_fingerprint_prop)
(roletype object_r vendor_fingerprint_prop)
(typeattributeset property_type (vendor_fingerprint_prop))
(typeattributeset vendor_property_type (vendor_fingerprint_prop))
(typeattributeset vendor_public_property_type (vendor_fingerprint_prop))

(allow hal_fingerprint_oppo vendor_fingerprint_prop (property_service (set)))
(allow hal_fingerprint_oppo vendor_fingerprint_prop (file (read getattr map open)))
(allow hal_fingerprint_oppo prop_socket (sock_file (write)))
(allow hal_fingerprint_oppo property_socket (sock_file (write)))
(allow hal_fingerprint_oppo property_socket (unix_stream_socket (connectto)))
```

效果：HAL 在 `setFactoryCaliState` / 初始化路径上可写入 `vendor.fingerprint.cali=1`，enroll 入口的 `getFactoryCaliState` 闸读回 `1`，通过校验进入 TA enroll。

---

## 实机验证证据（真机 acbefdc7）

1. **硬件特性枚举验证**：
   ```bash
   adb shell pm list features | grep -i fingerprint
   # 输出：
   # feature:android.hardware.fingerprint
   # feature:oplus.hardware.fingerprint.unlock_without_icon.support
   ```
2. **指纹服务注册与 HAL 状态**：
   ```bash
   adb shell dumpsys fingerprint
   # 输出：
   # Dumping for sensorId: 1, provider: FingerprintProvider
   # Fps state: 0
   # {"service":"FingerprintProvider/default","prints":[{"id":0,"count":0...}]}
   # HAL deaths since last reboot: 0
   ```
3. **生物识别认证器级别**：
   ```bash
   adb shell dumpsys biometric
   # 输出：
   # Sensors:
   #  ID(1), oemStrength: 15, updatedStrength: 15, modality 2, state: 0, cookie: 0
   # （modality 2 = TYPE_FINGERPRINT，strength 15 = BIOMETRIC_STRONG 强生物识别）
   ```
4. **设置界面跳转与录入调起**：
   ```bash
   adb shell am start -a android.settings.FINGERPRINT_SETTINGS
   # 输出：
   # Starting: Intent { act=android.settings.FINGERPRINT_SETTINGS }
   # 前台焦点成功激活 com.android.settings/.password.ChooseLockGeneric（前置锁屏凭据与指纹录入引导）
   ```
5. **enroll 校准闸验证（2026-10-19 实机 acbefdc7）**：
   ```bash
   # 未修复：HAL init 阶段 vendor.fingerprint.cali setprop 被 SELinux 拒
   #   E [FP_HAL][FpCa]: can not set prop vendor.fingerprint.cali
   # 修复后 setprop vendor.fingerprint.cali 1（或 sepolicy 让 HAL 自写）→ 触发录入：
   12:31:59.469  [UltraSonicCore_default]: [enroll] enroll gid = 0, timeout = 0
   12:31:59.470  [FPDevice]: [controlTp] mode = 1
   12:32:00.417  [FPDevice]: OplusTouch write node 196, value = 1, result:1
   12:32:00.417  [UltraSonicCore_default]: set DEVICE_ENTER_ENROLL success
   12:32:00.451  [FpCa]: sendCommand take time 33 ms
   # 无 invalid cali data / notifyError / onError → 正常等待手指按压
   ```

---

## 2026-10-26 h19 主线实机进展（haotian 0.19 + 原厂 16.0.7.201）

> 本节记录当前设备的真实状态与已验证结论，避免后续重复踩坑。上面 OS3 时代的
> 「实机验证证据」来自当时 nezha/OS3 底包，结论仍可参照，但不能直接当作 h19 的现状。

### 已完成并刷入（product_a）

1. **`/product/etc/permissions/android.hardware.fingerprint.xml`**（新增）
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <permissions>
       <feature name="android.hardware.fingerprint" />
   </permissions>
   ```
   这是 h19 底包**完全缺失**的一项。加之前：`pm list features` 无指纹特性、
   `dumpsys biometric` 传感器列表为空、日志 `SystemServiceRegistry: No service published for: fingerprint`。
   加之后（重启生效）：
   - `pm list features | grep fingerprint` → `feature:android.hardware.fingerprint`；
   - `dumpsys biometric` → `ID(1), oemStrength: 15, modality 2`；
   - `dumpsys fingerprint` → `sensorId: 1, provider: FingerprintProvider`。
2. **`/product/etc/build.prop`** 追加 7 个属性（内容见 `product_build.prop.append`，
   坐标 540,2054 / 184,184 / 528,2030,736,2258 为 RMX5010 实测值）。
3. **`/product/etc/device_features/haotian.xml`**
   - `front_fingerprint_sensor` 由 `false` 改为 `true`（h19 底包仍是 false）；
   - 新增 `support_fod=true`（底包原本没有这一项）；`fod_solution=3` 原本已正确。

构建脚本：`scripts/build_h19_fingerprint_features.sh`；刷写：`scripts/flash_product.sh`
（`PART=product_a IMG=... `）。

### 结果与仍未闭环的部分

- 上述三项生效后，**设置里仍然没有指纹入口**（「面部与密码」页只有录入人脸/设置锁屏密码）。
- 锁屏状态下直接启动 `com.android.settings/.Settings$FingerprintSettingsActivityV2`
  抛 Binder 异常（未解锁，无法确认该 Activity 是否可正常打开），因此“入口被隐藏”
  与“打开的上级页面不对”两种可能都还没排除。
- `getprop vendor.fingerprint.cali` 当前为空。按 OS3 结论，录入会在 HAL 入口报
  `invalid cali data` 秒拒，需要该属性为 `1`（参见上文 vendor 属性映射 + CIL 方案）。
  这项在 h19 尚未做。
- 待查方向：haotian 0.19 的 Settings 除特性/设备特性外还看哪些键
  （`MiuiConfig` / `FeatureParser` 的 `support_fingerprint` 类键），以及解锁后
  `FingerprintSettingsActivityV2` 能否直接打开。

### 2026-10-26 追加：odm 指纹 HAL 替换

- 新增 `bin/vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff`
  （sha256 `2c0f5399c9f81a47d882903dc362d6654c44fa78f34f1d2500d9dc2e0e3582ba`，640200 B）。
- 脚本 `scripts/build_odm_fp_hal.sh`：写入 odm stage 的 `/bin/hw/`，
  chmod 0755、标签 `u:object_r:hal_fingerprint_oppo_exec:s0`（contexts 已有该路径），
  重建 `odm.img` 并刷 `odm_a`。
- 实刷后：HAL 进程 `vendor.oplus.hardware.biometrics.fingerprint@2.1-service_uff` 正常运行，
  `dumpsys biometric` 指纹传感器 ID(1) modality 2 在线；设置入口/录入待回归。
- 人脸录入卡进度环是独立问题（Settings 状态机），修复见
  `docs/人脸录入卡住_根因与修复.md`。

### 镜像哈希（便于回退/核对）

- 当前已刷（含以上三项）：`product_fp.img` sha256 `97b5b86d16512cfdf1dd2720dc1489dd5f4c7dd449f44316e88a30efdc23742e`
- 上一版（灵动岛 74px + padding14px，无指纹改动）：`product_island.img` sha256 `2de61de672934de7a2bd627812c3e3ab9229114c110d1a852a0ddf606d4b8aea`
- 回退：`PART=product_a IMG=.../product_island.img scripts/flash_product.sh`

### 运行时兜底（可选）

`ksu-module/` 是同一组属性的 KernelSU 模块（`system.prop` + `post-fs-data.sh`
显式 resetprop），用于在镜像未重刷时快速验证。镜像已带属性时可删除，
两者值一致，不冲突。
