#!/usr/bin/env python3
"""补丁 ColorOS 钱包套件（FinShell / TAS / 银联 TSM），代替 COS-WALLET-FIX 在钱包进程里的钩子。

背景（docs/ColorOS钱包_RMX5010移植.md、docs/模块改动入镜像可行性.md §4.10）：
  钱包进程里的兼容原来由 Sense 的 local.mio.coloroswalletcompat 钩子完成。
  这些 APK 不会从商店更新，所以直接改 dex：把框架调用点改成调用
  patches/cos-wallet/RmxWalletShim.java（com.rmx5010.walletshim.RmxWalletShim），
  再改几个钱包自己的判断方法。shim 由 scripts/build_cos_wallet_shim.sh 编译，
  作为下一个空闲的 classesN.dex 加入。

所有 APK：
  - Application 类 <clinit> 开头 Shim.init()（Build 伪装成一加 13），
    attachBaseContext 开头 Shim.attach(this)；
  - SystemProperties.get/get/getBoolean 调用点 → Shim 同名方法（一加 13 属性表）；
  - Settings.Global/System.getString → Shim（nfc_multise_* 空值补 "Embedded SE"）；
  - CardEmulation.isDefaultServiceForCategory → Shim（Settings 默认组件是 FinShell 时为真）；
  - ApplicationInfo.privateFlags 读取 → Shim（选 OPlus eID 桥）。
反射读属性的辅助方法（FinShell/TAS 的 com.finshell.common.d.e/g.b，银联的
  com.unionpay.tsm.utils.a.a、com.unionpay.mobile.android.utils.h.a）：
  先查 Shim 属性表，命中直接返回。
FinShell / TAS（每个包的点位见 PER_PACKAGE，全部必须存在；TAS 没有 ba.a）：
  - com.finshell.common.util.i：c() → false，d()/e() → true（厂商判断）；
  - BaseActivityLifecycleCallbacks.showForbidRunDialog → 直接返回；
  - com.nearme.utils.ba.a()、com.nearme.nfc.e.e.m()、com.nearme.nfc.e.f.a() → true；
  - com.nearme.nfc.e.e.d()/h() → 原结果为假时按 eSE / 默认支付设置补真；
FinShell：
  - com.finshell.unfreeze.c.a() → false（走空的解冻管理器，不需要 oplus-fwk）；
  - com.nearme.network.header.d/b 返回请求头的 a(...) → 交通卡接口改写机型 / OTA。

用法：
  python3 patch_cos_wallet.py <in.apk> <shim.dex> <out.zip>
输出没有签名块；调用方用 scripts/apk_repack.py 拼回原签名块，并把内容补齐到原长度
（钱包 APK 的 v2/v3 签名带 VERITY_CHUNKED_SHA256 摘要，记录了内容长度，长度一变
开机收集证书就失败，包会被直接跳过）。
需要 PATH 里有 baksmali / smali。
"""
import os
import re
import subprocess
import sys
import tempfile
import zipfile

SHIM = "Lcom/rmx5010/walletshim/RmxWalletShim;"
API = "30"

# ---- call-site rewrites (every class) ---------------------------------------
SP = "Landroid/os/SystemProperties;"
CALLS = [
    (SP + "->get(Ljava/lang/String;)Ljava/lang/String;",
     SHIM + "->get(Ljava/lang/String;)Ljava/lang/String;"),
    (SP + "->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
     SHIM + "->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"),
    (SP + "->getBoolean(Ljava/lang/String;Z)Z",
     SHIM + "->getBoolean(Ljava/lang/String;Z)Z"),
    ("Landroid/provider/Settings$Global;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;",
     SHIM + "->globalGetString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;"),
    ("Landroid/provider/Settings$System;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;",
     SHIM + "->systemGetString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;"),
]
STATIC_CALL = re.compile(r"^(\s*)invoke-static(/range)? \{([^}]*)\}, (\S+)$", re.M)
CE_CALL = re.compile(
    r"^(\s*)invoke-virtual(/range)? \{([^}]*)\}, "
    r"Landroid/nfc/cardemulation/CardEmulation;->isDefaultServiceForCategory"
    r"\(Landroid/content/ComponentName;Ljava/lang/String;\)Z$", re.M)
CE_SHIM = (SHIM + "->isDefaultServiceForCategory(Landroid/nfc/cardemulation/CardEmulation;"
           "Landroid/content/ComponentName;Ljava/lang/String;)Z")
PF_IGET = re.compile(
    r"^(\s*)iget ([vp]\d+), ([vp]\d+), Landroid/content/pm/ApplicationInfo;->privateFlags:I$", re.M)
PF_SHIM = SHIM + "->privateFlags(Landroid/content/pm/ApplicationInfo;)I"
NEEDLES = [SP.encode(), b"Landroid/provider/Settings$Global;", b"Landroid/provider/Settings$System;",
           b"isDefaultServiceForCategory", b"privateFlags"]


def rewrite_calls(s, counts):
    def static(m):
        target = m.group(4)
        for old, new in CALLS:
            if target == old:
                counts[old.split("->")[1].split("(")[0] + "@" + old.split(";")[0]] += 1
                return "%sinvoke-static%s {%s}, %s" % (m.group(1), m.group(2) or "", m.group(3), new)
        return m.group(0)
    s = STATIC_CALL.sub(static, s)

    def ce(m):
        counts["isDefaultServiceForCategory"] += 1
        return "%sinvoke-static%s {%s}, %s" % (m.group(1), m.group(2) or "", m.group(3), CE_SHIM)
    s = CE_CALL.sub(ce, s)

    def pf(m):
        counts["privateFlags"] += 1
        ind, dst, obj = m.groups()
        return ("%sinvoke-static/range {%s .. %s}, %s\n\n%smove-result %s"
                % (ind, obj, obj, PF_SHIM, ind, dst))
    return PF_IGET.sub(pf, s)


# ---- method helpers ----------------------------------------------------------
def method_span(s, header):
    """(start, end) of the method whose header line is exactly `header`."""
    pat = re.compile(r"^" + re.escape(header) + r"$", re.M)
    found = list(pat.finditer(s))
    if len(found) != 1:
        raise LookupError("%d x %s" % (len(found), header))
    start = found[0].start()
    end = s.index(".end method", start) + len(".end method")
    return start, end


def find_method(s, name, desc):
    """Header line of method `name` with descriptor `desc`, any access flags."""
    pat = re.compile(r"^\.method [a-z ]*\b" + re.escape(name + desc) + r"$", re.M)
    found = pat.findall(s)
    if len(found) != 1:
        raise LookupError("%d x %s%s" % (len(found), name, desc))
    return found[0]


def first_code_offset(body):
    """Offset in body of the first instruction/label line (after .registers,
    .param and annotations)."""
    depth = 0
    off = 0
    lines = body.splitlines(True)
    for i, line in enumerate(lines):
        st = line.strip()
        if i == 0:
            off += len(line)
            continue
        if st.startswith(".annotation"):
            depth += 1
        elif st.startswith(".end annotation"):
            depth -= 1
        elif depth == 0 and st and not st.startswith(".") and not st.startswith("#"):
            return off
        off += len(line)
    raise LookupError("no code in method")


def insert_at_start(s, header, code):
    start, end = method_span(s, header)
    body = s[start:end]
    if "RmxWalletShim;" in body:
        raise SystemExit("already patched: " + header)
    i = first_code_offset(body)
    body = body[:i] + "    # RMX5010 wallet shim\n" + code + "\n" + body[i:]
    return s[:start] + body + s[end:]


def registers(body):
    m = re.search(r"^\s*\.(registers|locals) (\d+)$", body, re.M)
    return int(m.group(2)) if m else 0


def replace_body(s, header, code):
    start, end = method_span(s, header)
    body = s[start:end]
    n = max(registers(body), 1)
    new = "%s\n    .registers %d\n\n    # RMX5010 wallet shim\n%s\n.end method" % (header, n, code)
    return s[:start] + new + s[end:]


def const_return(value):
    return lambda s, header: replace_body(
        s, header, "    const/4 v0, 0x%d\n\n    return v0" % value)


def void_return(s, header):
    return replace_body(s, header, "    return-void")


def param_regs(desc):
    params = desc[1:desc.index(")")]
    regs, i = [], 0
    while i < len(params):
        c = params[i]
        j = i
        while params[j] == "[":
            j += 1
        if params[j] == "L":
            j = params.index(";", j)
        regs.append(2 if (params[j] in "JD" and j == i) else 1)
        i = j + 1
    return sum(regs)


def wrap_static(cls, after):
    """Rename the static method to rmx$<name> and add a wrapper with the
    original name that calls it, then `after(result_reg, nparam)` code."""
    def patch(s, header):
        m = re.match(r"^\.method ([a-z ]*)\b(\w+)(\(.*)$", header)
        flags, name, desc = m.groups()
        if "static" not in flags.split():
            raise SystemExit("wrap_static on non-static " + header)
        start, end = method_span(s, header)
        orig = s[start:end].replace(header, ".method private static rmx$%s%s" % (name, desc), 1)
        n = param_regs(desc)
        ret = desc[desc.index(")") + 1:]
        obj = ret.startswith("L") or ret.startswith("[")
        move = "move-result-object" if obj else "move-result"
        args = "{p0 .. p%d}" % (n - 1) if n else "{}"
        inv = "invoke-static/range" if n else "invoke-static"
        code = ("    %s %s, %s->rmx$%s%s\n\n    %s v0\n\n%s\n\n    return%s v0"
                % (inv, args, cls, name, desc, move, after(n), "-object" if obj else ""))
        wrapper = "%s\n    .registers %d\n\n    # RMX5010 wallet shim\n%s\n.end method" % (
            header, n + 1, code)
        return s[:start] + orig + "\n\n" + wrapper + s[end:]
    return patch


def bool_wrap(shim_method):
    # (Z result, Context p0) -> Z
    return lambda n: ("    invoke-static {v0, p0}, %s->%s(ZLandroid/content/Context;)Z\n\n"
                      "    move-result v0" % (SHIM, shim_method))


def header_wrap(n):
    a = "p0"
    b = "p1" if n > 1 else "p0"
    return ("    invoke-static {v0, %s, %s}, %s->fixHeaders(Ljava/util/Map;Ljava/lang/Object;"
            "Ljava/lang/Object;)V" % (a, b, SHIM))


# (class smali path, method name, descriptor, patch fn, required for FinShell)
GATES = [
    ("com/finshell/common/util/i", "c", "(Landroid/content/Context;)Z", const_return(0)),
    ("com/finshell/common/util/i", "d", "(Landroid/content/Context;)Z", const_return(1)),
    ("com/finshell/common/util/i", "e", "(Landroid/content/Context;)Z", const_return(1)),
    ("com/nearme/common/lib/BaseActivityLifecycleCallbacks", "showForbidRunDialog",
     "(Landroid/content/Context;)V", void_return),
    ("com/nearme/utils/ba", "a", "()Z", const_return(1)),
    ("com/nearme/nfc/e/e", "m", "(Landroid/content/Context;)Z", const_return(1)),
    ("com/nearme/nfc/e/f", "a", "()Z", const_return(1)),
    ("com/nearme/nfc/e/e", "d", "(Landroid/content/Context;)Z",
     wrap_static("Lcom/nearme/nfc/e/e;", bool_wrap("nfcEseActive"))),
    ("com/nearme/nfc/e/e", "h", "(Landroid/content/Context;)Z",
     wrap_static("Lcom/nearme/nfc/e/e;", bool_wrap("nfcDefaultPayment"))),
]
FIN_SHELL_ONLY = [
    ("com/finshell/unfreeze/c", "a", "()Z", const_return(0)),
    ("com/nearme/network/header/d", "a", "(Lcom/nearme/network/internal/c;)Ljava/util/HashMap;",
     wrap_static("Lcom/nearme/network/header/d;", header_wrap)),
    ("com/nearme/network/header/d", "a",
     "(Lcom/nearme/network/internal/c;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)"
     "Ljava/util/HashMap;", wrap_static("Lcom/nearme/network/header/d;", header_wrap)),
    ("com/nearme/network/header/b", "a", "(Ljava/lang/String;Lcom/nearme/network/internal/c;)"
     "Ljava/util/HashMap;", wrap_static("Lcom/nearme/network/header/b;", header_wrap)),
]


def prop_wrap(cls):
    """Static String helper(key, ...) that reads a system property through
    reflection: return the shim's spoofed value for key, else call the
    original (renamed rmx$<name>)."""
    def patch(s, header):
        m = re.match(r"^\.method ([a-z ]*)\b(\w+)(\(.*)$", header)
        flags, name, desc = m.groups()
        if "static" not in flags.split() or not desc.startswith("(Ljava/lang/String;") \
                or not desc.endswith(")Ljava/lang/String;"):
            raise SystemExit("prop_wrap: unexpected " + header)
        start, end = method_span(s, header)
        orig = s[start:end].replace(header, ".method private static rmx$%s%s" % (name, desc), 1)
        n = param_regs(desc)
        code = ("    invoke-static {p0}, %s->prop(Ljava/lang/String;)Ljava/lang/String;\n\n"
                "    move-result-object v0\n\n    if-nez v0, :rmx_prop_done\n\n"
                "    invoke-static/range {p0 .. p%d}, %s->rmx$%s%s\n\n"
                "    move-result-object v0\n\n    :rmx_prop_done\n    return-object v0"
                % (SHIM, n - 1, cls, name, desc))
        wrapper = "%s\n    .registers %d\n\n    # RMX5010 wallet shim\n%s\n.end method" % (
            header, n + 1, code)
        return s[:start] + orig + "\n\n" + wrapper + s[end:]
    return patch


# FinShell / TAS read properties through these reflection helpers
# (com.finshell.common.util.ag.b -> d.e.b or d.g.b).
FINSHELL_PROPS = [
    ("com/finshell/common/d/e", "b",
     "(Ljava/lang/String;Ljava/lang/String;Lcom/finshell/common/d/d;)Ljava/lang/String;",
     prop_wrap("Lcom/finshell/common/d/e;")),
    ("com/finshell/common/d/g", "b",
     "(Ljava/lang/String;Ljava/lang/String;Lcom/finshell/common/d/d;)Ljava/lang/String;",
     prop_wrap("Lcom/finshell/common/d/g;")),
]
UNIONPAY_PROPS = [
    ("com/unionpay/tsm/utils/a", "a", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
     prop_wrap("Lcom/unionpay/tsm/utils/a;")),
    ("com/unionpay/mobile/android/utils/h", "a",
     "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
     prop_wrap("Lcom/unionpay/mobile/android/utils/h;")),
]
# Per package: every listed point must exist.  TAS bundles the same vendor /
# NFC classes as FinShell except com.nearme.utils.ba (a different class there).
PER_PACKAGE = {
    "FinShellWallet": GATES + FIN_SHELL_ONLY + FINSHELL_PROPS,
    "TasWallet": [g for g in GATES if g[0] != "com/nearme/utils/ba"] + FINSHELL_PROPS,
    "UPTsmService": UNIONPAY_PROPS,
}


def app_patch(s, cls_desc):
    """Shim.init() in <clinit>, Shim.attach(this) in attachBaseContext."""
    init = "    invoke-static {}, %s->init()V\n" % SHIM
    try:
        s = insert_at_start(s, ".method static constructor <clinit>()V", init)
    except LookupError:
        s += ("\n.method static constructor <clinit>()V\n    .registers 0\n\n"
              "    # RMX5010 wallet shim\n%s\n    return-void\n.end method\n" % init)
    attach = "    invoke-static {p0}, %s->attach(Landroid/app/Application;)V\n" % SHIM
    try:
        header = find_method(s, "attachBaseContext", "(Landroid/content/Context;)V")
        s = insert_at_start(s, header, attach)
    except LookupError:
        sup = re.search(r"^\.super (\S+)$", s, re.M).group(1)
        s += ("\n.method protected attachBaseContext(Landroid/content/Context;)V\n"
              "    .registers 2\n\n    # RMX5010 wallet shim\n%s\n"
              "    invoke-super {p0, p1}, %s->attachBaseContext(Landroid/content/Context;)V\n\n"
              "    return-void\n.end method\n" % (attach, sup))
    return s


def application_class(apk):
    out = subprocess.run(["aapt2", "dump", "xmltree", "--file", "AndroidManifest.xml", apk],
                         check=True, capture_output=True, text=True).stdout
    i = out.index("E: application")
    m = re.search(r'android:name\(0x01010003\)="([^"]+)"', out[i:])
    return m.group(1)


def run(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main(src, shim_dex, out, app_class=None):
    base = os.path.basename(src)[:-len(".apk")]
    if base not in PER_PACKAGE:
        raise SystemExit("unknown wallet APK %s (expected one of %s)" % (base, sorted(PER_PACKAGE)))
    work = tempfile.mkdtemp(prefix="cos_wallet_")
    if app_class is None:
        app_class = application_class(src)
    app_rel = app_class.replace(".", "/")
    method_patches = list(PER_PACKAGE[base])
    wanted = {app_rel} | {c for c, *_ in method_patches}

    with zipfile.ZipFile(src) as z:
        dexes = sorted((n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)),
                       key=lambda n: int(n[7:-4] or 1))
        datas = {n: z.read(n) for n in dexes}

    owner = {}
    todo = []
    for name in dexes:
        data = datas[name]
        hit = any(x in data for x in NEEDLES)
        defs = set()
        if any(("L%s;" % c).encode() in data for c in wanted):
            p = os.path.join(work, name)
            open(p, "wb").write(data)
            listing = set(subprocess.run(["baksmali", "list", "classes", p], check=True,
                                         capture_output=True, text=True).stdout.split())
            defs = {c for c in wanted if "L%s;" % c in listing}
            for c in defs:
                owner[c] = name
        if hit or defs:
            todo.append(name)
    if app_rel not in owner:
        raise SystemExit("application class %s not found" % app_class)

    from collections import Counter
    counts = Counter()
    applied = []
    new_dex = {}
    for name in todo:
        p = os.path.join(work, name)
        open(p, "wb").write(datas[name])
        sd = p + ".smali"
        # No debug info: smali output without .line/.local is smaller than
        # the original dex, which leaves room to pad the APK back to its
        # original length (scripts/apk_repack.py).
        run(["baksmali", "d", p, "-o", sd, "--api", API, "--debug-info", "false"])
        changed = False
        for dp, _, fns in os.walk(sd):
            for fn in fns:
                if not fn.endswith(".smali"):
                    continue
                fp = os.path.join(dp, fn)
                s = open(fp, encoding="utf-8").read()
                t = rewrite_calls(s, counts)
                rel = os.path.relpath(fp, sd)[:-6].replace(os.sep, "/")
                if rel == app_rel:
                    t = app_patch(t, "L%s;" % rel)
                    applied.append(rel + " <clinit>/attachBaseContext")
                for c, mname, desc, fn_ in method_patches:
                    if c != rel:
                        continue
                    header = find_method(t, mname, desc)
                    t = fn_(t, header)
                    applied.append("%s.%s%s" % (c, mname, desc))
                if t != s:
                    open(fp, "w", encoding="utf-8").write(t)
                    changed = True
        if changed:
            new_dex[name] = p + ".patched"
            run(["smali", "a", sd, "-o", new_dex[name], "--api", API])

    expected = ["%s.%s%s" % (c, m, d) for c, m, d, _ in method_patches]
    missing = [e for e in expected if e not in applied]
    print("call sites:", dict(counts))
    print("method patches:", len(applied))
    for a in applied:
        print("  ", a)
    if missing:
        raise SystemExit("patch points not found in %s: %s" % (base, missing))

    # Fresh ZipInfo per entry (as patch_settings.py): reusing the source
    # entries carries their extra fields (zipalign padding) and flag bits
    # (data descriptor) over, and PackageManager then silently drops the
    # package at boot even though the app itself still runs.
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w") as zout:
        last = None
        for zi in zin.infolist():
            data = open(new_dex[zi.filename], "rb").read() if zi.filename in new_dex \
                else zin.read(zi.filename)
            zi2 = zipfile.ZipInfo(zi.filename, zi.date_time)
            zi2.compress_type = zi.compress_type
            zi2.external_attr = zi.external_attr
            zi2.internal_attr = zi.internal_attr
            zi2.create_system = zi.create_system
            zout.writestr(zi2, data)
            last = zi
        name = "classes%d.dex" % (len(dexes) + 1)
        if name in zin.namelist():
            raise SystemExit(name + " already exists")
        zi2 = zipfile.ZipInfo(name, last.date_time)
        zi2.compress_type = zipfile.ZIP_DEFLATED
        zi2.external_attr = 0o100644 << 16
        zi2.create_system = last.create_system
        zout.writestr(zi2, open(shim_dex, "rb").read())
        print("added", name)
    print("output", out, os.path.getsize(out))


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
