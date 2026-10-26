package local.mio.gt7profodfix;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public final class HookEntry implements IXposedHookLoadPackage {
    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam param) {
        boolean systemServer = "android".equals(param.processName)
                && ("android".equals(param.packageName) || "system".equals(param.packageName));
        if (systemServer) {
            HookLog.info("system_server entry via pkg=" + param.packageName);
            try {
                SystemServerHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("system_server hook installation failed", error);
            }
        } else if ("com.android.systemui".equals(param.packageName)) {
            try {
                SystemUiHooks.install(param.classLoader, param.processName);
            } catch (Throwable error) {
                HookLog.error("SystemUI hook installation failed", error);
            }
        } else if ("com.xiaomi.finddevice".equals(param.packageName)) {
            HookLog.info("finddevice entry, installing NoTZ credential hooks");
            try {
                FdNoTzHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("finddevice hook installation failed", error);
            }
        }
    }
}
