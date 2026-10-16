# patches/mtp-and-dpi — MTP 稳定性 + 屏幕密度 500

## 1. MTP：换回 RMX5010 原厂 `init.usb.configfs.rc`

- 目标路径：`system/etc/init/hw/init.usb.configfs.rc`
- 本目录的 [init.usb.configfs.rc](init.usb.configfs.rc) 即 **RMX5010 原厂（ColorOS 16.0.7.201）**文件，
  SHA-256 `87ffc530d89c587a8b3751e1ad66ec0bae365753421d4a0c72af20eab62b8d6b` —— 与 OS3 时代实机验证过的那份**完全一致**。
- 为什么需要：donor（小米）的 rc 里 MTP 分支带了额外的门控/rmdir 逻辑，在 Oplus 底上会破坏 MTP 配置链；
  原厂 rc 的 `on property:sys.usb.config=mtp && property:sys.usb.configfs=1` 分支才与本机 USB 控制器匹配。
- 与 donor 版本的差异：109 行（含 MIUI ADD/DEL 区块、`setusbconfig to` kmsg 调试行等）。

## 2. DPI：480 → 500

`product/etc/build.prop` 两行：

```
ro.sf.lcd_density=500
persist.miui.density_v2=500
```

- 依据：RMX5010 面板 1264×2780，物理密度 500；donor 默认 480 会让 UI 偏小。
- haotian 时代（A6a）同改法**实机验证**过；nezha 版 `device_features/nezha.xml` 里没有分辨率列表项
  （`nezha.xml` 与 `haotian.xml` 结构不同），所以**不需要**再补 `1264,1080` 之类的列表。
- 注意：`persist.*` 是 userdata 里的覆盖值，若刷机前机器上已有 `persist.miui.density_v2=480` 的旧值，
  镜像默认值不会生效 —— 首次开机后确认 `wm density` 为 500；不是的话用
  `adb shell wm density 500` 或清 userdata（本轮刷机本来就要 `-w`）。

## 验证

```bash
adb shell getprop ro.sf.lcd_density            # 500
adb shell getprop persist.miui.density_v2      # 500
adb shell wm density                           # Physical density: 500
# MTP：连接电脑后应出现 MTP 设备；adb shell setprop sys.usb.config mtp 后枚举正常
```


## 3. 补 `ro.miui.product.home`（炸桌面）

`product/etc/build.prop` 追加（[product_build.prop](product_build.prop) 为修好后的完整文件）：

```
ro.miui.product.home=com.miui.home
```

依据：该 prop 在整包里**没有被任何地方设置**（donor system/product/system_ext 与一加 my_product 都查过），
而 MIUI 应用会读（`MISettings.vdex`、`MIUICloudBackup.vdex`、`Backup.vdex`、`MIUIContactsT.vdex`、
`MIUSecurityCenter.vdex` 里都有该字符串）；桌面包名 = `com.miui.home`（`product/priv-app/MiuiHome`）。
