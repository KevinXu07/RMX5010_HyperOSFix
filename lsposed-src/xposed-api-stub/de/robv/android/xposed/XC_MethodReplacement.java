package de.robv.android.xposed;

/** Compile-time stub: LSPosed provides the real implementation at runtime. */
public abstract class XC_MethodReplacement extends XC_MethodHook {
    public XC_MethodReplacement() {}
    public XC_MethodReplacement(int priority) { super(priority); }

    protected abstract Object replaceHookedMethod(MethodHookParam param) throws Throwable;

    @Override
    protected final void beforeHookedMethod(MethodHookParam param) throws Throwable {
        param.setResult(replaceHookedMethod(param));
    }

    public static XC_MethodReplacement returnConstant(final Object value) {
        return new XC_MethodReplacement() {
            @Override
            protected Object replaceHookedMethod(MethodHookParam param) {
                return value;
            }
        };
    }
}
