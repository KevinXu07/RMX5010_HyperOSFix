# 双击亮屏（AOD）不工作：根因与修复

日期：2026-10-26　机型：RMX5010（realme GT7 Pro）　底座：原厂 16.0.7.201 + haotian OS4.0.0.19.XOBCNXM

## 1. 症状

- 息屏 / AOD 下双击屏幕不亮屏。
- 此前移植的一加 13（OP13）F4 修复（LSPosed 监听 KEY_F4 后唤醒）**完全没有效果**。

## 2. 根因链

1. `synaptics_hbp` 驱动只在**低功耗手势模式（LPWG）**下解析手势包；除指纹按下/抬起、进水外，
   所有手势统一上报 `KEY_F4`（`syna_tcm2.c` 的 LPWG report 分支：
   `input_report_key(input_dev, KEY_F4, 1/0)`，input 设备 `/dev/input/event5`）。
   也就是说 Android 侧的 F4 事件源依赖驱动先进入 LPWG。
2. 是否进入 LPWG 由 `syna_dev_update_lpwg_status()` 决定：

   ```c
   tcm->lpwg_enabled = (tcm->gesture_type || tcm->touch_and_hold
                        || (tcm->fp_active && !tcm->fp_prevent)
                        || tcm->under_water_detect) ? true : false;
   ```

   息屏时 `syna_dev_enter_lowpwr_sensing()` 只有 `lpwg_enabled=true` 才会下发 gesture mask
   并调用 `syna_dev_enable_lowpwr_gesture()`；否则直接 `syna_tcm_sleep()` 深睡。
3. HyperOS 没有任何 Oplus 触摸 HAL 集成，**从不写** `double_tap_enable` / gesture_type 节点，
   因此 `tcm->gesture_type` 恒为 0 → 息屏即深睡 → AOD 下触摸没有任何事件。
   OP13 的 F4 钩子没有事件源，自然“抄了也没用”。

## 3. Oplus 触摸 HAL 控制面（免改内核）

AIDL 服务：`vendor.oplus.hardware.touch.IOplusTouch/default`
（实现在 `/odm/lib64/vendor.oplus.hardware.touch-V2-ndk.so`，HAL 进程 pid 2183 附近的
`OplusTouch:` 日志；实际节点处理在 `touchDaemon` 进程）。

Binder transaction（从 `BpOplusTouch` 符号提取 + `service call` 实测）：

| code | 方法 | 参数 |
|---|---|---|
| 2 | `isTouchNodeSupport` | deviceId, nodeId |
| 3 | `touchReadNodeFile` | deviceId, nodeId → string |
| 4 | `touchWriteNodeFile` | deviceId, nodeId, int value |

节点 ID → 路径（deviceId=0，实测映射）：

| node | 路径 | node | 路径 |
|---|---|---|---|
| 1 | `/proc/touchpanel/double_tap_enable` | 21 | `/proc/touchpanel/double_tap_enable_indep` |
| 2 | `coordinate` | 22 | `oplus_optimized_time` |
| 3 | `baseline_test` | 23 | `kernel_grip_default_para` |
| 5 | `oplus_tp_direction` | 24 | `smooth_level` |
| 8 | `kernel_grip_handle` | 25 | `sensitive_level` |
| 9 | `report_rate_white_list` | 26 | `game_switch_enable` |
| 10 | `charge_detect` | 28 | `leather_cover_enable` |
| 14 | `baseline_result` | 31 | `fp_enable` |
| 16 | `tp_aging_test` | 34 | `tpedge_limit_enable` |
| 17 | `debug_info/delta` | 38 | `pencil_control` |
| 18 | `debug_info/baseline` | 39 | `gesture_support` |
| 20 | `debug_info/health_monitor` | 40 | `/proc/colorctrl/color_ctrl` |

> 这些 `/proc/touchpanel/*` 文件在 HBP 驱动里多数不存在，节点读写实际由 `touchDaemon`
> 在进程内维护并转成 `/dev/tcm_hbp0` 的 HBP control 帧，不要直接去 write proc 节点。

关键写入：

- `node 1 = 1`：`touchDaemon` 置 `gesture_enabled=1`（框架语义的“双击开关”）。
- `node 21 = <Android 手势位图>`：`touchDaemon` 换算成内核 `gesture_type` 并通过
  `CMD_SET_DYNAMIC_CONFIG/DC_GESTURE_TYPE_ENABLE` 下发。
  实测映射（写值 → 内核 `gesture_type`）：

  | node21 | kernel | node21 | kernel |
  |---|---|---|---|
  | 2 | 0x0001（双击，bit0） | 256 | 0x0080 |
  | 3 | 无下发 | 512 | 0x0100 |
  | 4 | 0x0004 | 1024 | 0x0200 |
  | 8 | 0x0002 | 4096 | 0x0800 |
  | 16 | 0x0008 | 65535 | 0x1fff |
  | 32 | 0x0010 | | |
  | 64 | 0x0020 | | |
  | 128 | 0x0040 | | |
  | 255 | 0x007f | | |

  双击只需要 `node21 = 2`。`touchDaemon` 把 mask 保存在进程内，并在**每次息屏时自动重发**，
  所以只要在开机后（或 daemon 重启后）成功写一次即可长期生效。

## 4. 落地方案

`kernel-src/ksu-module/service.sh`（KSU 模块 `rmx5010_fod_bridge`）：

1. 加载 FOD 触摸桥 `.ko` 后，向触摸 HAL 写 `node1=1`、`node21=2`；
2. 最多重试 180 s，等 `touchDaemon` 就绪（用写入返回值 `00000001` 判定）；
3. 后台每 30 s 检查 `pidof touchDaemon`，PID 变化（daemon 重启）后自动重发；
4. 全过程写入模块目录 `boot.log`，便于取证。

脚本片段：

```sh
TOUCH_SVC=vendor.oplus.hardware.touch.IOplusTouch/default
service call "$TOUCH_SVC" 4 i32 0 i32 1 s16 1    # double_tap_enable
service call "$TOUCH_SVC" 4 i32 0 i32 21 s16 2   # gesture_type bit0 = double tap
```

## 5. 验证证据

冷启动（`boot.log` + `dmesg`）：

```text
10-26 08:43:30 insmod rc=0
10-26 08:43:30 gesture applied after 0 s: Result: Parcel( 00000000 00000001 ...)
10-26 08:43:30 gesture applied for touchDaemon pid=3116

syna_dev_set_gesture_type: syna_dev_set_gesture_type: 1
syna_dev_enable_lowpwr_gesture: read back gesture mode is 1
syna_dev_enable_lowpwr_gesture: set wakeup gesture(0x09) mode to 1
syna_dev_enter_lowpwr_sensing: low power gesture mode enabled
```

Framework 侧免手戳验证（evdev 注入，Linux `KEY_F4 = 62`）：

```sh
su -c 'input keyevent 223'          # 进 Dozing
# 连续注入两次 F4 DOWN/UP，间隔 < 280 ms
sendevent /dev/input/event5 1 62 1; sendevent /dev/input/event5 0 0 0
sendevent /dev/input/event5 1 62 0; sendevent /dev/input/event5 0 0 0
sleep 0.12
sendevent /dev/input/event5 1 62 1; sendevent /dev/input/event5 0 0 0
sendevent /dev/input/event5 1 62 0; sendevent /dev/input/event5 0 0 0
```

结果：`mWakefulness` 由 `Dozing` → `Awake`；LSPosed 日志：

```text
OP13HyperOSFix: F4 event action=0 scan=62 repeat=0
OP13HyperOSFix: F4 event action=1 scan=62 repeat=0
```

注意：LSPosed 钩子按“双击”语义工作——`DOUBLE_TAP_WINDOW_MS = 280`，
窗口内第二次 F4 DOWN 才走 `wakeFully()`；单次 F4 只走 AOD 单击路径，不会点亮。

## 6. 风险与备注

- 该方案把双击亮屏**强制开启**；HyperOS 设置里的“双击亮屏”开关没有接入（F4 钩子内部的
  `ModuleConfig.DOUBLE_TAP_WAKE` 仍可关闭唤醒动作，但 LPWG 使能是常开的）。
- 若 `touchDaemon` 被 kill 且 init 未重启它，双击会失效，需重启系统。
- 不改内核、固件、vendor/odm/分区镜像，纯运行时 + `/data` KSU 模块，可随时删除恢复原状。
- 息屏 FOD 指纹链路依赖同一 LPWG 状态（`fp_active` 也会使能 LPWG），本修复不会影响指纹。
