# patches/odm-identity — 修正 OnePlus/PJA110 混合身份

## 现象
刷完 nezha 主线后，设置里设备名/型号显示 **PJA110**（一加 Ace 3 Pro），制造商变成 OnePlus。

## 根因
`/odm/build.prop`（RMX5010 原厂）末尾有两行 import：

```
import /odm/etc/${ro.boot.prjname}/build.prop
import /mnt/vendor/my_manifest/build.prop      <-- 元凶
```

`my_manifest` 分区里那份 `build.prop` 是**一加 Ace 3 Pro 的完整身份块**：

```
ro.product.odm.model=PJA110
ro.product.odm.device=OP5943L1
ro.product.manufacturer=OnePlus
ro.build.fingerprint=OnePlus/PJA110/OP5943L1:13/TP1A.220905.001/T.134d489_1-1:user/release-keys
ro.vendor.build.fingerprint=OnePlus/PJA110/...
```

因为 `ro.product.odm.*` 的优先级最高，型号/制造商/指纹全被它接管。
（这份 my_manifest/my_product 是 OS3 时代的"精简版 my_*"，取自一加底包；OS3 那版已经打过
"删 import + 写身份"的补丁，nezha 主线没带过来。）

## 修法（[odm_build.prop](odm_build.prop) 是修好后的完整文件）
1. 删除 `/odm/build.prop` 里的全部 import 行（2 条）
2. 追加显式身份（odm 优先级最高，直接压过 my_manifest）：
   `ro.product.{manufacturer,brand}=Xiaomi`、`model=2410DPN6CC`、`device/name=nezha`、
   `marketname=Realme GT7 Pro`（同时写 `ro.product.odm.*` 变体）
3. 把修好的内容原样覆盖 `/odm/etc/build.prop`（它原本只有 4 行 import，同样会拉起项目 prop）

## 刷写与验证
只刷 odm，**不需要清数据**（不涉及 APK 签名）：

```bat
fastboot reboot fastboot
fastboot -S 128M flash odm_a images\odm.img
fastboot reboot
```

```bash
adb shell getprop ro.product.model        # 期望 2410DPN6CC
adb shell getprop ro.product.brand        # Xiaomi
adb shell getprop ro.build.fingerprint    # 不应再是 OnePlus/PJA110/...
adb shell getprop ro.product.marketname   # Realme GT7 Pro
```

## 遗留
`my_product/build.prop`（ext4 镜像）里还有 `ro.build.display.ota=PJA110_11_A.01…`、
`ro.product.authentication=2023CP8032` 等一加残留；本次未动该分区。若确认有东西直接读
my_product 的 prop，需要再单独改 ext4 镜像。
