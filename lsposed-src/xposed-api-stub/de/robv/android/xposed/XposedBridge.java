package de.robv.android.xposed;

import java.lang.reflect.Member;
import java.util.Set;

/** Compile-time stub: LSPosed provides the real implementation at runtime. */
public final class XposedBridge {
    private XposedBridge() {}
    public static void log(String text) {}
    public static void log(Throwable t) {}
    public static Object invokeOriginalMethod(Member method, Object thisObject, Object[] args) { return null; }
    public static XC_MethodHook.Unhook hookMethod(Member hookMethod, XC_MethodHook callback) { return null; }
    public static Set<XC_MethodHook.Unhook> hookAllConstructors(Class<?> hookClass, XC_MethodHook callback) { return null; }
    public static Set<XC_MethodHook.Unhook> hookAllMethods(Class<?> hookClass, String methodName, XC_MethodHook callback) { return null; }
}
