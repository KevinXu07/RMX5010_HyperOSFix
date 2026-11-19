#!/usr/bin/env python3
"""补丁 product/app/MITSMClient/MITSMClient.apk（小米 TSM）：FinShell 是默认支付时不抢前台。

代替 COS-WALLET-FIX 在 com.miui.tsmclient 进程里的两个钩子（见
patches/cos-wallet/RmxWalletTsm.java）：
  - NfcEventMonitorService 里的 Context/ContextWrapper.startActivity(Intent) 调用点改为
    RmxWalletTsm.startActivity(context, intent)：小米 TSM 收到 NFC 自动事件
    （RF_ON / TRANSACTION / SMART_SELECT_CARD）时拉起 DoubleClickActivity 的那一次被丢弃；
  - DoubleClickActivity.onCreate 之后 RmxWalletTsm.afterDoubleClickCreate：
    自动事件兜底关闭，用户点进来的交通卡快捷入口改为打开 FinShell 卡包。
FinShell 不是默认支付时两处都走小米原逻辑。
原 APK 的 dex 不压缩存放；重新汇编的 dex 没有共享代码块，体积大约 40%，所以改过的 dex
改为 deflate 存放（系统应用照常由 ART 解出编译），未改的 dex 原样保留。

用法：
  python3 patch_tsmclient.py <MITSMClient.apk> <tsm-bridge.dex> <out.zip>
MITSMClient 的 v2/v3 只有 0x0103 摘要，调用方 zipalign 后用 apk_sigblock.py splice
拼回原签名块即可。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

B = "Lcom/miui/tsmclient/RmxWalletTsm;"
DCA = "com/miui/tsmclient/ui/quick/DoubleClickActivity"
MONITOR = "com/miui/tsmclient/service/NfcEventMonitorService"
CALL = re.compile(r"^(\s*)invoke-virtual \{(\w+), (\w+)\}, Landroid/content/(?:Context|ContextWrapper);"
                  r"->startActivity\(Landroid/content/Intent;\)V$", re.M)


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def wrap_on_create(s):
    header = ".method protected onCreate(Landroid/os/Bundle;)V"
    pat = re.compile(r"^" + re.escape(header) + r"$", re.M)
    found = list(pat.finditer(s))
    if len(found) != 1:
        raise SystemExit("DoubleClickActivity.onCreate not found exactly once")
    start = found[0].start()
    end = s.index(".end method", start) + len(".end method")
    orig = s[start:end].replace(header, ".method private rmx$onCreate(Landroid/os/Bundle;)V", 1)
    wrapper = (header + "\n    .registers 2\n\n"
               "    # RMX5010: ColorOS wallet (was COS-WALLET-FIX)\n"
               "    invoke-direct {p0, p1}, L%s;->rmx$onCreate(Landroid/os/Bundle;)V\n\n"
               "    invoke-static {p0}, %s->afterDoubleClickCreate(Landroid/app/Activity;)V\n\n"
               "    return-void\n.end method" % (DCA, B))
    return s[:start] + orig + "\n\n" + wrapper + s[end:]


def main(src, bridge_dex, out):
    work = tempfile.mkdtemp(prefix="tsmclient_")
    with zipfile.ZipFile(src) as z:
        dexes = sorted((n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)),
                       key=lambda n: int(n[7:-4] or 1))
        datas = {n: z.read(n) for n in dexes}
    calls, wrapped, new_dex = 0, 0, {}
    for name in dexes:
        data = datas[name]
        if ("L%s;" % DCA).encode() not in data and ("L%s;" % MONITOR).encode() not in data:
            continue
        p = os.path.join(work, name)
        open(p, "wb").write(data)
        sd = p + ".smali"
        run(["baksmali", "d", p, "-o", sd, "--api", "33"])
        changed = False
        for dp, _, fns in os.walk(sd):
            for fn in fns:
                if not fn.endswith(".smali"):
                    continue
                fp = os.path.join(dp, fn)
                s = open(fp, encoding="utf-8").read()
                rel = os.path.relpath(fp, sd)[:-6].replace(os.sep, "/")
                # Only the NFC event service launches DoubleClickActivity for
                # automatic RF/HCI events; leave every other caller alone.
                if not rel.startswith(MONITOR):
                    n, t = 0, s
                else:
                    n = len(CALL.findall(s))
                    t = CALL.sub(lambda m: "%sinvoke-static {%s, %s}, %s->startActivity("
                             "Landroid/content/Context;Landroid/content/Intent;)V"
                                 % (m.group(1), m.group(2), m.group(3), B), s)
                calls += n
                if rel == DCA:
                    t = wrap_on_create(t)
                    wrapped += 1
                if t != s:
                    open(fp, "w", encoding="utf-8").write(t)
                    changed = True
        if changed:
            new_dex[name] = p + ".patched"
            run(["smali", "a", sd, "-o", new_dex[name], "--api", "33"])
    print("startActivity call sites:", calls, "DoubleClickActivity wrapped:", wrapped)
    if wrapped != 1 or calls == 0:
        raise SystemExit("patch points missing")
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
        last = None
        for zi in zin.infolist():
            data = open(new_dex[zi.filename], "rb").read() if zi.filename in new_dex \
                else zin.read(zi.filename)
            zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
            # The stock dex files are stored; a smali-reassembled dex is ~40%
            # larger (no shared code items), so store the patched one deflated.
            zi2.compress_type = zipfile.ZIP_DEFLATED if zi.filename in new_dex else zi.compress_type
            zi2.external_attr = zi.external_attr
            zi2.internal_attr = zi.internal_attr
            zi2.create_system = zi.create_system
            zout.writestr(zi2, data)
            last = zi
        name = "classes%d.dex" % (len(dexes) + 1)
        zi2 = zipfile.ZipInfo(name, last.date_time)
        zi2.compress_type = zipfile.ZIP_DEFLATED
        zi2.external_attr = 0o100644 << 16
        zi2.create_system = last.create_system
        zout.writestr(zi2, open(bridge_dex, "rb").read())
        print("added", name)
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
