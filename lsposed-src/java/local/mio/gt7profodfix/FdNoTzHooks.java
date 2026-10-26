package local.mio.gt7profodfix;

import android.content.Context;

import java.lang.reflect.Method;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;

/**
 * RMX5010 没有可用的小米 TZ/cardapp 凭证，FindDevice 的
 * SecurityDeviceCredentialService 仍会走 DeviceCredentialTZ，导致
 * 小爱/ASR 请求拿不到 fid/sign（DeviceSignInterceptor 打印 deviceId=null）。
 * 这里把 TZ 门面委托给现有的 NoTZ 软件凭证（/mnt/vendor/persist/fdsd/dc），
 * 保持 dx.i.e()==TZ 的判断不变，只替换凭证方法本身。
 */
final class FdNoTzHooks {
    private static final String TZ_CLASS = "com.xiaomi.finddevice.v2.DeviceCredentialTZ";
    private static final String NOTZ_CLASS = "com.xiaomi.finddevice.v2.DeviceCredentialManagerNoTZ";
    private static final String CRED_IFACE = "com.xiaomi.finddevice.v2.IDeviceCredential";

    private static ClassLoader sLoader;
    private static volatile Object sCredential;

    private FdNoTzHooks() {
    }

    static void install(ClassLoader loader) {
        sLoader = loader;
        Class<?> tz;
        try {
            tz = XposedHelpers.findClass(TZ_CLASS, loader);
        } catch (Throwable error) {
            HookLog.error("FdNoTz: TZ class missing", error);
            return;
        }
        if (tz == null) {
            HookLog.info("FdNoTz: TZ class missing");
            return;
        }

        hookString(tz, "getFId", "getFId");
        hookString(tz, "getHost", "getHost");
        hookString(tz, "getOwnUserId", "getOwnUserId");

        XposedBridge.hookAllMethods(tz, "isProvisioned", new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                param.setResult(credential() != null);
            }
        });

        XposedBridge.hookAllMethods(tz, "sign", new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                Object credential = credential();
                if (credential == null || param.args == null || param.args.length == 0) {
                    param.setResult(null);
                    return;
                }
                param.setResult(invoke(credential, "sign",
                        new Class<?>[]{byte[].class}, param.args[0]));
            }
        });

        XposedBridge.hookAllMethods(tz, "provision", new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                param.setResult(true);
            }
        });

        HookLog.info("FdNoTz: hooks installed");
    }

    private static void hookString(Class<?> tz, String method, String credentialMethod) {
        XposedBridge.hookAllMethods(tz, method, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                Object credential = credential();
                param.setResult(credential == null
                        ? null : invoke(credential, credentialMethod, new Class<?>[0]));
            }
        });
    }

    private static Object credential() {
        Object cached = sCredential;
        if (cached != null) {
            return cached;
        }
        synchronized (FdNoTzHooks.class) {
            if (sCredential != null) {
                return sCredential;
            }
            try {
                Context context = currentApplication();
                if (context == null) {
                    HookLog.once("fd_no_context", "FdNoTz: context unavailable");
                    return null;
                }
                Class<?> managerClass = XposedHelpers.findClass(NOTZ_CLASS, sLoader);
                if (managerClass == null) {
                    HookLog.once("fd_no_notz", "FdNoTz: NoTZ class missing");
                    return null;
                }
                Object manager = managerClass.getConstructor(Context.class).newInstance(context);
                Object credential = managerClass.getMethod("get", Context.class)
                        .invoke(manager, context);
                if (credential == null) {
                    HookLog.once("fd_credential_null", "FdNoTz: NoTZ credential is null");
                    return null;
                }
                sCredential = credential;
                HookLog.info("FdNoTz: credential loaded " + credential.getClass().getName());
                return credential;
            } catch (Throwable error) {
                HookLog.error("FdNoTz: credential load failed", error);
                return null;
            }
        }
    }

    private static Object invoke(Object credential, String method, Class<?>[] types,
                                 Object... args) {
        try {
            Class<?> iface = XposedHelpers.findClass(CRED_IFACE, sLoader);
            Method target = iface.getMethod(method, types);
            return target.invoke(credential, args);
        } catch (Throwable error) {
            HookLog.error("FdNoTz: invoke " + method + " failed", error);
            return null;
        }
    }

    private static Context currentApplication() {
        try {
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object application = activityThread.getMethod("currentApplication").invoke(null);
            return application instanceof Context ? (Context) application : null;
        } catch (Throwable error) {
            return null;
        }
    }
}
