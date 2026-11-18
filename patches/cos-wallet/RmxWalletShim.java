package com.rmx5010.walletshim;

import android.app.Activity;
import android.app.Application;
import android.app.KeyguardManager;
import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.nfc.cardemulation.CardEmulation;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.os.SystemProperties;
import android.provider.Settings;
import android.util.Log;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

/**
 * In-APK replacement for the wallet-process part of COS-WALLET-FIX (Sense's
 * local.mio.coloroswalletcompat hooks), added to FinShell / TAS / UnionPay TSM
 * as an extra classesN.dex by scripts/patch_cos_wallet.py.
 *
 * Instead of hooking framework methods, the patch script rewrites the wallet's
 * own call sites to the static methods below (same signatures plus the
 * receiver), so the behaviour is confined to these processes exactly like the
 * LSPosed version:
 *
 *  - software identity of a OnePlus 13 (Build fields and the property table);
 *  - nfc_multise_* fallback to "Embedded SE";
 *  - FinShell CardService counted as the payment default when Settings says so;
 *  - the OPlus eID bridge chosen over the Xiaomi one (privateFlags bit 20);
 *  - transit request headers carrying the OnePlus model / OTA;
 *  - FinShell activities kept over the keyguard during a lockscreen session.
 *
 * Nothing here touches the secure element, certificates or the server
 * protocol.
 */
public final class RmxWalletShim {
    private static final String TAG = "RmxWalletShim";

    static final String FIN_SHELL = "com.finshell.wallet";
    static final String CARD_SERVICE = "com.nearme.wallet.nfc.CardService";
    static final String PAYMENT_COMPONENT = FIN_SHELL + "/" + CARD_SERVICE;
    static final String EMBEDDED_SE = "Embedded SE";
    static final String MULTISE_ACTIVE = "nfc_multise_active";
    static final String MULTISE_LIST = "nfc_multise_list";
    static final String MODEL = "PJZ110";
    static final String OTA = "PJZ110_11.C.92_1920_202607071800";
    static final String TRANSIT_PATH = "nfc/transit/";
    static final String LOCKSCREEN_SESSION =
            "local.mio.coloroswalletcompat.extra.LOCKSCREEN_SESSION";
    static final String SWIPE_ACTIVITY = "com.nearme.wallet.nfc.ui.NfcConsumeActivity";
    static final long SESSION_MS = 60_000L;
    static final int PLATFORM_KEY_FLAG = 0x00100000;

    private static final Map<String, String> PROPS = new HashMap<>();

    static {
        PROPS.put("ro.product.brand", "OnePlus");
        PROPS.put("ro.product.manufacturer", "OnePlus");
        PROPS.put("ro.product.model", MODEL);
        PROPS.put("ro.product.device", "OP5D0DL1");
        PROPS.put("ro.product.name", MODEL);
        PROPS.put("ro.build.product", "OP5D0DL1");
        PROPS.put("ro.product.brand.sub", "OnePlus");
        PROPS.put("ro.product.marketname", "OnePlus 13");
        PROPS.put("ro.vendor.oplus.market.name", "OnePlus 13");
        PROPS.put("ro.vendor.oplus.market.enname", "OnePlus 13");
        PROPS.put("ro.boot.prjname", "23821");
        PROPS.put("ro.build.version.oplusrom", "V16.1.0");
        PROPS.put("ro.build.version.oplusrom.display", "16.1");
        PROPS.put("ro.build.version.ota", OTA);
        PROPS.put("persist.sys.pkwallet.support", "true");
        PROPS.put("persist.sys.oplus.region", "CN");
        PROPS.put("persist.sys.oppo.region", "CN");
        PROPS.put("ro.vendor.oplus.regionmark", "CN");
        // FinShell's built-in OnePlus ESE carrier descriptor; the local gate
        // only requires it to contain Build.BRAND.
        PROPS.put("ro.product.cuptsm", "ONEPLUS|ESE|01|02");

        setBuild("BRAND", "OnePlus");
        setBuild("MANUFACTURER", "OnePlus");
        setBuild("MODEL", MODEL);
        setBuild("DEVICE", "OP5D0DL1");
        setBuild("PRODUCT", MODEL);
    }

    private static volatile Application sApp;
    private static volatile long sSessionUntil;

    private RmxWalletShim() {}

    /** Called first in the Application class's static initialiser. */
    public static void init() {
        // The static block above does the work.
    }

    /**
     * Called first in Application.attachBaseContext, i.e. before the base
     * context is set: nothing here may use the Application as a Context yet.
     */
    public static void attach(Application app) {
        if (sApp != null || app == null) return;
        sApp = app;
        if ("com.nearme.wallet.WalletApplication".equals(app.getClass().getName())) {
            try {
                app.registerActivityLifecycleCallbacks(new LockscreenSession());
            } catch (Throwable t) {
                Log.w(TAG, "lockscreen session unavailable", t);
            }
        }
    }

    private static void setBuild(String name, String value) {
        try {
            Field f = Build.class.getField(name);
            f.setAccessible(true);
            f.set(null, value);
        } catch (Throwable t) {
            Log.w(TAG, "Build." + name + " not set", t);
        }
    }

    // ---- properties --------------------------------------------------------

    /** Spoofed value for key, or null to read the real property. */
    public static String prop(String key) {
        return key == null ? null : PROPS.get(key);
    }

    public static String get(String key) {
        String v = prop(key);
        return v != null ? v : SystemProperties.get(key);
    }

    public static String get(String key, String def) {
        String v = prop(key);
        return v != null ? v : SystemProperties.get(key, def);
    }

    public static boolean getBoolean(String key, boolean def) {
        String v = prop(key);
        if (v != null) {
            if ("true".equalsIgnoreCase(v) || "1".equals(v)) return true;
            if ("false".equalsIgnoreCase(v) || "0".equals(v)) return false;
        }
        return SystemProperties.getBoolean(key, def);
    }

    // ---- settings / NFC state ---------------------------------------------

    private static String multise(String key, String value) {
        if (!MULTISE_ACTIVE.equals(key) && !MULTISE_LIST.equals(key)) return value;
        if (value == null || value.trim().isEmpty() || "null".equals(value)) return EMBEDDED_SE;
        return value;
    }

    public static String globalGetString(ContentResolver cr, String key) {
        return multise(key, Settings.Global.getString(cr, key));
    }

    public static String systemGetString(ContentResolver cr, String key) {
        return multise(key, Settings.System.getString(cr, key));
    }

    private static boolean finShellDefaultPayment(Context context) {
        try {
            return PAYMENT_COMPONENT.equals(Settings.Secure.getString(
                    context.getContentResolver(), "nfc_payment_default_component"));
        } catch (Throwable t) {
            return false;
        }
    }

    private static boolean embeddedSeConfigured(Context context) {
        try {
            ContentResolver cr = context.getContentResolver();
            String active = Settings.Global.getString(cr, MULTISE_ACTIVE);
            if (active == null) active = Settings.System.getString(cr, MULTISE_ACTIVE);
            return active == null || active.trim().isEmpty() || "null".equals(active)
                    || EMBEDDED_SE.equals(active);
        } catch (Throwable t) {
            return false;
        }
    }

    private static Context context(Context c) {
        return c != null ? c : sApp;
    }

    /** com.nearme.nfc.e.e.d(Context): eSE is the active secure element. */
    public static boolean nfcEseActive(boolean result, Context c) {
        if (result) return true;
        Context ctx = context(c);
        return ctx != null && embeddedSeConfigured(ctx);
    }

    /** com.nearme.nfc.e.e.h(Context): FinShell is the payment default. */
    public static boolean nfcDefaultPayment(boolean result, Context c) {
        if (result) return true;
        Context ctx = context(c);
        return ctx != null && finShellDefaultPayment(ctx);
    }

    public static boolean isDefaultServiceForCategory(CardEmulation ce, ComponentName cn,
            String category) {
        if (ce.isDefaultServiceForCategory(cn, category)) return true;
        if (cn == null || (category != null && !"payment".equals(category))) return false;
        if (!FIN_SHELL.equals(cn.getPackageName()) || !CARD_SERVICE.equals(cn.getClassName())) {
            return false;
        }
        Context ctx = sApp;
        return ctx != null && finShellDefaultPayment(ctx);
    }

    // ---- eID bridge selection ---------------------------------------------

    public static int privateFlags(ApplicationInfo ai) {
        int flags = 0;
        try {
            Field f = ApplicationInfo.class.getField("privateFlags");
            flags = f.getInt(ai);
        } catch (Throwable t) {
            Log.w(TAG, "privateFlags unavailable", t);
        }
        String pkg = ai.packageName;
        if ("com.oplus.eid".equals(pkg)) return flags | PLATFORM_KEY_FLAG;
        if ("com.rongcard.eid".equals(pkg)) return flags & ~PLATFORM_KEY_FLAG;
        return flags;
    }

    // ---- transit request headers ------------------------------------------

    private static String url(Object o) {
        if (o == null) return "";
        if (o instanceof String) return (String) o;
        try {
            Method m = o.getClass().getMethod("getUrl");
            Object u = m.invoke(o);
            return u instanceof String ? (String) u : "";
        } catch (Throwable t) {
            return "";
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    public static void fixHeaders(Map headers, Object a, Object b) {
        if (headers == null) return;
        if (!url(a).contains(TRANSIT_PATH) && !url(b).contains(TRANSIT_PATH)) return;
        try {
            headers.put("--p-c-model--", MODEL);
            if (headers.get("model") instanceof String) headers.put("model", MODEL);
            headers.put("otav", OTA);
        } catch (Throwable t) {
            Log.w(TAG, "transit headers not rewritten", t);
        }
    }

    // ---- lockscreen session -----------------------------------------------

    static final class LockscreenSession implements Application.ActivityLifecycleCallbacks {
        private static void update(Activity activity) {
            Intent intent = activity.getIntent();
            long now = SystemClock.elapsedRealtime();
            try {
                if (intent != null && intent.getBooleanExtra(LOCKSCREEN_SESSION, false)) {
                    sSessionUntil = now + SESSION_MS;
                    intent.removeExtra(LOCKSCREEN_SESSION);
                    Log.i(TAG, "lockscreen wallet session started");
                }
            } catch (Throwable ignored) {
                // BadParcelableException from a foreign extra: ignore.
            }
            KeyguardManager km = activity.getSystemService(KeyguardManager.class);
            if (km == null || !km.isKeyguardLocked()) return;
            // The swipe page itself is showWhenLocked; a resume of it over the
            // keyguard also opens a session (SINGLE_TOP relaunch via
            // onNewIntent keeps the old intent).
            if (SWIPE_ACTIVITY.equals(activity.getClass().getName())) {
                sSessionUntil = Math.max(sSessionUntil, now + SESSION_MS);
            }
            if (now >= sSessionUntil) return;
            activity.setShowWhenLocked(true);
        }

        @Override public void onActivityPreCreated(Activity a, Bundle b) { update(a); }
        @Override public void onActivityCreated(Activity a, Bundle b) {}
        @Override public void onActivityStarted(Activity a) {}
        @Override public void onActivityPreResumed(Activity a) { update(a); }
        @Override public void onActivityResumed(Activity a) {}
        @Override public void onActivityPaused(Activity a) {}
        @Override public void onActivityStopped(Activity a) {}
        @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
        @Override public void onActivityDestroyed(Activity a) {}
    }
}
