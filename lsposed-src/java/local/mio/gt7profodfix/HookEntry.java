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
        } else if ("com.miui.securitycenter".equals(param.packageName)
                || "com.miui.securitymanager".equals(param.packageName)) {
            HookLog.info("SecurityCenter entry, installing MiCharge/battery-time hooks");
            try {
                MiChargeHooks.install(param.packageName, param.processName,
                        param.classLoader);
            } catch (Throwable error) {
                HookLog.error("MiCharge hook installation failed", error);
            }
        } else if ("org.ifaa.aidl.manager".equals(param.packageName)) {
            HookLog.info("IFAA entry, installing fingerprint payment hooks");
            try {
                IfaaHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("IFAA hook installation failed", error);
            }
        } else if ("com.android.settings".equals(param.packageName)) {
            HookLog.info("Settings entry, exposing stock pickup switch");
            try {
                SettingsHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("Settings hook installation failed", error);
            }
        } else if ("com.android.bluetooth".equals(param.packageName)) {
            HookLog.info("Bluetooth entry, installing LHDC V5 bridge");
            try {
                BluetoothHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("Bluetooth LHDC hook installation failed", error);
            }
        } else if ("com.oplus.camera".equals(param.packageName)) {
            HookLog.info("OplusCamera entry, installing slow-video surface hooks");
            try {
                CameraSlowMotionHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("OplusCamera slow-video hook installation failed", error);
            }
            try {
                CameraProModeHooks.install(param.classLoader);
            } catch (Throwable error) {
                HookLog.error("OplusCamera professional-mode hook installation failed", error);
            }
        }
    }
}
