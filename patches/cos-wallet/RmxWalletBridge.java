package com.android.server;

import android.app.AppOpsManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Binder;
import android.os.Handler;
import android.os.Looper;
import android.os.UserHandle;
import android.provider.Settings;
import android.util.Log;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;

/**
 * system_server side of the ColorOS wallet set (image version of Sense's
 * WalletRuntimePermissions, WalletFreezeExemption and the double-click power
 * wallet hooks).  Called from miui-services.jar, patched by
 * scripts/patch_miui_services_greeze.py:
 *
 *  - VibratorManagerServiceImpl.init(Context) (boot) and
 *    ShortCutActionsUtils.<init>(Context) (lazy) -> onInit: AppOps for the wallet set
 *    (MIUIOP 10008 background start for all five, 10020 show-when-locked for
 *    FinShell), re-applied on boot / unlock / package add or replace;
 *  - ShortCutActionsUtils.launchDefaultWallet() -> launchDefaultWallet: open
 *    FinShell's NFC swipe page instead of the Quick Access Wallet path that
 *    FinShell does not implement;
 *  - ShortCutActionsUtils.launchMiPay(String) -> onLaunchMiPay: the same page
 *    when FinShell is the NFC payment default, else the stock Mi Pay launch;
 *  - AurogonImmobulusMode.isNoRestrictApp / isNoRestrictFreezeable /
 *    TransfermLocalAllowList -> isWalletPackage: Greeze leaves FinShell alone
 *    so reader broadcasts are not parked until the next thaw.
 */
public final class RmxWalletBridge {
    private static final String TAG = "RmxWalletBridge";

    static final String FIN_SHELL = "com.finshell.wallet";
    static final String SWIPE_ACTIVITY = "com.nearme.wallet.nfc.ui.NfcConsumeActivity";
    static final String OPEN_ACTION = "finshell.wallet.intent.action.OPEN";
    static final String LOCKSCREEN_SESSION =
            "local.mio.coloroswalletcompat.extra.LOCKSCREEN_SESSION";
    static final String PAYMENT_COMPONENT = FIN_SHELL + "/com.nearme.wallet.nfc.CardService";
    static final List<String> WALLET_PACKAGES = Arrays.asList(
            FIN_SHELL, "com.heytap.tas", "com.unionpay.tsmservice", "com.heytap.htms",
            "com.oplus.eid");
    static final int OP_BACKGROUND_START = 10008;
    static final int OP_SHOW_WHEN_LOCKED = 10020;

    private static volatile boolean sStarted;
    private static Context sContext;
    private static Handler sHandler;
    private static final Runnable RECONCILE = new Runnable() {
        @Override public void run() { reconcile(); }
    };

    private RmxWalletBridge() {}

    // ---- Greeze --------------------------------------------------------------

    public static boolean isWalletPackage(String pkg) {
        return FIN_SHELL.equals(pkg);
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    public static void addWalletToAllowList(List list) {
        try {
            if (list != null && !list.contains(FIN_SHELL)) list.add(FIN_SHELL);
        } catch (Throwable t) {
            Log.w(TAG, "allow list not extended", t);
        }
    }

    // ---- double-click power -------------------------------------------------

    private static Context context(Object utils) {
        for (String name : new String[] {"mContext", "mDefaultDisplayContext"}) {
            try {
                Field f = utils.getClass().getDeclaredField(name);
                f.setAccessible(true);
                Object v = f.get(utils);
                if (v instanceof Context) return (Context) v;
            } catch (Throwable ignored) {
                // next
            }
        }
        return sContext;
    }

    private static boolean launchSwipe(Context context) {
        if (context == null) return false;
        long token = Binder.clearCallingIdentity();
        try {
            context.getPackageManager().getPackageInfo(FIN_SHELL, 0);
            Intent intent = new Intent(OPEN_ACTION);
            intent.setComponent(new ComponentName(FIN_SHELL, SWIPE_ACTIVITY));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP
                    | Intent.FLAG_ACTIVITY_CLEAR_TOP | 0x00080000);
            intent.putExtra(LOCKSCREEN_SESSION, true);
            Method asUser = Context.class.getMethod("startActivityAsUser", Intent.class,
                    UserHandle.class);
            asUser.invoke(context, intent, UserHandle.class.getField("CURRENT").get(null));
            Log.i(TAG, "double-click power -> " + FIN_SHELL + "/" + SWIPE_ACTIVITY);
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "wallet swipe page launch failed", t);
            return false;
        } finally {
            Binder.restoreCallingIdentity(token);
        }
    }

    public static boolean launchDefaultWallet(Object utils) {
        return launchSwipe(context(utils));
    }

    /** -1: run the stock Mi Pay launch; 0/1: handled. */
    public static int onLaunchMiPay(Object utils, String reason) {
        Context context = context(utils);
        if (context == null) return -1;
        try {
            String component = Settings.Secure.getString(context.getContentResolver(),
                    "nfc_payment_default_component");
            if (!PAYMENT_COMPONENT.equals(component)) return -1;
        } catch (Throwable t) {
            return -1;
        }
        return launchSwipe(context) ? 1 : -1;
    }

    // ---- AppOps -------------------------------------------------------------

    public static void onInit(Context context) {
        if (sStarted || context == null) return;
        sStarted = true;
        sContext = context;
        sHandler = new Handler(Looper.getMainLooper());
        sHandler.postDelayed(new Runnable() {
            int tries;

            @Override public void run() {
                try {
                    register();
                } catch (Throwable t) {
                    if (++tries < 120) {
                        sHandler.postDelayed(this, 1000);
                    } else {
                        Log.w(TAG, "wallet receivers not registered", t);
                    }
                    return;
                }
                sHandler.postDelayed(RECONCILE, 20_000);
            }
        }, 1000);
    }

    private static void register() {
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent intent) {
                if (intent.getData() != null
                        && !WALLET_PACKAGES.contains(intent.getData().getSchemeSpecificPart())) {
                    return;
                }
                sHandler.removeCallbacks(RECONCILE);
                sHandler.postDelayed(RECONCILE, 1000);
            }
        };
        IntentFilter boot = new IntentFilter();
        boot.addAction(Intent.ACTION_BOOT_COMPLETED);
        boot.addAction(Intent.ACTION_USER_UNLOCKED);
        sContext.registerReceiver(receiver, boot, null, sHandler, Context.RECEIVER_EXPORTED);
        IntentFilter pkg = new IntentFilter();
        pkg.addAction(Intent.ACTION_PACKAGE_ADDED);
        pkg.addAction(Intent.ACTION_PACKAGE_REPLACED);
        pkg.addDataScheme("package");
        sContext.registerReceiver(receiver, pkg, null, sHandler, Context.RECEIVER_EXPORTED);
    }

    private static void reconcile() {
        long token = Binder.clearCallingIdentity();
        try {
            PackageManager pm = sContext.getPackageManager();
            AppOpsManager ops = sContext.getSystemService(AppOpsManager.class);
            if (ops == null) return;
            Method opToName = AppOpsManager.class.getMethod("opToName", int.class);
            Method check = AppOpsManager.class.getMethod("checkOpNoThrow", int.class, int.class,
                    String.class);
            Method setMode = AppOpsManager.class.getMethod("setMode", int.class, int.class,
                    String.class, int.class);
            int writes = 0;
            for (String pkg : WALLET_PACKAGES) {
                ApplicationInfo info;
                try {
                    info = pm.getApplicationInfo(pkg, 0);
                } catch (PackageManager.NameNotFoundException e) {
                    continue;
                }
                int[] codes = FIN_SHELL.equals(pkg)
                        ? new int[] {OP_BACKGROUND_START, OP_SHOW_WHEN_LOCKED}
                        : new int[] {OP_BACKGROUND_START};
                for (int code : codes) {
                    try {
                        // Only MIUI's AppOpsManager knows these vendor codes.
                        Object name = opToName.invoke(null, code);
                        if (name == null || "NONE".equals(name)
                                || String.valueOf(name).startsWith("Unknown")) {
                            continue;
                        }
                        int mode = ((Number) check.invoke(ops, code, info.uid, pkg)).intValue();
                        if (mode != AppOpsManager.MODE_ALLOWED) {
                            setMode.invoke(ops, code, info.uid, pkg, AppOpsManager.MODE_ALLOWED);
                            writes++;
                        }
                    } catch (Throwable t) {
                        Log.w(TAG, "appop " + code + " for " + pkg + " not set", t);
                    }
                }
            }
            Log.i(TAG, "wallet appops reconciled, updated=" + writes);
        } catch (Throwable t) {
            Log.w(TAG, "wallet appops unavailable", t);
        } finally {
            Binder.restoreCallingIdentity(token);
        }
    }
}
