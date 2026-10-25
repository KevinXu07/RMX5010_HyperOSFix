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


## 后续修正（2026-10-16 晚）：型号 → 25128PNA1G

`2410DPN6CC` 是 haotian（小米 15 Pro）的型号，**不是 nezha 的**。nezha 有两个代号：

- 小米/徕卡侧：`missi`（证据：donor system 分区的 build.prop 里有 `# from device/xiaomi/missi/system.prop`，
  且 `ro.system.build.fingerprint=Xiaomi/missi/missi:17/CP2A.260605.016/...`）
- Redmi/产品侧：`nezha`（`ro.product.product.name=miproduct_nezha`，且 `device_features/nezha.xml`）

现在的取值：`ro.product.model` / `ro.product.odm.model` = **25128PNA1G**（徕卡版型号，用户提供；
该串在 donor 包里搜不到，属于外部信息）；`ro.product.device/name` 保留 `nezha`（device_features 只有 nezha.xml）。
如需把 device/name 也改成 `missi`，改 odm_build.prop 里那四行即可。

---

## 2026-10-25 更新：主线切换到 haotian，身份再次改写（device/name/marketname）

donor 从 nezha OS4.0.2.0 切到 **haotian OS4.0.0.19.XOBCNXM**（15 Pro）后，身份块再次改写：

```
ro.product.odm.device=haotian      ro.product.device=haotian
ro.product.odm.name=haotian        ro.product.name=haotian
ro.product.odm.model=2410DPN6CC    （不变，与本 donor odm 自带值一致）
ro.product.odm.marketname=Xiaomi 15 Pro   （原 Realme GT7 Pro）
```

合成指纹变为 `Xiaomi/haotian/haotian:17/CP2A.260605.016/OS4.0.0.19.XOBCNXM:user/release-keys`。
实机验证：正常开机、Enforcing、米账号闭包进程（mtd/hypsys/fidoca）全部存活、
设置内型号显示 Xiaomi 15 Pro / 2410DPN6CC。

### 血泪教训：重建 odm 卡第一屏的根因（违反本仓库 SELinux 规范 §3 的实例）

对 odm 做过 7 轮"改 build.prop → 重建 → 刷写"，其中 6 轮卡死在第一屏（adbd 不起），
与改哪些 prop **无关**——连"零改动重建"都卡。字节级 diff（`cmp` 逐字节对比重建镜像与
已知可开机镜像）发现全部差异仅 73 字节，其中 54 字节是悬空软链
`etc/vintf/manifest/network_manifest.xml` 的 inode 区域：

- 旧镜像（可开机）：该软链 inode 自带 `security.selinux=vendor_configs_file`（xattr 计数=2）
- 重建镜像：**0 个 xattr**

根因：生成 file_contexts 时用 `os.getxattr()`（默认跟随软链）读悬空目标 → 必然 OSError →
该软链被跳过 → 镜像内 unlabeled。Enforcing 下 init/libvintf 访问 unlabeled 的
vintf manifest 软链被拒 → 卡死。**规范 §3 的 `follow_symlinks=False` 就是为这一条写的。**

排查手段（值得沉淀）：对整个镜像做 `cmp` 逐字节对比 + 差异区间归类，比"读规范想象"
可靠得多。重建时的完整约束以 [SELinux 规范](../../docs/SELinux闭包与EROFS重建规范.md) §3/§4 为准。

### 回滚件

nezha 身份版本保留于构建目录 `odm.img.nezha-id.bak`，一条 `fastboot flash odm_a` 可回退。
