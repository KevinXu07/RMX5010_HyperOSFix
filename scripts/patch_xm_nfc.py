#!/usr/bin/env python3
"""补丁 system/app/XMNfcNci/XMNfcNci.apk：ColorOS 钱包的 NFC 服务侧（代替 COS-WALLET-FIX
在 com.android.nfc 进程里的钩子，见 patches/cos-wallet/RmxWalletNfc.java）。

插入点（编号对应 COS-WALLET-FIX docs/HOOKS.md）：
  RoutingOptionManager
    - native doGet*Destination() 的每个调用点，读出结果后交给桥修正 0x01 -> 0xC0（N01-N06）
    - getInstance() 里构造完成后 afterRoutingCtor（N08）
    - readRoutingOptionsFromPrefs 前后（N07）
    - getDefaultIsoDepRoute / getDefaultOffHostRoute 的返回值（N09/N10）
    - recoverOverridedRoutingTable 之前、overwriteRoutingTable 之后（N11/N12）
  CardEmulationManager 构造后（NfcInjector 里，N13）；AidRoutingManager 构造后
  （NfcService、RegisteredAidCache 里，N14）；AidRoutingManager.configureRouting 前后（N15）
  NfcApplication.onCreate 之后：安装选卡/路由/门卡桥和默认钱包策略（N18/N19）
  NfcDispatcher$DispatchInfo.tryStartActivity(Intent) 的返回值（N20）
  CardEmulationManager.onServicesUpdated / onWalletRoleHolderChanged / onUserSwitched 之后、
  NfcAdapterService.setTagIntentAppPreferenceForUser 之后：触发策略核对（N21-N24）
  NfcServiceHandler.sendFieldOnEvent 前后 / sendFieldOffEvent 之后：读卡器场强事件转给钱包（Sense）

方法级钩子的做法：原方法改名为 rmx$<name>（改为 private），新增同名同签名的包装方法，
在调用原方法前后调用桥。native 方法不能改名（JNI 按名字绑定），所以改调用点。

用法：
  python3 patch_xm_nfc.py <XMNfcNci.apk> <nfc-bridge.dex> <out.zip>
XMNfcNci 的 v2/v3 只有 0x0103 摘要，调用方 zipalign 后用 apk_sigblock.py splice 拼回
原签名块即可。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

B = "Lcom/android/nfc/RmxWalletNfc;"
CE = "com/android/nfc/cardemulation/"
ROM = "L%sRoutingOptionManager;" % CE


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def method_span(s, header):
    pat = re.compile(r"^" + re.escape(header) + r"$", re.M)
    found = list(pat.finditer(s))
    if len(found) != 1:
        raise SystemExit("%d x %s" % (len(found), header))
    start = found[0].start()
    end = s.index(".end method", start) + len(".end method")
    return start, end


def param_regs(desc):
    params = desc[1:desc.index(")")]
    n, i = 0, 0
    while i < len(params):
        j = i
        while params[j] == "[":
            j += 1
        if params[j] == "L":
            j = params.index(";", j)
        n += 2 if (j == i and params[j] in "JD") else 1
        i = j + 1
    return n


def wrap(s, cls, header, before="", after="", locals_=2):
    """Rename the method to rmx$<name> (private) and add a same-signature
    wrapper: <before>; call original; <after>; return.  In before/after the
    original's result (if any) is v0; v1.. are free locals."""
    m = re.match(r"^\.method ([a-z\- ]*?)\s*(\w+)(\(.*\))(\S+)$", header)
    if not m:
        raise SystemExit("bad header " + header)
    flags, name, params, ret = m.groups()
    flags = flags.split()
    static = "static" in flags
    start, end = method_span(s, header)
    body = s[start:end]
    if "rmx$" in body:
        raise SystemExit("already wrapped: " + header)
    keep = [f for f in flags if f in ("static", "declared-synchronized", "synchronized", "final")]
    renamed = ".method %s rmx$%s%s%s" % (" ".join(["private"] + keep), name, params, ret)
    orig = body.replace(header, renamed, 1)
    n = param_regs(params + "V") + (0 if static else 1)
    if n:
        inv = "invoke-%s/range {p0 .. p%d}" % ("static" if static else "direct", n - 1)
    else:
        inv = "invoke-static {}"
    call = "    %s, L%s;->rmx$%s%s%s\n" % (inv, cls, name, params, ret)
    if ret == "V":
        res, rtn = "", "    return-void"
    elif ret[0] in "L[":
        res, rtn = "    move-result-object v0\n", "    return-object v0"
    elif ret in ("J", "D"):
        raise SystemExit("wide return not supported: " + header)
    else:
        res, rtn = "    move-result v0\n", "    return v0"
    wrapper = ("%s\n    .registers %d\n\n    # RMX5010: ColorOS wallet (was COS-WALLET-FIX)\n%s%s%s%s%s\n"
               ".end method" % (header, n + locals_, before, call, res, after, rtn))
    return s[:start] + orig + "\n\n" + wrapper + s[end:]


def after_new(s, owner, what, bridge_method, expect):
    """After `invoke-direct {vX...}, L<owner>;-><init>(...)V` insert
    RmxWalletNfc.<bridge_method>(vX)."""
    pat = re.compile(r"^(\s*)invoke-direct(?:/range)? \{(\w+)(?:[^}]*)\}, L%s;-><init>\([^)]*\)V\n"
                     % re.escape(owner), re.M)
    count = [0]

    def rep(m):
        count[0] += 1
        return (m.group(0) + "\n%s# RMX5010: ColorOS wallet (%s)\n"
                "%sinvoke-static/range {%s .. %s}, %s->%s(Ljava/lang/Object;)V\n"
                % (m.group(1), what, m.group(1), m.group(2), m.group(2), B, bridge_method))
    s = pat.sub(rep, s)
    if count[0] != expect:
        raise SystemExit("%s: %d construction sites, expected %d" % (what, count[0], expect))
    return s


NATIVE = {
    "doGetOffHostEseDestination": ("[B", "onOffHostEse"),
    "doGetDefaultRouteDestination": ("I", "onNativeRoute"),
    "doGetDefaultIsoDepRouteDestination": ("I", "onNativeIsoDep"),
    "doGetDefaultOffHostRouteDestination": ("I", "onNativeOffHost"),
    "doGetDefaultFelicaRouteDestination": ("I", "onNativeFelica"),
    "doGetDefaultScRouteDestination": ("I", "onNativeRoute"),
}


def patch_routing(s):
    count = [0]
    pat = re.compile(r"^(\s*)invoke-virtual \{(\w+)\}, %s->(doGet\w+Destination)\(\)(I|\[B)\n\n"
                     r"\s*(move-result(?:-object)?) (\w+)\n" % re.escape(ROM), re.M)

    def rep(m):
        ind, _, name, ret, mr, reg = m.groups()
        if name not in NATIVE:
            return m.group(0)
        count[0] += 1
        _, fn = NATIVE[name]
        return (m.group(0) + "\n%s# RMX5010: ColorOS eSE route (was COS-WALLET-FIX)\n"
                "%sinvoke-static/range {%s .. %s}, %s->%s(%s)%s\n\n%s%s %s\n"
                % (ind, ind, reg, reg, B, fn, ret, ret, ind, mr, reg))
    s = pat.sub(rep, s)
    if count[0] != 10:
        raise SystemExit("RoutingOptionManager: %d native route call sites, expected 10" % count[0])
    s = after_new(s, CE + "RoutingOptionManager", "routing singleton", "afterRoutingCtor", 1)
    cls = CE + "RoutingOptionManager"
    s = wrap(s, cls, ".method public readRoutingOptionsFromPrefs(Landroid/content/Context;"
             "Lcom/android/nfc/DeviceConfigFacade;)V",
             before="    invoke-static {p0}, %s->beforeReadPrefs(Ljava/lang/Object;)V\n" % B,
             after="    invoke-static {p0, p1}, %s->afterReadPrefs(Ljava/lang/Object;"
                   "Landroid/content/Context;)V\n" % B)
    for name in ("getDefaultIsoDepRoute", "getDefaultOffHostRoute"):
        s = wrap(s, cls, ".method public %s()I" % name,
                 after="    invoke-static {v0}, %s->onDefaultRoute(I)I\n\n    move-result v0\n" % B)
    s = wrap(s, cls, ".method public recoverOverridedRoutingTable()V",
             before="    invoke-static {}, %s->onRoutingTableChange()V\n" % B)
    s = wrap(s, cls, ".method public overwriteRoutingTable()V",
             after="    invoke-static {}, %s->onRoutingTableChange()V\n" % B)
    return s


def patch_aid_routing(s):
    return wrap(s, CE + "AidRoutingManager",
                ".method public configureRouting(Ljava/util/HashMap;ZZ)I",
                before="    invoke-static {p0}, %s->beforeConfigureRouting(Ljava/lang/Object;)V\n" % B,
                after="    invoke-static {}, %s->afterConfigureRouting()V\n" % B)


def patch_card_emulation(s):
    cls = CE + "CardEmulationManager"
    for header, name in (
            (".method public onServicesUpdated(ILjava/util/List;Z)V", "onServicesUpdated"),
            (".method public onWalletRoleHolderChanged(Ljava/lang/String;I)V",
             "onWalletRoleHolderChanged"),
            (".method public onUserSwitched(I)V", "onUserSwitched")):
        s = wrap(s, cls, header, after=(
            '    const-string v1, "%s"\n\n'
            "    invoke-static {v1}, %s->onCardEmulationEvent(Ljava/lang/String;)V\n" % (name, B)))
    return s


def patch_injector(s):
    return after_new(s, CE + "CardEmulationManager", "card emulation manager",
                     "afterCardEmulationCtor", 1)


def patch_service(s):
    return after_new(s, CE + "AidRoutingManager", "aid routing manager", "afterAidRoutingCtor", 1)


def patch_aid_cache(s):
    return after_new(s, CE + "AidRoutingManager", "aid routing manager", "afterAidRoutingCtor", 1)


def patch_application(s):
    return wrap(s, "com/android/nfc/NfcApplication", ".method public onCreate()V",
                after="    invoke-static {}, %s->afterApplicationCreate()V\n" % B)


def patch_dispatch(s):
    return wrap(s, "com/android/nfc/NfcDispatcher$DispatchInfo",
                ".method tryStartActivity(Landroid/content/Intent;)Z",
                after="    invoke-static {p0, p1, v0}, %s->afterTryStartActivity(Ljava/lang/Object;"
                      "Landroid/content/Intent;Z)Z\n\n    move-result v0\n" % B)


def patch_adapter(s):
    return wrap(s, "com/android/nfc/NfcService$NfcAdapterService",
                ".method public setTagIntentAppPreferenceForUser(ILjava/lang/String;Z)I",
                after="    invoke-static {p1, p2, v0}, %s->afterTagPreference(ILjava/lang/String;I)V\n" % B)


def patch_handler(s):
    cls = "com/android/nfc/NfcService$NfcServiceHandler"
    s = wrap(s, cls, ".method private sendFieldOnEvent()V",
             before="    invoke-static {p0}, %s->beforeFieldOn(Ljava/lang/Object;)Z\n\n"
                    "    move-result v1\n" % B,
             after="    invoke-static {p0, v1}, %s->afterFieldOn(Ljava/lang/Object;Z)V\n" % B)
    return wrap(s, cls, ".method private sendFieldOffEvent()V",
                after="    invoke-static {p0}, %s->afterFieldOff(Ljava/lang/Object;)V\n" % B)


PATCHES = [
    (CE + "RoutingOptionManager.smali", patch_routing),
    (CE + "AidRoutingManager.smali", patch_aid_routing),
    (CE + "CardEmulationManager.smali", patch_card_emulation),
    (CE + "RegisteredAidCache.smali", patch_aid_cache),
    ("com/android/nfc/NfcInjector.smali", patch_injector),
    ("com/android/nfc/NfcService.smali", patch_service),
    ("com/android/nfc/NfcApplication.smali", patch_application),
    ("com/android/nfc/NfcDispatcher$DispatchInfo.smali", patch_dispatch),
    ("com/android/nfc/NfcService$NfcAdapterService.smali", patch_adapter),
    ("com/android/nfc/NfcService$NfcServiceHandler.smali", patch_handler),
]


def main(src, bridge_dex, out):
    work = tempfile.mkdtemp(prefix="xm_nfc_")
    with zipfile.ZipFile(src) as z:
        dexes = [n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)]
        if dexes != ["classes.dex"]:
            raise SystemExit("expected a single classes.dex, got %s" % dexes)
        open(os.path.join(work, "classes.dex"), "wb").write(z.read("classes.dex"))
    sd = os.path.join(work, "smali")
    run(["baksmali", "d", os.path.join(work, "classes.dex"), "-o", sd, "--api", "33"])
    for rel, fn in PATCHES:
        p = os.path.join(sd, rel)
        s = open(p, encoding="utf-8").read()
        open(p, "w", encoding="utf-8").write(fn(s))
        print("patched", rel)
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
