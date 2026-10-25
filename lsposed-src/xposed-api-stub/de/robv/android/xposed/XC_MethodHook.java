package de.robv.android.xposed;

import java.lang.reflect.Member;

/** Compile-time stub: LSPosed provides the real implementation at runtime. */
public abstract class XC_MethodHook {
    public static final int PRIORITY_HIGHEST = 10000;
    public static final int PRIORITY_DEFAULT = 50;
    public static final int PRIORITY_LOWEST = -10000;

    public XC_MethodHook() {}
    public XC_MethodHook(int priority) {}

    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {}
    protected void afterHookedMethod(MethodHookParam param) throws Throwable {}

    public static final class MethodHookParam {
        public Object thisObject;
        public Object[] args;
        public Object getResult() { return null; }
        public void setResult(Object result) {}
        public Throwable getThrowable() { return null; }
        public void setThrowable(Throwable throwable) {}
        public Object getObjectExtra(String key) { return null; }
        public void setObjectExtra(String key, Object value) {}
    }

    public class Unhook {
        public Member getHookedMethod() { return null; }
        public void unhook() {}
    }
}
