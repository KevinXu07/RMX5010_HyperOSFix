# NFC 功能适配（NXP SN220 芯片栈 + Xiaomi NFC 服务协议栈）

面向 **realme GT7 Pro（RMX5010）** 移植小米 HyperOS 的全套 NFC 功能闭包方案。

---

## 症状与现象

- 系统下拉状态栏中的“NFC”快捷开关为灰色不可点击，或点击后瞬间弹回关闭状态。
- 系统「设置 -> 连接与共享」中缺少 NFC 菜单，或进入后提示服务不可用。
- 底层日志与服务状态：
  ```text
  Can't find service: nfc
  ```
  NFC 核心服务完全未运行。

---

## 硬件与底座分析

1. **硬件芯片差异**：
   - 小米 nezha（红米底包机型）原厂采用意法半导体方案（STMicro ST54L，对应包内 `Nfc_st.apk` 与 `st54l_conf`）。
   - realme GT7 Pro（RMX5010）原厂采用恩智浦方案（**NXP SN220**，底层驱动为 `android.hardware.nfc-service.nxp`）。
   - 若直接沿用 nezha 的 `Nfc_st`，硬件 HAL 无法匹配，服务直接崩溃。
2. **小米生态协议栈（XMNfcNci）**：
   - 小米生态系统（包括小米钱包、小爱同学触碰、触碰互联、门卡模拟等）依赖 Xiaomi 专有的 NFC 接口协议栈：`com.xiaomi.nfc.IMiNfcAdapter`（Binder 服务名：`mi_nfc`）。
   - 必须使用支持 NXP 芯片的官方小米协议栈 APK（`XMNfcNci.apk`）替换 ST 方案。

---

## 完整实施方案

### 1. 系统分区应用载荷（`system.img`）

- 注入小米 NXP NFC 服务协议栈：
  `/system/app/XMNfcNci/XMNfcNci.apk`
  - 文件大小：15,378,917 字节
  - SHA-256：`f680e8fafa51fc5d4ff76ab17deed0fbbecea331dc9c1343accf910bbba308bf`
  - 权限与属主：`0644 root:root`
  - SELinux 标签：`u:object_r:system_file:s0`

### 2. 产品分区功能属性（`product.img`）

在 `product/etc/build.prop` 注入 5 项 Xiaomi NFC 核心功能开关：
```properties
ro.vendor.nfc.repair=1
ro.vendor.nfc.wallet_fusion=1
ro.vendor.nfc.secure_display_optim=1
ro.vendor.nfc.mitouch=1
ro.vendor.nfc.phonecase=1
```

### 3. 底层策略与服务映射（`vendor.img`）

- **Binder 服务映射**（`vendor/etc/selinux/vendor_service_contexts`）：
  ```text
  mi_nfc    u:object_r:nfc_service:s0
  ```
- **属性上下文映射**（`vendor/etc/selinux/vendor_property_contexts`）：
  ```text
  ro.vendor.nfc.    u:object_r:vendor_nfc_mi_prop:s0
  ro.vendor.se.     u:object_r:vendor_nfc_mi_prop:s0
  ```
- **SELinux 策略闭包**（`vendor/etc/selinux/vendor_sepolicy.cil` 与 `debug` 版本）：
  ```cil
  (type vendor_nfc_mi_prop)
  (roletype object_r vendor_nfc_mi_prop)
  (typeattributeset property_type (vendor_nfc_mi_prop))
  (typeattributeset vendor_property_type (vendor_nfc_mi_prop))
  (typeattributeset vendor_public_property_type (vendor_nfc_mi_prop))

  (allow hal_nfc_default vendor_nfc_mi_prop (file (read getattr map open)))
  (allow hal_secure_element_default vendor_nfc_mi_prop (file (read getattr map open)))
  (allow hal_secure_element_default vendor_nfc_mi_prop (property_service (set)))
  (allow nfc_202404 vendor_nfc_mi_prop (file (read getattr map open)))
  (allow secure_element_202404 vendor_nfc_mi_prop (file (read getattr map open)))
  (allow system_app_202404 vendor_nfc_mi_prop (file (read getattr map open)))
  (allow vendor_init_202404 vendor_nfc_mi_prop (property_service (set)))
  (allow vendor_init_202404 vendor_nfc_mi_prop (file (read getattr map open)))
  (allow hal_misys_vendor_default vendor_nfc_mi_prop (file (read getattr map open)))
  ```

---

## 实机验证结果（设备：`acbefdc7`）

| 校验项 | 实机输出 | 结论 |
|---|---|---|
| **NFC 服务状态** | `dumpsys nfc` 返回 `mState=on` | ✅ NFC 核心服务正常运行中 |
| **系统 Binder 注册** | `service list` 成功注册：<br>`mi_nfc: [com.xiaomi.nfc.IMiNfcAdapter]`<br>`nfc: [android.nfc.INfcAdapter]` | ✅ 平台与小米双服务在线 |
| **底层 NXP HAL 识别** | `vendor.nxp.nxpnfc_aidl.INxpNfc/default`<br>`vendor.oplus.hardware.nfc.IOplusNfc/default` | ✅ 硬件通信正常（SN220 识别） |
| **APK 包管理器状态** | `package:/system/app/XMNfcNci/XMNfcNci.apk` | ✅ 原生系统预置应用加载成功 |
| **SELinux 安全状态** | `Enforcing` | ✅ 零 AVC 拦截崩溃 |

---

## 2026-10-25 补充（haotian 主线）：五项调优 prop 运行时未生效

haotian OS4.0.0.19 底上重新注入 XMNfcNci（0.19 donor 自带包不含该应用，需从
OS3 成品 system 提取，f680e8fa…/15,378,917 字节）。NFC 服务正常
（`service check nfc` = found，`nfc.initialized=true`），开关/基础功能可用。

但 product build.prop 追加的五项 `ro.vendor.nfc.{mitouch,phonecase,repair,
secure_display_optim,wallet_fusion}=1` **运行时 getprop 不到**：

- factory vendor 的 `vendor_property_contexts` 把 `ro.vendor.nfc.*` 标为
  `vendor_nfc_mi_prop`，而 factory `vendor_sepolicy.cil` **没有** `allow init
  vendor_nfc_mi_prop:property_service set`（ColorOS 自身不从这个 label 的
  build.prop 路径设置属性）→ init 加载 product build.prop 的 set 被 Enforcing 拒绝。
- nezha 主线当年是配合 OS3 时代 vendor sepolicy 补丁（含 init set 授权 + 读取域
  授权）一起落地的；factory 底上单独加 prop 不生效。

**修复路径（未实施，NFC 基础功能不受影响）**：vendor sepolicy 追加
`allow init vendor_nfc_mi_prop:property_service set;` + XMNfcNci 读取域授权，
重建 vendor.img。是否必要取决于 Mi 钱包/碰一碰实测是否缺这些调优。
