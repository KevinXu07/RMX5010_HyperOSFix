# 注视感知：小米 MiAON → Oplus AON 摄像头 HAL 桥接（2026-11-13，Sense 1.54）

## 现象
HyperOS 设置里的"注视感知"（注视屏幕时不熄屏 / 离开后自动锁屏 / 长时间未注视降低亮度）开着也没有效果。

## 链路
- 这些功能都是 AOSP 屏幕注视：`AttentionDetector`（PowerManager，`adaptive_sleep=1`）在变暗前 2 s
  调 `AttentionManagerService.checkAttention` → 绑定的 `com.xiaomi.aon/.AonAttentionService`。
- `AonAttentionService` → `AONAdapter.registerListener(type 4, algo, timeout)`：先检查
  `mDeviceCapability & type`，再调后端 `IAONInterface.AonEventRegister`；后端经
  `AONEventUpdate.updateToClient(4, int[])` 回报，`AttentionClient$1` 在 `data[5]==1 || data[11]==1`
  时回 `ATTENTION_SUCCESS_PRESENT`。
- 后端按 `ro.miui.support.aon.*` 选择：Tee（`vendor.xiaomi.hardware.miface`）、Aoc/Cpu/Enpu
  （`vendor.xiaomi.hardware.aon.IAlwaysOn`）、MtkV3（`vendor.mediatek...aovservice`）——全部是小米/联发科
  专有 HAL。本机无任何属性 → Tee，`IMiFace.getService()` 抛 `NoSuchElementException`，能力为 0：
  `registerListener 4 failed, Please check capability, mDeviceCapability: 0`。

## 本机可用的硬件
真我 vendor 的 `vendor.oplus.hardware.camera.aon.IAONService/default`（V1，跑在
`vendor.qti.camera.provider` 进程，`/odm/lib64/vendor.oplus.hardware.camera.aon-service-impl.so`，
底层 QSEE AON 固件），即 ColorOS `my_product/app/AONService` 使用的 HAL。

接口（ndk 桩反汇编 + ColorOS AONService Java 桩确认）：

| tx | 方法 |
|---|---|
| 1 | `long registerClient(IAONServiceCallBack cb, int serviceTypeMask)` |
| 2 | `AONSensorInfo[] getAonSensorInfoList()` |
| 3 | `subscribeSensor(long, SensorConfigInfo{sensorId, w, h, fps, framesPerDelivery, periodMs, serviceType, deliveryMode})` |
| 4 / 5 | `startService(long, int type)` / `stopService(long, int)` |
| 6 / 7 | `unsubscribeSensor(long)` / `unregisterClient(long)` |
| 回调 1 / 2 | `onAONEvent(long, AONCallBackInfo{serviceType, AONResult[]{id, ResultData union}})` / `onAONSensorEvent` |

- `ResultData` 是 union：tag 0 byte、1 byte[]、2 int、3 int[]、4 string、5 float、6 float[]、7 double、8 double[]、9 bool。
- 传感器：1 个，`imx480` 前摄，slot 3，`supportedSrvType=0xdf`，帧 320×240 @ 20/15/10/5 fps。
- 结果 id：100 手机角度（float）、101 人脸数（int）、102/103 fusion、200、**300 注视 float[23]**
  （[0] gaze_x、[1] gaze_y、[2..5] 眼部尺寸、[6..] 眨眼信息）。
- **回调 Binder 必须 `markVintfStability()`**，否则 HAL 报
  `Cannot do a user transaction on a system stability binder ... in a vendor stability context` / `BAD_TYPE`。
- SELinux：`com.xiaomi.aon`（`system_app`）可直接 find + call，无需补策略。

## 判定（按本机标定）
ColorOS `GazeUtils` 竖屏框是 −7.6<x<7.6、−4.4<y<19.4，本机实测会误把"看别处"判成注视。实测：

| | gaze_y | gaze_x |
|---|---|---|
| 注视屏幕 | 约 3~10（~85% 帧） | −11~0 |
| 看别处 | −3.8~2.0，且多数帧（76/99）无注视结果 | −8.5~0.4 |

规则：人脸数>0、睁眼（`(a1+a3)/(a0+a2) ≤ 7`，沿用 ColorOS）、竖屏 `3 < y < 19.4` 且 `−14 < x < 10`；
横屏按 ColorOS 表的方向旋转（90°：`−19.4 < x < −3`；180°：`−19.4 < y < −3`；270°：`3 < x < 19.4`）。
最近 5 帧中 ≥2 帧为注视才报 PRESENT；**只报 PRESENT，不报 ABSENT**——误判只会让屏幕按原超时熄灭。

## 实现
- Sense `XiaomiAonGazeHooks`（作用域 `com.xiaomi.aon`）只接管 `AONFaceTee` 的 type 4：
  `getAONCapability` 或上 4；`AonEventRegister(4,…)` → register(0xf) + subscribe(3, 320×240, 10fps,
  10 帧/1000ms, 0x4, mode 1) + start(0x4)；`AonEventUnRegister(4)` → stop/unsubscribe/unregister；
  判定为注视时调 `AONFaceTee.AlwaysonFaceCb(4, data)`（`data[5]=1`），走小米自己的 handler。
- 每次会话结束打印统计：帧数、人脸帧、注视帧、判定帧、首帧/首次 PRESENT 时延、gaze_y 范围。
- 模块：`com.xiaomi.aon` 加入 `SENSE_SCOPES` 与 `service.sh` 开机补注册，标记升到 `v3`。
- 调试工具：`tools/aonprobe`（root 下 `app_process` 运行，打印传感器列表与每帧结果）。

## 验证
- `cmd attention call checkAttention`：约 0.3 s `ATTENTION_SUCCESS_PRESENT`，取消后会话停止、客户端注销。
- 实际使用（超时 60 s）：注视时变暗前检查 0.42 s / 0.61 s 返回 PRESENT → `onUserAttention()`，屏幕不变暗；
  移开视线后照常变暗、熄屏，会话随之停止。
- 第一次实测出现过 3.1 s 才 PRESENT（屏幕先暗约 1 s 再恢复），统计日志加入后的两次均在 0.6 s 内，
  推断当时未正视屏幕。
