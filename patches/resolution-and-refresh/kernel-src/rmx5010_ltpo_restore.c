// SPDX-License-Identifier: GPL-2.0
/*
 * Event-driven Realme GT7 Pro (RMX5010) ADFR min_fps restore helper.
 *
 * Hooks oplus_adfr_status_reset() via kretprobe to detect whenever the display
 * driver resets its adaptive refresh rate status (e.g. on app launch, camera,
 * fullscreen video, screen wake), and automatically restores min_fps=10 via
 * oplus_adfr_set_min_fps_attr().
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kprobes.h>
#include <linux/workqueue.h>
#include <linux/ratelimit.h>
#include <linux/jiffies.h>

static unsigned int min_fps = 10; // GT7 Pro panel accepts min 10
module_param(min_fps, uint, 0644);
MODULE_PARM_DESC(min_fps, "ADFR minimum FPS restored after panel reset (1..120)");

static unsigned int delay_ms = 350;
module_param(delay_ms, uint, 0644);
MODULE_PARM_DESC(delay_ms, "Delay after panel reset before restoring min_fps (0..5000 ms)");

static bool apply_on_load = true;
module_param(apply_on_load, bool, 0644);
MODULE_PARM_DESC(apply_on_load, "Apply min_fps once when the module loads");

typedef ssize_t (*set_min_fps_fn)(void *dev, void *attr, const char *buf, size_t count);
static set_min_fps_fn oplus_set_min_fps = NULL;

static atomic64_t reset_events = ATOMIC64_INIT(0);
static atomic64_t successful_writes = ATOMIC64_INIT(0);
static int last_error = 0;

static void ltpo_restore_workfn(struct work_struct *work);
static DECLARE_DELAYED_WORK(ltpo_restore_work, ltpo_restore_workfn);

static int ltpo_reset_return(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    unsigned int d;
    atomic64_inc(&reset_events);
    d = (delay_ms > 5000) ? 5000 : delay_ms;
    mod_delayed_work(system_unbound_wq, &ltpo_restore_work, msecs_to_jiffies(d));
    return 0;
}

static struct kretprobe ltpo_reset_probe = {
    .handler = ltpo_reset_return,
    .kp = {
        .symbol_name = "oplus_adfr_status_reset",
    },
    .maxactive = 8,
};

static void ltpo_restore_workfn(struct work_struct *work)
{
    char buf[16];
    int len;
    ssize_t ret;

    if (min_fps < 1 || min_fps > 120) {
        last_error = -ERANGE;
        return;
    }

    if (!oplus_set_min_fps) {
        last_error = -ENOSYS;
        return;
    }

    len = scnprintf(buf, sizeof(buf), "%u", min_fps);
    ret = oplus_set_min_fps(NULL, NULL, buf, len);
    if (ret < 0) {
        last_error = (int)ret;
        pr_err_ratelimited("rmx5010_ltpo_restore: min_fps=%u write failed: %d\n", min_fps, (int)ret);
    } else if (ret != len) {
        last_error = -EIO;
    } else {
        last_error = 0;
        atomic64_inc(&successful_writes);
    }
}

static int __init rmx5010_ltpo_init(void)
{
    int ret;
    struct kprobe kp = {
        .symbol_name = "oplus_adfr_set_min_fps_attr",
    };

    if (min_fps < 1 || min_fps > 120)
        return -ERANGE;

    // Dynamically locate oplus_adfr_set_min_fps_attr address
    ret = register_kprobe(&kp);
    if (ret) {
        pr_err("rmx5010_ltpo_restore: register_kprobe for oplus_adfr_set_min_fps_attr failed: %d\n", ret);
        return ret;
    }
    oplus_set_min_fps = (set_min_fps_fn)kp.addr;
    unregister_kprobe(&kp);

    if (!oplus_set_min_fps) {
        pr_err("rmx5010_ltpo_restore: failed to resolve oplus_adfr_set_min_fps_attr\n");
        return -ENOENT;
    }

    ret = register_kretprobe(&ltpo_reset_probe);
    if (ret) {
        pr_err("rmx5010_ltpo_restore: register_kretprobe for oplus_adfr_status_reset failed: %d\n", ret);
        return ret;
    }

    if (apply_on_load)
        mod_delayed_work(system_unbound_wq, &ltpo_restore_work, 0);

    pr_info("rmx5010_ltpo_restore: active, min_fps=%u delay_ms=%u\n",
            min_fps, (delay_ms > 5000) ? 5000 : delay_ms);
    return 0;
}

static void __exit rmx5010_ltpo_exit(void)
{
    unregister_kretprobe(&ltpo_reset_probe);
    cancel_delayed_work_sync(&ltpo_restore_work);
    pr_info("rmx5010_ltpo_restore: stopped, events=%lld writes=%lld last_error=%d\n",
            (long long)atomic64_read(&reset_events),
            (long long)atomic64_read(&successful_writes),
            last_error);
}

module_init(rmx5010_ltpo_init);
module_exit(rmx5010_ltpo_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("KevinXu07");
MODULE_DESCRIPTION("Event-driven Realme GT7 Pro (RMX5010) ADFR min_fps restore helper");
MODULE_VERSION("0.1.0");
