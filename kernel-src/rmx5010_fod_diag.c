// SPDX-License-Identifier: GPL-2.0
/* Minimal diagnostic: kprobe on a vmlinux symbol + input device registration.
 * If this loads, the crash is in touching module symbols; if it panics too,
 * the problem is in our module build itself. */
#include <linux/input.h>
#include <linux/kprobes.h>
#include <linux/module.h>

static struct input_dev *diag_input;

static int __init fod_diag_init(void)
{
	struct kprobe kp = { .symbol_name = "_printk" };
	void *addr;
	int ret;

	ret = register_kprobe(&kp);
	if (ret) {
		pr_info("fod_diag: kprobe _printk failed: %d\n", ret);
		return ret;
	}
	addr = kp.addr;
	unregister_kprobe(&kp);
	pr_info("fod_diag: _printk resolved at %px\n", addr);

	diag_input = input_allocate_device();
	if (!diag_input)
		return -ENOMEM;
	diag_input->name = "rmx5010_fod_diag";
	diag_input->id.bustype = BUS_HOST;
	input_set_capability(diag_input, EV_KEY, KEY_F5);
	ret = input_register_device(diag_input);
	if (ret) {
		input_free_device(diag_input);
		return ret;
	}
	pr_info("fod_diag: input device registered OK\n");
	return 0;
}

static void __exit fod_diag_exit(void)
{
	if (diag_input)
		input_unregister_device(diag_input);
	pr_info("fod_diag: exited\n");
}

module_init(fod_diag_init);
module_exit(fod_diag_exit);
MODULE_LICENSE("GPL");
