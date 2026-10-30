# SurfaceFlinger 触摸升帧（LTPO 交互刷新率）

日期：2026-10-29
载体：KSU 模块 `rmx5010_fod_bridge` 1.3.9（`post-fs-data.sh`）

## 现象

抖音 feed 里的视频是 30fps 时，打开评论区、连续滑动评论列表仍然一直是 30Hz，
不会回到 60/120。旧版 SurfaceFlinger 策略：

```text
touchTimer=nullopt
ro.surface_flinger.set_touch_timer_ms=0
```

同时 App 的窗口：

```text
VRI-...MainActivity requestedFrameRate: {30.00 Hz ...}
renderRate=30.00 Hz
activeMode=60Hz
```

说明 App 为视频把整个窗口固定成 30Hz，而 SurfaceFlinger 的触摸升帧被关闭，
所以滑动评论也仍按 30Hz 走。这不是 GameManager 的 24fps 问题，也不是 App 单方面的
“视频 30fps”问题：静态时降到视频帧率是对的，但触摸交互期间应该由 SF 升帧。

## 修复

`post-fs-data.sh` 在 SurfaceFlinger 启动前执行：

```text
/data/adb/ksud resetprop ro.surface_flinger.set_touch_timer_ms 2000
```

`2000` 表示触摸后保持升帧 2 秒。模块启动日志：

```text
sf touch timer: 2000
```

重启后实测抖音评论区连续滑动：

```text
滑动瞬间: renderRate=120.00 Hz，activeMode=120Hz
          （App 自身仍写着 requestedFrameRate=30Hz）
停止触摸 2 秒: renderRate=30.00 Hz，activeMode=60Hz
```

帧率计数器也一致：触摸期间 120Hz 计数持续增长，30Hz 不增长；停止后 120Hz 停止，
30Hz 继续增长。说明是全局 SurfaceFlinger 触摸升帧，不依赖任何 App 名单。

## 影响与回退

- 全局对所有 App 生效：评论/列表滑动、设置页、游戏触摸都会在触摸后短暂升到
  120Hz，然后回落到内容帧率。
- 会增加一点功耗/发热；如果觉得过于激进，可把 2000 改成 500 或 1000 ms。
- 回退：删除 `post-fs-data.sh` 中的 `resetprop` 调用并重启，或手动
  `ksud resetprop ro.surface_flinger.set_touch_timer_ms 0` 后重启。
- 这不是把视频强行改成 120fps；视频本身仍按 30/60fps 输出，只是触摸交互期间
  面板/合成器升到 120Hz，避免滑动时卡在 30Hz。
