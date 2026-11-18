#!/usr/bin/env python3
"""补丁 system/app/SecureElement/SecureElement.apk：给原签名的 ColorOS 钱包开 eSE 特权通道。

背景（docs/ColorOS钱包_RMX5010移植.md、COS-WALLET-FIX 的
hookSecureElementOplusAccessFallback）：ColorOS 的 SecureElement 在
GlobalPlatform 访问规则之外有 OPlus 的回退判断，本机的小米 / AOSP
SecureElement 没有，FinShell / TAS 的原签名证书会被拒。

AccessControlEnforcer.setUpChannelAccess([B String [B Z) 开头：
    if (RmxSeBridge.isTrustedWallet(pkg))
        return ChannelAccess.getPrivilegeAccess(pkg, Binder.getCallingPid());
包名和 PackageManager 里的签名证书都必须与原版钱包一致（见
patches/cos-wallet/RmxSeBridge.java），其余调用者走原逻辑。

用法：
  python3 patch_secure_element.py <SecureElement.apk> <se-bridge.dex> <out.zip>
输出没有签名块；SecureElement 的 v2/v3 只有 0x0103 摘要（没有记录长度的 verity
摘要），调用方 zipalign 后用 scripts/apk_sigblock.py splice 拼回原签名块即可，
并删除同目录的 oat。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

ENFORCER = "com/android/se/security/AccessControlEnforcer.smali"
HEADER = ".method public setUpChannelAccess([BLjava/lang/String;[BZ)Lcom/android/se/security/ChannelAccess;"
BRIDGE = "Lcom/android/se/RmxSeBridge;"


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def patch(s):
    start = s.index(HEADER + "\n")
    end = s.index(".end method", start)
    body = s[start:end]
    if "RmxSeBridge" in body:
        raise SystemExit("already patched")
    m = re.search(r"^    \.registers (\d+)\n", body, re.M)
    if not m or int(m.group(1)) < 7:
        raise SystemExit("setUpChannelAccess: unexpected register count")
    code = ("    # RMX5010: OPlus eSE fallback for the original ColorOS wallet signers\n"
            "    invoke-static {p2}, %s->isTrustedWallet(Ljava/lang/String;)Z\n\n"
            "    move-result v0\n\n"
            "    if-eqz v0, :rmx_se_stock\n\n"
            "    invoke-static {}, Landroid/os/Binder;->getCallingPid()I\n\n"
            "    move-result v0\n\n"
            "    invoke-static {p2, v0}, Lcom/android/se/security/ChannelAccess;->getPrivilegeAccess"
            "(Ljava/lang/String;I)Lcom/android/se/security/ChannelAccess;\n\n"
            "    move-result-object v0\n\n"
            "    return-object v0\n\n"
            "    :rmx_se_stock\n" % BRIDGE)
    i = m.end()
    body = body[:i] + "\n" + code + body[i:]
    return s[:start] + body + s[end:]


def main(src, bridge_dex, out):
    work = tempfile.mkdtemp(prefix="secure_element_")
    with zipfile.ZipFile(src) as z:
        dexes = [n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)]
        if dexes != ["classes.dex"]:
            raise SystemExit("expected a single classes.dex, got %s" % dexes)
        open(os.path.join(work, "classes.dex"), "wb").write(z.read("classes.dex"))
    sd = os.path.join(work, "smali")
    run(["baksmali", "d", os.path.join(work, "classes.dex"), "-o", sd, "--api", "33"])
    p = os.path.join(sd, ENFORCER)
    s = open(p, encoding="utf-8").read()
    open(p, "w", encoding="utf-8").write(patch(s))
    new = os.path.join(work, "classes.patched")
    run(["smali", "a", sd, "-o", new, "--api", "33"])
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
        last = None
        for zi in zin.infolist():
            data = open(new, "rb").read() if zi.filename == "classes.dex" else zin.read(zi.filename)
            zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
            zi2.compress_type = zi.compress_type
            zi2.external_attr = zi.external_attr
            zi2.internal_attr = zi.internal_attr
            zi2.create_system = zi.create_system
            zout.writestr(zi2, data)
            last = zi
        zi2 = zipfile.ZipInfo("classes2.dex", last.date_time)
        zi2.compress_type = zipfile.ZIP_DEFLATED
        zi2.external_attr = 0o100644 << 16
        zi2.create_system = last.create_system
        zout.writestr(zi2, open(bridge_dex, "rb").read())
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
