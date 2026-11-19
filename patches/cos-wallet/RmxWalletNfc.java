package com.android.nfc;

import android.app.role.RoleManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.database.ContentObserver;
import android.net.Uri;
import android.nfc.NfcAdapter;
import android.os.BatteryManager;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Parcel;
import android.os.SystemClock;
import android.os.UserHandle;
import android.os.UserManager;
import android.provider.Settings;
import android.util.Log;
import android.widget.Toast;

import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/**
 * NFC-service side of the ColorOS wallet set: a Java port of the
 * com.android.nfc part of COS-WALLET-FIX / Sense (HookEntry's routing,
 * access-card bridge and tech-chooser hooks, FixedWalletPolicy, and Sense's
 * reader-field forwarding) for system/app/XMNfcNci.
 *
 * scripts/patch_xm_nfc.py calls the static on/after/before methods below from
 * the exact places the LSPosed hooks used to run (N01-N24 in
 * COS-WALLET-FIX docs/HOOKS.md):
 *   - RoutingOptionManager native doGet*Destination call sites (N01-N06);
 *   - RoutingOptionManager.readRoutingOptionsFromPrefs before/after (N07);
 *   - after every RoutingOptionManager / CardEmulationManager /
 *     AidRoutingManager construction (N08, N13, N14);
 *   - getDefaultIsoDepRoute / getDefaultOffHostRoute results (N09, N10);
 *   - recoverOverridedRoutingTable before, overwriteRoutingTable after (N11, N12);
 *   - AidRoutingManager.configureRouting before/after (N15);
 *   - NfcApplication.onCreate after: bridge install (N18/N19);
 *   - NfcDispatcher$DispatchInfo.tryStartActivity(Intent) after (N20);
 *   - CardEmulationManager.onServicesUpdated / onWalletRoleHolderChanged /
 *     onUserSwitched after, NfcAdapterService.setTagIntentAppPreferenceForUser
 *     after (N21-N24, the wallet policy triggers);
 *   - NfcServiceHandler.sendFieldOnEvent / sendFieldOffEvent (Sense).
 * N16/N17 (ApduServiceInfo is a boot-classpath class) are covered by the
 * policy's persistent setOffHostForService, as in the module.
 * Everything is event-driven; nothing here polls.
 */
public final class RmxWalletNfc {
    static final String TAG = "ColorOSWalletCompat";
    static final String NFC_PACKAGE = "com.android.nfc";
    static final String FIN_SHELL = "com.finshell.wallet";
    static final String CARD_SERVICE = "com.nearme.wallet.nfc.CardService";
    static final String PAYMENT_COMPONENT = FIN_SHELL + "/" + CARD_SERVICE;
    static final String EMBEDDED_SE = "Embedded SE";
    static final String EVENT_PERMISSION = "oplus.permission.OPLUS_COMPONENT_SAFE";
    static final String ACTION_UPDATE_CITY_CONFIG = "com.nfc.action.UPDATE_CITY_CONFIG";
    static final String ACTION_ENTER_SWIPE_PAGE = "com.nfc.action.ENTER_SWIPE_PAGE";
    static final String ACTION_UPDATE_SMART_CARD_MANAGER = "com.nfc.action.UPDATE_SMART_CARD_MANAGER";
    static final String ACTION_RECONCILE_NFC = "local.mio.coloroswalletcompat.action.RECONCILE_NFC";
    static final String ACTION_RF_FIELD_ON = "com.android.nfc_extras.action.RF_FIELD_ON_DETECTED";
    static final String ACTION_RF_FIELD_OFF = "com.android.nfc_extras.action.RF_FIELD_OFF_DETECTED";
    static final String ACCESS_CARD_TYPE = "accesscard";
    static final String EID_CARD_TYPE = "eidcard";
    static final String ACCESS_CARD_AID_PREFIX = "A0000003964D344D1061707056434D";
    static final String BRIDGE_PREFS = "coloros_wallet_compat_nfc";
    static final long BRIDGE_TIMEOUT_MS = 10 * 60 * 1000L;
    static final String NXP_TRANSIT_SERVICE = "vendor.nxp.nxpnfc_aidl.INxpNfc/default";
    static final String NXP_TRANSIT_DESCRIPTOR = "vendor.nxp.nxpnfc_aidl.INxpNfc";
    static final int NXP_SET_TRANSIT_CONFIG_TRANSACTION = 3;
    static final int STALE_XIAOMI_ESE_ROUTE = 0x01;
    /** RMX5010's SN220 reports its eSE as NFCEE 0xC0 (same as OnePlus 13). */
    static final int ESE_NFCEE_ID = 0xC0;

    private static final Object LOCK = new Object();
    static volatile boolean sBridgeInstalled;
    static volatile Object sRoutingManager;
    static volatile Object sAidRoutingManager;
    static volatile Object sCardEmulationManager;
    static volatile Context sRoutingContext;
    static volatile Boolean sCompat;
    static volatile Integer sOrigIsoDep;
    static volatile Integer sOrigOffHost;
    static volatile Integer sOrigFelica;
    static volatile Integer sEseRoute;
    static volatile AccessCardBridge sBridge;
    // Sense reader-field forwarding state.
    static volatile boolean sForwardedOn;
    static volatile long sLastOnLog;

    private RmxWalletNfc() {}

    static void log(String msg) { Log.i(TAG, msg); }

    static void log(String msg, Throwable t) { Log.w(TAG, msg, t); }

    // =========================================================== reflection

    static Field findField(Class<?> c, String name) throws NoSuchFieldException {
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try {
                Field f = k.getDeclaredField(name);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
                // superclass
            }
        }
        throw new NoSuchFieldException(c.getName() + "#" + name);
    }

    static boolean hasField(Object o, String name) {
        try {
            findField(o.getClass(), name);
            return true;
        } catch (NoSuchFieldException e) {
            return false;
        }
    }

    static Object get(Object o, String name) throws Exception {
        return findField(o.getClass(), name).get(o);
    }

    static int getInt(Object o, String name) throws Exception {
        return findField(o.getClass(), name).getInt(o);
    }

    static void setInt(Object o, String name, int v) throws Exception {
        findField(o.getClass(), name).setInt(o, v);
    }

    static boolean getBool(Object o, String name) throws Exception {
        return findField(o.getClass(), name).getBoolean(o);
    }

    static void setBool(Object o, String name, boolean v) throws Exception {
        findField(o.getClass(), name).setBoolean(o, v);
    }

    static Object getStatic(Class<?> c, String name) throws Exception {
        return findField(c, name).get(null);
    }

    private static Class<?> box(Class<?> t) {
        if (!t.isPrimitive()) return t;
        if (t == int.class) return Integer.class;
        if (t == boolean.class) return Boolean.class;
        if (t == long.class) return Long.class;
        if (t == byte.class) return Byte.class;
        if (t == short.class) return Short.class;
        if (t == char.class) return Character.class;
        if (t == float.class) return Float.class;
        if (t == double.class) return Double.class;
        return Void.class;
    }

    private static boolean matches(Class<?>[] types, Object[] args) {
        if (types.length != args.length) return false;
        for (int i = 0; i < types.length; i++) {
            if (args[i] == null) {
                if (types[i].isPrimitive()) return false;
            } else if (!box(types[i]).isInstance(args[i])) {
                return false;
            }
        }
        return true;
    }

    /** XposedHelpers.callMethod equivalent: first compatible method by name. */
    static Object call(Object target, String name, Object... args) throws Exception {
        boolean isStatic = target instanceof Class;
        Class<?> c = isStatic ? (Class<?>) target : target.getClass();
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            for (Method m : k.getDeclaredMethods()) {
                if (m.getName().equals(name) && matches(m.getParameterTypes(), args)) {
                    m.setAccessible(true);
                    try {
                        return m.invoke(isStatic ? null : target, args);
                    } catch (java.lang.reflect.InvocationTargetException e) {
                        Throwable cause = e.getCause();
                        if (cause instanceof Exception) throw (Exception) cause;
                        throw e;
                    }
                }
            }
        }
        throw new NoSuchMethodException(c.getName() + "#" + name + Arrays.toString(args));
    }

    /** Exact primitive signature, as the module's callExactMethod. */
    static Object callExact(Object target, String name, Class<?>[] types, Object... args)
            throws Exception {
        for (Class<?> k = target.getClass(); k != null; k = k.getSuperclass()) {
            for (Method m : k.getDeclaredMethods()) {
                if (m.getName().equals(name) && Arrays.equals(m.getParameterTypes(), types)) {
                    m.setAccessible(true);
                    try {
                        return m.invoke(target, args);
                    } catch (java.lang.reflect.InvocationTargetException e) {
                        Throwable cause = e.getCause();
                        if (cause instanceof Exception) throw (Exception) cause;
                        throw e;
                    }
                }
            }
        }
        throw new NoSuchMethodException(target.getClass().getName() + "#" + name);
    }

    static Object newInstance(Class<?> c, Object... args) throws Exception {
        for (Constructor<?> k : c.getDeclaredConstructors()) {
            if (matches(k.getParameterTypes(), args)) {
                k.setAccessible(true);
                return k.newInstance(args);
            }
        }
        throw new NoSuchMethodException(c.getName() + ".<init>");
    }

    static Context currentApplication() {
        Context c = sRoutingContext;
        if (c != null) return c;
        try {
            return (Context) Class.forName("android.app.ActivityThread")
                    .getMethod("currentApplication").invoke(null);
        } catch (Throwable t) {
            return null;
        }
    }

    static UserHandle owner() {
        try {
            return (UserHandle) UserHandle.class.getMethod("of", int.class).invoke(null, 0);
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }

    static Object currentUser() throws Exception {
        return UserHandle.class.getField("CURRENT").get(null);
    }

    // ===================================================== routing (N01-N15)

    /** N01: doGetOffHostEseDestination() result. */
    public static byte[] onOffHostEse(byte[] routes) {
        if (routes == null || routes.length == 0) return new byte[] {(byte) ESE_NFCEE_ID};
        for (int i = 0; i < routes.length; i++) {
            if ((routes[i] & 0xff) == STALE_XIAOMI_ESE_ROUTE) routes[i] = (byte) ESE_NFCEE_ID;
        }
        return routes;
    }

    private static int translate(int route) {
        return route == STALE_XIAOMI_ESE_ROUTE ? ESE_NFCEE_ID : route;
    }

    /** N02 / N06: doGetDefaultRouteDestination(), doGetDefaultScRouteDestination(). */
    public static int onNativeRoute(int route) {
        return translate(route);
    }

    /** N03: doGetDefaultIsoDepRouteDestination(). */
    public static int onNativeIsoDep(int route) {
        synchronized (LOCK) {
            if (sOrigIsoDep == null) sOrigIsoDep = route;
        }
        return translate(route);
    }

    /** N04: doGetDefaultOffHostRouteDestination(). */
    public static int onNativeOffHost(int route) {
        synchronized (LOCK) {
            if (sOrigOffHost == null) sOrigOffHost = route;
        }
        return translate(route);
    }

    /** N05: doGetDefaultFelicaRouteDestination(). */
    public static int onNativeFelica(int route) {
        synchronized (LOCK) {
            if (sOrigFelica == null) sOrigFelica = route;
        }
        return translate(route);
    }

    /** N07 before. */
    public static void beforeReadPrefs(Object manager) {
        patchEseIdentity(manager);
    }

    /** N07 after. */
    public static void afterReadPrefs(Object manager, Context context) {
        try {
            patchEseIdentity(manager);
            Object r = call(manager, "getRouteForSecureElement", "eSE1");
            int eseRoute = r instanceof Number ? ((Number) r).intValue() : -1;
            if (eseRoute <= 0) {
                log("eSE1 route unavailable; leaving platform routing unchanged");
                return;
            }
            synchronized (LOCK) {
                sRoutingManager = manager;
                sEseRoute = eseRoute;
                if (context != null) sRoutingContext = context;
            }
            sCompat = true;
            patchRoutingObjects(true);
            log("routing defaults captured iso=" + sOrigIsoDep + ", offhost=" + sOrigOffHost
                    + ", felica=" + sOrigFelica + ", eSE=" + eseRoute);
        } catch (Throwable t) {
            log("routing prefs hook failed", t);
        }
    }

    /** N08: after RoutingOptionManager construction. */
    public static void afterRoutingCtor(Object manager) {
        if (manager == null) return;
        try {
            synchronized (LOCK) {
                sRoutingManager = manager;
                sEseRoute = ESE_NFCEE_ID;
                if (sOrigIsoDep == null) sOrigIsoDep = getInt(manager, "mDefaultIsoDepRoute");
                if (sOrigOffHost == null) sOrigOffHost = getInt(manager, "mDefaultOffHostRoute");
                if (sOrigFelica == null) sOrigFelica = getInt(manager, "mDefaultFelicaRoute");
                sCompat = true;
            }
            patchEseIdentity(manager);
            patchRoutingObjects(true);
            log("routing singleton captured iso=" + sOrigIsoDep + ", offhost=" + sOrigOffHost
                    + ", felica=" + sOrigFelica + ", eSE=" + ESE_NFCEE_ID);
        } catch (Throwable t) {
            log("routing singleton capture failed", t);
        }
    }

    /** N09 / N10: getDefaultIsoDepRoute(), getDefaultOffHostRoute() results. */
    public static int onDefaultRoute(int route) {
        if (!Boolean.TRUE.equals(sCompat)) return route;
        Integer ese = sEseRoute;
        return ese != null && ese > 0 ? ese : route;
    }

    /** N11 before recoverOverridedRoutingTable, N12 after overwriteRoutingTable. */
    public static void onRoutingTableChange() {
        sCompat = true;
        patchRoutingObjects(true);
    }

    /** N13: after CardEmulationManager construction. */
    public static void afterCardEmulationCtor(Object cem) {
        if (cem == null) return;
        sCardEmulationManager = cem;
        try {
            Object c = get(cem, "mContext");
            if (c instanceof Context) {
                sRoutingContext = (Context) c;
                sCompat = true;
            }
        } catch (Throwable ignored) {
            // no context field
        }
        patchEseArray(cem);
        patchRoutingObjects(Boolean.TRUE.equals(sCompat));
    }

    /** N14: after AidRoutingManager construction. */
    public static void afterAidRoutingCtor(Object manager) {
        if (manager == null) return;
        sAidRoutingManager = manager;
        patchEseArray(manager);
        sCompat = true;
        patchRoutingObjects(true);
        log("AidRoutingManager follows live ColorOS route");
    }

    /** N15 before. */
    public static void beforeConfigureRouting(Object manager) {
        sAidRoutingManager = manager;
        sCompat = true;
        patchRoutingObjects(true);
    }

    /** N15 after. */
    public static void afterConfigureRouting() {
        patchRoutingObjects(Boolean.TRUE.equals(sCompat));
    }

    static void patchEseIdentity(Object manager) {
        if (manager == null) return;
        patchEseArray(manager);
        try {
            @SuppressWarnings("unchecked")
            Map<Object, Object> routeForSe = (Map<Object, Object>) get(manager, "mRouteForSecureElement");
            @SuppressWarnings("unchecked")
            Map<Object, Object> seForRoute = (Map<Object, Object>) get(manager, "mSecureElementForRoute");
            if (routeForSe != null && seForRoute != null) {
                Object prev = routeForSe.get("eSE1");
                routeForSe.put("eSE1", ESE_NFCEE_ID);
                if (prev instanceof Number && ((Number) prev).intValue() != ESE_NFCEE_ID
                        && "eSE1".equals(seForRoute.get(((Number) prev).intValue()))) {
                    seForRoute.remove(((Number) prev).intValue());
                }
                seForRoute.put(ESE_NFCEE_ID, "eSE1");
            }
        } catch (Throwable t) {
            log("failed to repair eSE route lookup tables", t);
        }
        for (String f : new String[] {"mDefaultRoute", "mDefaultIsoDepRoute",
                "mDefaultOffHostRoute", "mDefaultFelicaRoute", "mDefaultScRoute",
                "mOverrideDefaultRoute", "mOverrideDefaultIsoDepRoute",
                "mOverrideDefaultOffHostRoute", "mOverrideDefaultFelicaRoute",
                "mOverrideDefaultScRoute"}) {
            translateField(manager, f);
        }
    }

    static void patchEseArray(Object owner) {
        if (owner == null || !hasField(owner, "mOffHostRouteEse")) return;
        try {
            Object v = get(owner, "mOffHostRouteEse");
            if (v instanceof byte[]) onOffHostEse((byte[]) v);
        } catch (Throwable t) {
            log("failed to repair cached eSE route array", t);
        }
    }

    static void translateField(Object owner, String name) {
        try {
            if (getInt(owner, name) == STALE_XIAOMI_ESE_ROUTE) setInt(owner, name, ESE_NFCEE_ID);
        } catch (Throwable ignored) {
            // field absent on this build
        }
    }

    static void patchRoutingObjects(boolean compat) {
        Object rm = sRoutingManager;
        if (rm == null) return;
        patchEseIdentity(rm);
        if (sCardEmulationManager != null) patchEseArray(sCardEmulationManager);
        if (sAidRoutingManager != null) patchEseArray(sAidRoutingManager);
        Integer iso = compat ? sEseRoute : sOrigIsoDep;
        Integer off = compat ? sEseRoute : sOrigOffHost;
        Integer fel = sOrigFelica;
        if (iso == null || off == null || fel == null) return;
        try {
            setInt(rm, "mDefaultIsoDepRoute", iso);
            setInt(rm, "mDefaultOffHostRoute", off);
            setInt(rm, "mDefaultFelicaRoute", fel);
            Object aid = sAidRoutingManager;
            if (aid != null) {
                translateField(aid, "mDefaultRoute");
                setInt(aid, "mDefaultIsoDepRoute", iso);
                setInt(aid, "mDefaultOffHostRoute", off);
                setInt(aid, "mDefaultFelicaRoute", fel);
            }
        } catch (Throwable t) {
            log("routing object patch failed", t);
        }
    }

    static void queueIsoDepRoute(Object nfcService, int route) throws Exception {
        try {
            callExact(nfcService, "setIsoDepProtocolRoute", new Class<?>[] {int.class}, route);
        } catch (NoSuchMethodException e) {
            callExact(nfcService, "sendMessage", new Class<?>[] {int.class, Object.class},
                    22, Integer.valueOf(route));
        }
    }

    static void queueTechnologyRoutes(Object nfcService, int offHost, int felica) throws Exception {
        callExact(nfcService, "setTechnologyABFRoute", new Class<?>[] {int.class, int.class},
                offHost, felica);
    }

    static Integer rebuildAidRouting(Object cem) throws Exception {
        Object cache = get(cem, "mAidCache");
        try {
            Object r = callExact(cache, "onRoutingOverridedOrRecovered", new Class<?>[0]);
            return r instanceof Number ? ((Number) r).intValue() : null;
        } catch (NoSuchMethodException e) {
            Object lock;
            try {
                lock = get(cache, "mLock");
            } catch (Throwable t) {
                lock = cache;
            }
            synchronized (lock) {
                Object r = callExact(cache, "updateRoutingLocked",
                        new Class<?>[] {boolean.class, boolean.class}, true, true);
                return r instanceof Number ? ((Number) r).intValue() : null;
            }
        }
    }

    // ===================================================== bridge (N18/N19)

    /** NfcApplication.onCreate after. */
    public static void afterApplicationCreate() {
        try {
            Object service = getStatic(Class.forName("com.android.nfc.NfcService"), "sService");
            if (service != null) installBridgeIfReady(service);
        } catch (Throwable t) {
            log("ColorOS access-card bridge unavailable", t);
        }
    }

    static void installBridgeIfReady(Object service) {
        synchronized (LOCK) {
            if (sBridgeInstalled) return;
            Context context;
            Handler handler;
            try {
                context = (Context) get(service, "mContext");
                handler = (Handler) get(service, "mHandler");
            } catch (Throwable t) {
                return;
            }
            if (context == null || handler == null) return;
            AccessCardBridge bridge = new AccessCardBridge(context, handler, service);
            bridge.install();
            sBridge = bridge;
            sBridgeInstalled = true;
        }
    }

    // ================================================= tech chooser (N20)

    /** NfcDispatcher$DispatchInfo.tryStartActivity(Intent) after. */
    public static boolean afterTryStartActivity(Object dispatchInfo, Intent chooser,
            boolean result) {
        if (result || chooser == null) return result;
        ComponentName component = chooser.getComponent();
        if (component == null || !NFC_PACKAGE.equals(component.getPackageName())
                || !component.getClassName().endsWith(".TechListChooserActivity")) {
            return result;
        }
        try {
            Intent root = (Intent) get(dispatchInfo, "rootIntent");
            Context context = (Context) get(dispatchInfo, "context");
            if (root == null || context == null) return result;
            root.putExtra("launchIntent", chooser);
            call(context, "startActivityAsUser", root, currentUser());
            log("resumed stock Android 17 NFC TECH chooser");
            return true;
        } catch (Throwable t) {
            log("NFC TECH chooser compatibility failed", t);
            return result;
        }
    }

    // ================================================ policy triggers (N21-N24)

    /** CardEmulationManager.onServicesUpdated / onWalletRoleHolderChanged / onUserSwitched. */
    public static void onCardEmulationEvent(String name) {
        AccessCardBridge b = sBridge;
        if (b != null) b.policy.schedule(name);
    }

    /** NfcAdapterService.setTagIntentAppPreferenceForUser(int, String, boolean) result. */
    public static void afterTagPreference(int userId, String pkg, int result) {
        if (result != 0 || userId != 0 || !FixedWalletPolicy.TAG_PREFERENCES.containsKey(pkg)) return;
        AccessCardBridge b = sBridge;
        if (b != null) b.policy.schedule("tag_preference_changed");
    }

    // ================================================ reader field (Sense)

    /** NfcServiceHandler.sendFieldOnEvent before: returns the previous mFieldOnEventSent. */
    public static boolean beforeFieldOn(Object nfcHandler) {
        try {
            Object service = get(nfcHandler, "this$0");
            boolean before = getBool(service, "mFieldOnEventSent");
            setBool(service, "mFieldOnEventSent", false);
            return before;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * HyperOS only tells a wallet about a reader when eSE is not the default
     * route; with eSE (SMX) it hands the event to Mi TSM. After the stock
     * handler ran, forward the same event to FinShell when the stock eSE branch
     * accepted it, FinShell is the payment default and the phone is not on a
     * wireless charger.
     */
    public static void afterFieldOn(Object nfcHandler, boolean sentBefore) {
        try {
            Object service = get(nfcHandler, "this$0");
            if (!getBool(service, "mFieldOnEventSent")) {
                setBool(service, "mFieldOnEventSent", sentBefore);
                return;
            }
            Class<?> feature = Class.forName("com.android.nfc.Feature");
            Object felica = call(feature, "isFelicaSupport");
            if (Boolean.TRUE.equals(felica)) return;
            int defaultSe = ((Number) call(service, "getDefaultSeSetting")).intValue();
            if (defaultSe != getInt(service, "ROUTE_ID_SMX")) return;
            if (getBool(service, "mInProvisionMode")) return;
            Context context = (Context) get(service, "mContext");
            if (!isFinShellDefaultPayment(context)) return;
            Intent battery = context.registerReceiver(null,
                    new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            int plugged = battery == null ? 0 : battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
            if (plugged == BatteryManager.BATTERY_PLUGGED_WIRELESS) return;
            sendToWallet(context, ACTION_RF_FIELD_ON);
            sForwardedOn = true;
            long now = SystemClock.elapsedRealtime();
            if (now - sLastOnLog > 2000L) {
                sLastOnLog = now;
                log("reader field forwarded to FinShell");
            }
        } catch (Throwable t) {
            log("field-on forward failed", t);
        }
    }

    /** NfcServiceHandler.sendFieldOffEvent after. */
    public static void afterFieldOff(Object nfcHandler) {
        if (!sForwardedOn) return;
        sForwardedOn = false;
        try {
            Object service = get(nfcHandler, "this$0");
            sendToWallet((Context) get(service, "mContext"), ACTION_RF_FIELD_OFF);
        } catch (Throwable t) {
            log("field-off forward failed", t);
        }
    }

    static void sendToWallet(Context context, String action) throws Exception {
        Intent intent = new Intent(action);
        intent.setPackage(FIN_SHELL);
        intent.addFlags(0x00000020 /* FLAG_INCLUDE_STOPPED_PACKAGES */
                | Intent.FLAG_RECEIVER_FOREGROUND);
        call(context, "sendBroadcastAsUser", intent, currentUser());
    }

    static boolean isFinShellDefaultPayment(Context context) {
        try {
            return PAYMENT_COMPONENT.equals(Settings.Secure.getString(
                    context.getContentResolver(), "nfc_payment_default_component"));
        } catch (Throwable t) {
            return false;
        }
    }

    // ===================================================== card bridge

    /**
     * Port of ColorOsAccessCardBridge: caches FinShell's selected card
     * (UPDATE_CITY_CONFIG), keeps the dynamic "other" AID group equal to the
     * selected AID, queues the ColorOS default routes (ISO-DEP and A/B to eSE)
     * through NfcService and, for an off-host access card, applies the
     * matching RF profile, DH85 and SAK (A11B) through the existing NXP/Xiaomi
     * interfaces, restoring the exact previous state on card change.
     */
    static final class AccessCardBridge {
        final Context context;
        final Handler handler;
        final Object nfcService;
        final SharedPreferences prefs;
        final FixedWalletPolicy policy;

        String cardType;
        String aid;
        String parameterIndex;
        boolean usingDh;
        boolean swipePage;
        long swipeStartedAt;
        boolean runtimeApplied;
        byte[] savedSak;
        Integer savedDh85;
        String savedTransitConfig;
        Boolean routingLiveCompat;
        volatile boolean fullRebuildInFlight;
        volatile Boolean fullRebuiltCompat;

        final Runnable timeoutRollback = new Runnable() {
            @Override public void run() {
                if (!swipePage) return;
                log("access-card swipe-page context expired; selected-card RF profile remains active");
                swipePage = false;
                persistPageState();
            }
        };

        final BroadcastReceiver walletReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent intent) {
                String a = intent.getAction();
                if (ACTION_UPDATE_CITY_CONFIG.equals(a)) onCardConfig(intent);
                else if (ACTION_ENTER_SWIPE_PAGE.equals(a)) onSwipePage(intent);
                else if (ACTION_UPDATE_SMART_CARD_MANAGER.equals(a)) onSmartCardEvent(intent);
                else if (ACTION_RECONCILE_NFC.equals(a)) reconcileAfterNfcReady("module_mode_change");
            }
        };

        final BroadcastReceiver systemReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent intent) {
                String a = intent.getAction();
                if (Intent.ACTION_SCREEN_OFF.equals(a)) {
                    if (swipePage) {
                        swipePage = false;
                        persistPageState();
                        handler.removeCallbacks(timeoutRollback);
                    }
                } else if (NfcAdapter.ACTION_ADAPTER_STATE_CHANGED.equals(a)) {
                    int state = intent.getIntExtra(NfcAdapter.EXTRA_ADAPTER_STATE,
                            NfcAdapter.STATE_OFF);
                    if (state == NfcAdapter.STATE_OFF) {
                        onNfcOff();
                    } else if (state == NfcAdapter.STATE_ON) {
                        reconcileAfterNfcReady("adapter_on");
                        // ADAPTER_STATE_ON can arrive before discovery is
                        // enabled; HyperOS then skips MSG_COMMIT_ROUTING.
                        handler.postDelayed(() -> reconcileAfterNfcReady("adapter_stable"), 1200L);
                    }
                }
            }
        };

        AccessCardBridge(Context context, Handler handler, Object nfcService) {
            this.context = context;
            this.handler = handler;
            this.nfcService = nfcService;
            this.prefs = context.getSharedPreferences(BRIDGE_PREFS, Context.MODE_PRIVATE);
            cardType = prefs.getString("card_type", null);
            aid = prefs.getString("aid", null);
            parameterIndex = prefs.getString("parameter_index", null);
            usingDh = prefs.getBoolean("using_dh", false);
            swipePage = prefs.getBoolean("swipe_page", false);
            swipeStartedAt = prefs.getLong("swipe_started_at", 0L);
            runtimeApplied = prefs.getBoolean("runtime_applied", false);
            savedSak = hexToBytes(prefs.getString("saved_sak", null));
            int dh = prefs.getInt("saved_dh85_mode", -1);
            savedDh85 = (dh == 0 || dh == 1) ? dh : null;
            savedTransitConfig = prefs.getString("saved_transit_config", null);
            policy = new FixedWalletPolicy(context, handler, nfcService,
                    this::reconcileAfterNfcReady);
        }

        void install() {
            try {
                policy.install();
            } catch (Throwable t) {
                log("fixed wallet policy install failed", t);
            }
            IntentFilter wallet = new IntentFilter();
            wallet.addAction(ACTION_UPDATE_CITY_CONFIG);
            wallet.addAction(ACTION_ENTER_SWIPE_PAGE);
            wallet.addAction(ACTION_UPDATE_SMART_CARD_MANAGER);
            wallet.addAction(ACTION_RECONCILE_NFC);
            context.registerReceiver(walletReceiver, wallet, EVENT_PERMISSION, handler,
                    Context.RECEIVER_EXPORTED);
            IntentFilter system = new IntentFilter();
            system.addAction(Intent.ACTION_SCREEN_OFF);
            system.addAction(NfcAdapter.ACTION_ADAPTER_STATE_CHANGED);
            context.registerReceiver(systemReceiver, system, null, handler,
                    Context.RECEIVER_EXPORTED);
            handler.postDelayed(() -> {
                hydrateSelectedCardFromGlobalSettings();
                syncSelectedWalletAidGroup("service_start");
                reconcileAfterNfcReady("service_start");
            }, 1500L);
            log("protected, event-driven ColorOS access-card bridge installed");
        }

        void onCardConfig(Intent intent) {
            String newType = intent.getStringExtra("cardType");
            if (newType == null) return;
            String newAid = intent.getStringExtra("aid");
            String newIndex = intent.getStringExtra("parameter_index");
            boolean newDh = "yes".equalsIgnoreCase(intent.getStringExtra("isUsingDH"));
            boolean changed = !newType.equals(cardType) || !eq(newAid, aid)
                    || !eq(newIndex, parameterIndex) || newDh != usingDh;
            if (changed && (runtimeApplied || savedSak != null || savedDh85 != null)) {
                deactivateRuntime("card_change");
            }
            cardType = newType;
            aid = newAid;
            parameterIndex = newIndex;
            usingDh = newDh;
            prefs.edit().putString("card_type", cardType).putString("aid", aid)
                    .putString("parameter_index", parameterIndex).putBoolean("using_dh", usingDh)
                    .apply();
            mirrorColorOsCardSettings(intent);
            boolean dynamicChanged = syncSelectedWalletAidGroup("card_config");
            if (changed && dynamicChanged && EID_CARD_TYPE.equalsIgnoreCase(cardType)) {
                showEidSwitchToast();
            }
            log("cached NFC card config type=" + cardType + ", access=" + isAccessCard()
                    + ", dh=" + usingDh);
            if (reconcileOfficialRouting("card_config", dynamicChanged)) {
                handler.post(() -> {
                    applySelectedCardRuntime("card_config");
                    applyRoutingAfterOfficialSequence("card_config");
                });
            } else {
                applySelectedCardRuntime("card_config");
            }
        }

        boolean syncSelectedWalletAidGroup(String reason) {
            if (!isOffHostWalletCard()) return false;
            String selected = normalizeAid(aid);
            if (selected == null) {
                log("ignored invalid selected wallet-card AID (" + reason + ")");
                return false;
            }
            try {
                Object cem = get(nfcService, "mCardEmulationManager");
                Object cache = get(cem, "mServiceCache");
                Object iface = null;
                try {
                    iface = get(cem, "mCardEmulationInterface");
                } catch (Throwable ignored) {
                    // older layout
                }
                ComponentName component = new ComponentName(FIN_SHELL, CARD_SERVICE);
                int walletUid = context.getPackageManager().getPackageUid(FIN_SHELL, 0);
                int userId = walletUid / 100000;
                Object group;
                try {
                    group = call(cache, "getAidGroupForService", userId, walletUid, component, "other");
                } catch (Exception e) {
                    if (iface == null) throw e;
                    group = call(iface, "getAidGroupForService", userId, component, "other");
                }
                java.util.ArrayList<String> existing = new java.util.ArrayList<>();
                if (group != null) {
                    Object aids = call(group, "getAids");
                    if (aids instanceof List) {
                        for (Object o : (List<?>) aids) {
                            if (o instanceof String) existing.add(((String) o).toUpperCase(Locale.US));
                        }
                    }
                }
                List<String> desired = Collections.singletonList(selected);
                if (existing.equals(desired)) return false;
                Class<?> groupClass = Class.forName("android.nfc.cardemulation.AidGroup");
                Object newGroup = newInstance(groupClass, new java.util.ArrayList<>(desired), "other");
                Object updated;
                try {
                    updated = call(cache, "registerAidGroupForService", userId, walletUid, component,
                            newGroup);
                } catch (Exception e) {
                    if (iface == null) throw e;
                    updated = call(iface, "registerAidGroupForService", userId, component, newGroup);
                }
                boolean ok = Boolean.TRUE.equals(updated);
                log(ok ? "synchronized selected wallet-card dynamic AID type=" + cardType
                        + " aid=" + selected + " (" + reason + ")"
                        : "selected wallet-card dynamic AID update was rejected (" + reason + ")");
                return ok;
            } catch (Throwable t) {
                log("selected wallet-card dynamic AID sync failed (" + reason + ")", t);
                return false;
            }
        }

        void showEidSwitchToast() {
            handler.postDelayed(() -> {
                try {
                    Toast toast = Toast.makeText(context, "模拟卡已切换", Toast.LENGTH_SHORT);
                    toast.show();
                    handler.postDelayed(() -> {
                        try {
                            toast.cancel();
                        } catch (Throwable ignored) {
                            // already gone
                        }
                    }, 500L);
                } catch (Throwable t) {
                    log("eID switch toast failed", t);
                }
            }, 180L);
        }

        void hydrateSelectedCardFromGlobalSettings() {
            try {
                ContentResolver r = context.getContentResolver();
                String type = Settings.Global.getString(r, "cardType");
                String gaid = normalizeAid(Settings.Global.getString(r, "aid"));
                if (type != null && !type.trim().isEmpty() && !"defaultcard".equalsIgnoreCase(type)
                        && gaid != null) {
                    cardType = type;
                    aid = gaid;
                    parameterIndex = Settings.Global.getString(r, "parameter_index");
                    prefs.edit().putString("card_type", cardType).putString("aid", aid)
                            .putString("parameter_index", parameterIndex).apply();
                }
            } catch (Throwable t) {
                log("selected card settings hydration failed", t);
            }
        }

        void applySelectedCardRuntime(String reason) {
            if (isAccessCard() && !usingDh) {
                activateRuntime(reason);
            } else {
                if (swipePage) {
                    swipePage = false;
                    persistPageState();
                    handler.removeCallbacks(timeoutRollback);
                }
                if (runtimeApplied || savedSak != null || savedDh85 != null) {
                    deactivateRuntime("non_access_card");
                }
            }
        }

        void onSwipePage(Intent intent) {
            int v = intent.getIntExtra("swipePage", -1);
            if (v == 1) {
                if (!isAccessCard()) {
                    log("ignored swipe-page enter for non-access card");
                    return;
                }
                if (usingDh) {
                    log("DH/HCE access-card parameters are not changed; off-host eSE path remains isolated");
                    return;
                }
                swipePage = true;
                swipeStartedAt = System.currentTimeMillis();
                persistPageState();
                scheduleTimeout(BRIDGE_TIMEOUT_MS);
                activateRuntime("swipe_page_enter");
            } else if (v == 0) {
                swipePage = false;
                persistPageState();
                handler.removeCallbacks(timeoutRollback);
                log("wallet swipe page exited; selected access-card RF profile retained");
            }
        }

        void onSmartCardEvent(Intent intent) {
            if (intent.getBooleanExtra("user_switch", false) && swipePage && isAccessCard()
                    && !usingDh) {
                activateRuntime("user_switch");
            }
        }

        void reconcileAfterNfcReady(String reason) {
            policy.reconcile(reason);
            if (!isNfcEnabled()) return;
            boolean force = "adapter_on".equals(reason) || "adapter_stable".equals(reason)
                    || "service_start".equals(reason) || "wallet_policy".equals(reason)
                    || "module_mode_change".equals(reason);
            if (reconcileOfficialRouting(reason, force)) {
                handler.post(() -> {
                    reconcileCardStateAfterRouting(reason);
                    applyRoutingAfterOfficialSequence(reason);
                });
                return;
            }
            reconcileCardStateAfterRouting(reason);
        }

        void reconcileCardStateAfterRouting(String reason) {
            long elapsed = System.currentTimeMillis() - swipeStartedAt;
            if (swipePage) {
                if (elapsed >= 0 && elapsed < BRIDGE_TIMEOUT_MS) {
                    scheduleTimeout(BRIDGE_TIMEOUT_MS - elapsed);
                } else {
                    swipePage = false;
                    persistPageState();
                }
            }
            if (isAccessCard() && !usingDh) {
                if (runtimeApplied) {
                    runtimeApplied = false;
                    persistRuntimeState();
                }
                activateRuntime(reason);
            } else if (runtimeApplied || savedSak != null || savedDh85 != null) {
                deactivateRuntime(reason + "_non_access");
            }
        }

        void onNfcOff() {
            handler.removeCallbacks(timeoutRollback);
            routingLiveCompat = null;
            fullRebuildInFlight = false;
            fullRebuiltCompat = null;
            runtimeApplied = false;
            persistRuntimeState();
            log("NFC off; retained selected-card RF snapshot for event-driven replay or exact mode-change restore");
        }

        boolean reconcileOfficialRouting(String reason, boolean force) {
            if (sRoutingManager == null) return false;
            Integer ese = sEseRoute;
            Integer fel = sOrigFelica;
            if (ese == null || fel == null) return false;
            sCompat = true;
            try {
                patchRoutingObjects(true);
                if (!isNfcEnabled()) {
                    routingLiveCompat = null;
                    return false;
                }
                if (!force && Boolean.TRUE.equals(routingLiveCompat)) return false;
                queueIsoDepRoute(nfcService, ese);
                queueTechnologyRoutes(nfcService, ese, fel);
                routingLiveCompat = true;
                log("official routing queued (" + reason + ") iso=" + ese + ", ab=" + ese
                        + ", felica=" + fel + ", compat=true");
                return true;
            } catch (Throwable t) {
                log("official routing reconciliation failed (" + reason + ")", t);
                return false;
            }
        }

        void applyRoutingAfterOfficialSequence(String reason) {
            try {
                if (!isNfcEnabled()) return;
                call(nfcService, "commitRouting", false);
                handler.post(() -> {
                    try {
                        if (!isNfcEnabled()) return;
                        boolean full = "adapter_stable".equals(reason) || "service_start".equals(reason)
                                || "wallet_policy".equals(reason) || "module_mode_change".equals(reason);
                        if (full && beginFullRoutingRebuild(reason)) return;
                        handler.post(() -> finishNativeRoutingCommit(reason));
                    } catch (Throwable t) {
                        log("official full routing rebuild failed (" + reason + ")", t);
                    }
                });
            } catch (Throwable t) {
                log("final official routing commit failed", t);
            }
        }

        boolean beginFullRoutingRebuild(String reason) {
            synchronized (this) {
                if (fullRebuildInFlight) return true;
                if (Boolean.TRUE.equals(fullRebuiltCompat)) return false;
                fullRebuildInFlight = true;
            }
            new Thread(() -> {
                Integer status;
                try {
                    status = rebuildAidRouting(get(nfcService, "mCardEmulationManager"));
                } catch (Throwable t) {
                    log("official full routing worker failed (" + reason + ")", t);
                    status = null;
                }
                final Integer s = status;
                handler.post(() -> {
                    synchronized (AccessCardBridge.this) {
                        fullRebuildInFlight = false;
                        if (s != null && s == 0) fullRebuiltCompat = true;
                    }
                    log("official full routing rebuild status=" + s + " (" + reason + ")");
                    finishNativeRoutingCommit(reason);
                });
            }, "ColorOsNfcRouting").start();
            return true;
        }

        void finishNativeRoutingCommit(String reason) {
            try {
                if (!isNfcEnabled()) return;
                Integer ese = sEseRoute;
                Integer fel = sOrigFelica;
                if (ese == null || fel == null) return;
                Object host = get(nfcService, "mDeviceHost");
                callExact(host, "setIsoDepProtocolRoute", new Class<?>[] {int.class}, ese);
                callExact(host, "setTechnologyABFRoute", new Class<?>[] {int.class, int.class}, ese, fel);
                Object status = call(host, "commitRouting");
                log("direct official routing commit status=" + status + " iso=" + ese + ", ab=" + ese
                        + ", felica=" + fel + " (" + reason + ")");
                call(nfcService, "applyRouting", true);
            } catch (Throwable t) {
                log("post-rebuild native routing commit failed (" + reason + ")", t);
            }
        }

        void activateRuntime(String reason) {
            if (!isNfcEnabled()) {
                log("deferred access-card RF activation until NFC is on");
                return;
            }
            if (!isAccessCard() || usingDh || runtimeApplied) return;
            byte[] existing = savedSak;
            byte[] sak = existing != null ? existing : readSakRegister();
            if (sak == null) {
                log("A11B snapshot failed; access-card RF change aborted");
                return;
            }
            Integer existingDh = savedDh85;
            Integer dh = existingDh != null ? existingDh : readDh85Mode();
            if (dh == null) {
                log("DH85 snapshot failed; access-card RF change aborted");
                return;
            }
            String base;
            if (existing == null) {
                base = readTransitConfig(new File("/data/vendor/nfc/libnfc-nxpTransit.conf"));
                if (base == null) base = readTransitConfig(new File("/data/nfc/libnfc-nxpTransit.conf"));
            } else {
                base = savedTransitConfig;
            }
            String access = readTransitConfig(resolveAccessProfile());
            if (existing == null) {
                savedSak = sak;
                savedTransitConfig = base;
            }
            if (existingDh == null) savedDh85 = dh;
            persistRuntimeState();
            if (access != null) {
                if (!applyTransitConfig(access)) {
                    log("access-card transit profile rejected; continuing with transactional SAK compatibility");
                } else {
                    log("selected access-card transit profile applied (" + profileLabel() + ")");
                }
            } else {
                log("access-card transit profile missing; using current RF profile");
            }
            if (!writeDh85Mode(1)) {
                if (base != null) applyTransitConfig(base);
                log("official eSE DH85 switch failed; restored transit profile");
                return;
            }
            if (!writeSakRegister(sak, 0)) {
                writeDh85Mode(dh);
                if (base != null) applyTransitConfig(base);
                log("A11B update failed; restored DH85/transit state");
                return;
            }
            runtimeApplied = true;
            persistRuntimeState();
            log("selected access-card RF state active (" + reason + ")");
        }

        void deactivateRuntime(String reason) {
            if (!runtimeApplied && savedSak == null && savedDh85 == null) return;
            if (!isNfcEnabled()) {
                onNfcOff();
                return;
            }
            String base = savedTransitConfig != null ? savedTransitConfig
                    : readTransitConfig(new File("/data/vendor/nfc/libnfc-nxpTransit.conf"));
            boolean profile = base == null || applyTransitConfig(base);
            boolean sak = savedSak == null || writeSakRegister(savedSak, null);
            boolean dh = savedDh85 == null || writeDh85Mode(savedDh85);
            if (profile && sak && dh) {
                runtimeApplied = false;
                savedSak = null;
                savedDh85 = null;
                savedTransitConfig = null;
                persistRuntimeState();
                log("restored exact pre-access-card RF state (" + reason + ")");
            } else {
                log("RF restore incomplete (" + reason + ") profile=" + profile + " sak=" + sak
                        + " dh85=" + dh + "; snapshot retained");
            }
        }

        boolean isAccessCard() {
            return ACCESS_CARD_TYPE.equals(cardType) && aid != null
                    && aid.toUpperCase(Locale.US).startsWith(ACCESS_CARD_AID_PREFIX);
        }

        boolean isOffHostWalletCard() {
            if (cardType == null || cardType.trim().isEmpty() || "defaultcard".equalsIgnoreCase(cardType)) {
                return false;
            }
            if (isAccessCard() && usingDh) return false;
            return normalizeAid(aid) != null;
        }

        File resolveAccessProfile() {
            if (parameterIndex != null && parameterIndex.matches("^index[0-9]{1,2}$")) {
                File f = new File("/data/vendor/nfc/libnfc_accesscard_" + parameterIndex + "_config.conf");
                if (f.isFile()) return f;
            }
            return new File("/data/vendor/nfc/libnfc_accesscard_config.conf");
        }

        String profileLabel() {
            if (parameterIndex != null && parameterIndex.matches("^index[0-9]{1,2}$")
                    && new File("/data/vendor/nfc/libnfc_accesscard_" + parameterIndex
                            + "_config.conf").isFile()) {
                return parameterIndex;
            }
            return "default";
        }

        String readTransitConfig(File file) {
            try {
                if (!file.isFile() || file.length() < 1 || file.length() > 262144) return null;
                return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
            } catch (Throwable t) {
                log("failed reading " + file.getAbsolutePath(), t);
                return null;
            }
        }

        boolean applyTransitConfig(String config) {
            Parcel data = null;
            Parcel reply = null;
            try {
                Object b = call(Class.forName("android.os.ServiceManager"), "getService",
                        NXP_TRANSIT_SERVICE);
                if (!(b instanceof IBinder)) return false;
                IBinder binder = (IBinder) b;
                if (!NXP_TRANSIT_DESCRIPTOR.equals(binder.getInterfaceDescriptor())) {
                    log("unexpected NXP transit descriptor " + binder.getInterfaceDescriptor());
                    return false;
                }
                data = Parcel.obtain();
                reply = Parcel.obtain();
                data.writeInterfaceToken(NXP_TRANSIT_DESCRIPTOR);
                data.writeString(config);
                if (!binder.transact(NXP_SET_TRANSIT_CONFIG_TRANSACTION, data, reply, 0)) return false;
                reply.readException();
                return reply.readInt() != 0;
            } catch (Throwable t) {
                log("NXP transit config transaction failed", t);
                return false;
            } finally {
                if (reply != null) reply.recycle();
                if (data != null) data.recycle();
            }
        }

        byte[] readSakRegister() {
            try {
                Class<?> rf = Class.forName("com.android.nfc.rftools.RFConfigUtils");
                Object utils = call(rf, "getInstance");
                Object response = call(utils, "getRegisterInfo", (Object) new byte[] {(byte) 0xA1, 0x1B});
                Object status = get(response, "status");
                Object payload = get(response, "payload");
                if (!(status instanceof Number) || ((Number) status).intValue() != 0
                        || !(payload instanceof byte[]) || ((byte[]) payload).length <= 5) {
                    return null;
                }
                byte[] p = (byte[]) payload;
                return Arrays.copyOfRange(p, 5, p.length);
            } catch (Throwable t) {
                log("failed to snapshot A11B", t);
                return null;
            }
        }

        boolean writeSakRegister(byte[] source, Integer forcedMode) {
            if (source.length == 0 || source.length > 250) return false;
            byte[] target = source.clone();
            if (forcedMode != null) target[0] = (byte) (int) forcedMode;
            try {
                if (Arrays.equals(readSakRegister(), target)) return true;
                Object result = call(nfcService, "sendRFConfig",
                        (Object) new byte[] {(byte) 0xA1, 0x1B}, target);
                if (result instanceof Number && ((Number) result).intValue() == 0) return true;
                Class<?> feature;
                try {
                    feature = Class.forName("com.android.nfc.Feature");
                } catch (ClassNotFoundException e) {
                    return false;
                }
                if (!(result instanceof Number) || ((Number) result).intValue() != 3
                        || !Boolean.FALSE.equals(call(feature, "isRFCustomEnabled"))) {
                    return false;
                }
                Object host = get(nfcService, "mDeviceHost");
                Object lock;
                try {
                    lock = get(nfcService, "mRfConfigLock");
                } catch (Throwable t) {
                    lock = nfcService;
                }
                synchronized (lock) {
                    call(host, "disableDiscovery");
                    try {
                        byte[] payload = new byte[4 + target.length];
                        payload[0] = 1;
                        payload[1] = (byte) 0xA1;
                        payload[2] = 0x1B;
                        payload[3] = (byte) target.length;
                        System.arraycopy(target, 0, payload, 4, target.length);
                        Object response = sendRawCoreCommand(0x02, payload);
                        if (response == null) return false;
                        Object st = get(response, "status");
                        Object d = get(response, "payload");
                        boolean accepted = st instanceof Number && ((Number) st).intValue() == 0
                                && d instanceof byte[] && ((byte[]) d).length > 0 && ((byte[]) d)[0] == 0;
                        boolean verified = accepted && Arrays.equals(readSakRegister(), target);
                        log("A17 wallet SAK fallback accepted=" + accepted + " verified=" + verified
                                + " mode=" + (target[0] & 255));
                        return verified;
                    } finally {
                        call(nfcService, "applyRouting", true);
                    }
                }
            } catch (Throwable t) {
                log("failed writing A11B", t);
                return false;
            }
        }

        Integer readDh85Mode() {
            try {
                Object response = sendRawCoreCommand(0x03, new byte[] {0x01, (byte) 0x85});
                if (response == null) return null;
                Object st = get(response, "status");
                Object p = get(response, "payload");
                if (!(st instanceof Number) || ((Number) st).intValue() != 0 || !(p instanceof byte[])
                        || ((byte[]) p).length < 5) {
                    return null;
                }
                byte[] payload = (byte[]) p;
                for (int i = 0; i < payload.length - 2; i++) {
                    if ((payload[i] & 0xff) == 0x85 && (payload[i + 1] & 0xff) == 1) {
                        int v = payload[i + 2] & 0xff;
                        return (v == 0 || v == 1) ? v : null;
                    }
                }
                return null;
            } catch (Throwable t) {
                log("failed to snapshot DH85", t);
                return null;
            }
        }

        boolean writeDh85Mode(int value) {
            if (value != 0 && value != 1) return false;
            try {
                Integer current = readDh85Mode();
                boolean success;
                if (current != null && current == value) {
                    success = true;
                } else {
                    Object host = get(nfcService, "mDeviceHost");
                    call(host, "disableDiscovery");
                    try {
                        Object response = sendRawCoreCommand(0x02,
                                new byte[] {0x01, (byte) 0x85, 0x01, (byte) value});
                        if (response == null) return false;
                        Object st = get(response, "status");
                        Object p = get(response, "payload");
                        success = st instanceof Number && ((Number) st).intValue() == 0
                                && (!(p instanceof byte[]) || ((byte[]) p).length == 0 || ((byte[]) p)[0] == 0);
                        if (!success) {
                            log("DH85 CORE_SET rejected status=" + st + " payload="
                                    + bytesToHex(p instanceof byte[] ? (byte[]) p : null));
                        }
                    } finally {
                        call(nfcService, "applyRouting", true);
                    }
                }
                if (success) {
                    Settings.Global.putInt(context.getContentResolver(), "set_85_config_mode",
                            value == 0 ? 1 : 0);
                }
                return success;
            } catch (Throwable t) {
                log("failed writing DH85", t);
                return false;
            }
        }

        Object sendRawCoreCommand(int oid, byte[] payload) throws Exception {
            Object host = get(nfcService, "mDeviceHost");
            return call(host, "sendRawVendorCmd", 1, 0, oid, payload);
        }

        boolean isNfcEnabled() {
            try {
                return Boolean.TRUE.equals(call(nfcService, "isNfcEnabled"));
            } catch (Throwable t) {
                return false;
            }
        }

        void mirrorColorOsCardSettings(Intent intent) {
            try {
                ContentResolver r = context.getContentResolver();
                Settings.Global.putString(r, "cardType", cardType);
                Settings.Global.putString(r, "aid", aid);
                Settings.Global.putString(r, "parameter_index", parameterIndex);
                String sak = intent.getStringExtra("sak");
                int v = 0;
                try {
                    if (sak != null) v = Integer.parseInt(sak, 16);
                } catch (NumberFormatException ignored) {
                    v = 0;
                }
                Settings.Global.putInt(r, "sak", v);
            } catch (Throwable t) {
                log("failed mirroring ColorOS card settings", t);
            }
        }

        void scheduleTimeout(long delay) {
            handler.removeCallbacks(timeoutRollback);
            handler.postDelayed(timeoutRollback, Math.max(1L, delay));
        }

        void persistPageState() {
            prefs.edit().putBoolean("swipe_page", swipePage).putLong("swipe_started_at", swipeStartedAt)
                    .apply();
        }

        void persistRuntimeState() {
            SharedPreferences.Editor e = prefs.edit().putBoolean("runtime_applied", runtimeApplied)
                    .putString("saved_sak", bytesToHex(savedSak))
                    .putString("saved_transit_config", savedTransitConfig);
            if (savedDh85 == null) e.remove("saved_dh85_mode");
            else e.putInt("saved_dh85_mode", savedDh85);
            e.apply();
        }
    }

    static boolean eq(Object a, Object b) {
        return a == null ? b == null : a.equals(b);
    }

    static String normalizeAid(String value) {
        if (value == null) return null;
        String n = value.trim().toUpperCase(Locale.US);
        if (n.length() < 10 || n.length() > 32 || n.length() % 2 != 0 || !n.matches("^[0-9A-F]+$")) {
            return null;
        }
        return n;
    }

    static String bytesToHex(byte[] bytes) {
        if (bytes == null) return null;
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) sb.append(String.format(Locale.ROOT, "%02X", b & 0xff));
        return sb.toString();
    }

    static byte[] hexToBytes(String value) {
        if (value == null || value.length() < 2 || value.length() % 2 != 0
                || !value.matches("^[0-9A-Fa-f]+$")) {
            return null;
        }
        byte[] out = new byte[value.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    // ===================================================== wallet policy

    /** Port of FixedWalletPolicy: the default OPPO wallet policy, owned by NfcService. */
    static final class FixedWalletPolicy {
        static final String ROLE = "android.app.role.WALLET";
        static final String ENABLED = "coloros_wallet_compat_enabled";
        static final String DEFAULT = "nfc_payment_default_component";
        static final String FOREGROUND = "nfc_payment_foreground";
        static final String ACTIVE = "nfc_multise_active";
        static final String ROUTES = "nfc_multise_list";
        static final int MAX_CORRECTIONS = 6;
        static final long CORRECTION_WINDOW_MS = 15000L;
        static final Map<String, Boolean> TAG_PREFERENCES = new LinkedHashMap<>();
        static final Set<String> WALLET_PACKAGES = new HashSet<>(Arrays.asList(
                FIN_SHELL, "com.heytap.tas", "com.unionpay.tsmservice", "com.heytap.htms",
                "com.oplus.eid"));

        static {
            TAG_PREFERENCES.put(FIN_SHELL, true);
            TAG_PREFERENCES.put("com.eg.android.AlipayGphone", true);
            TAG_PREFERENCES.put("com.tencent.mm", true);
            TAG_PREFERENCES.put("cmb.pb", true);
            TAG_PREFERENCES.put("com.chinamobile.mcloud", true);
            TAG_PREFERENCES.put("com.greenpoint.android.mc10086.activity", true);
            TAG_PREFERENCES.put("com.miui.tsmclient", false);
            TAG_PREFERENCES.put("mark.via", false);
            TAG_PREFERENCES.put("com.heytap.tas", false);
            TAG_PREFERENCES.put("com.xiaomi.market", false);
            TAG_PREFERENCES.put("com.yuanwofei.cardemulator.pro", false);
            TAG_PREFERENCES.put("com.android.apps.tag", false);
        }

        interface RoutingChanged { void onRoutingChanged(String reason); }

        final Context context;
        final Handler handler;
        final Object service;
        final RoutingChanged onRoutingChanged;
        Context userContext;
        String pendingReason = "start";
        boolean roleInFlight;
        boolean roleReplayPending;
        int roleAttempts;
        boolean finishedLogged;
        boolean correctionsPaused;
        final ArrayDeque<Long> correctionTimes = new ArrayDeque<>();
        final Set<String> errors = new HashSet<>();
        final Executor executor;
        final Runnable reconcileTask;
        final ContentObserver observer;

        FixedWalletPolicy(Context context, Handler handler, Object service, RoutingChanged cb) {
            this.context = context;
            this.handler = handler;
            this.service = service;
            this.onRoutingChanged = cb;
            this.executor = handler::post;
            this.reconcileTask = () -> {
                if (reconcile(pendingReason)) onRoutingChanged.onRoutingChanged("wallet_policy");
            };
            this.observer = new ContentObserver(handler) {
                @Override public void onChange(boolean selfChange, Uri uri) {
                    schedule("settings_changed");
                }
            };
        }

        void install() throws Exception {
            userContext = (Context) call(context, "createContextAsUser", owner(), 0);
            ContentResolver r = userContext.getContentResolver();
            for (String k : new String[] {ENABLED, ACTIVE, ROUTES}) {
                r.registerContentObserver(Settings.Global.getUriFor(k), false, observer);
            }
            for (String k : new String[] {DEFAULT, FOREGROUND}) {
                r.registerContentObserver(Settings.Secure.getUriFor(k), false, observer);
            }
            IntentFilter life = new IntentFilter();
            life.addAction(Intent.ACTION_BOOT_COMPLETED);
            life.addAction(Intent.ACTION_USER_UNLOCKED);
            context.registerReceiver(new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent intent) {
                    if (Intent.ACTION_USER_UNLOCKED.equals(intent.getAction())
                            || Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
                        resetCorrectionBudget();
                    }
                    schedule(String.valueOf(intent.getAction()));
                }
            }, life, null, handler, Context.RECEIVER_EXPORTED);
            IntentFilter pkg = new IntentFilter();
            pkg.addAction(Intent.ACTION_PACKAGE_ADDED);
            pkg.addAction(Intent.ACTION_PACKAGE_CHANGED);
            pkg.addAction(Intent.ACTION_PACKAGE_REPLACED);
            pkg.addAction(Intent.ACTION_PACKAGE_REMOVED);
            pkg.addDataScheme("package");
            context.registerReceiver(new BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent intent) {
                    Uri data = intent.getData();
                    String p = data == null ? null : data.getSchemeSpecificPart();
                    if (p == null) return;
                    if (TAG_PREFERENCES.containsKey(p) || WALLET_PACKAGES.contains(p)) {
                        if (Intent.ACTION_PACKAGE_ADDED.equals(intent.getAction())
                                || Intent.ACTION_PACKAGE_REPLACED.equals(intent.getAction())) {
                            resetCorrectionBudget();
                        }
                        schedule("package_changed:" + p);
                    }
                }
            }, pkg, null, handler, Context.RECEIVER_EXPORTED);
            // CardEmulationManager / NfcAdapterService callbacks call
            // onCardEmulationEvent / afterTagPreference (patched in).
            schedule("install");
            handler.postDelayed(() -> schedule("boot_settled"), 20000L);
            log("fixed OPPO wallet policy installed (event-driven, no Action)");
        }

        void schedule(String reason) {
            if (correctionsPaused) return;
            pendingReason = reason;
            handler.removeCallbacks(reconcileTask);
            handler.postDelayed(reconcileTask, 350L);
        }

        boolean reconcile(String reason) {
            Context ctx = userContext;
            if (ctx == null) return false;
            if ("adapter_on".equals(reason) || "service_start".equals(reason)) resetCorrectionBudget();
            if (correctionsPaused) return false;
            long id = Binder.clearCallingIdentity();
            try {
                if (!isOwnerActive() || !walletInstalled(ctx)) return false;
                boolean[] changed = {roleReplayPending};
                boolean[] routing = {roleReplayPending};
                roleReplayPending = false;
                ContentResolver r = ctx.getContentResolver();
                step("settings", () -> {
                    String[][] kv = {{ENABLED, "1"}, {ACTIVE, EMBEDDED_SE}, {ROUTES, EMBEDDED_SE}};
                    for (String[] e : kv) {
                        if (!e[1].equals(Settings.Global.getString(r, e[0]))) {
                            if (!Settings.Global.putString(r, e[0], e[1])) {
                                throw new IllegalStateException("write " + e[0] + " failed");
                            }
                            changed[0] = true;
                            routing[0] = true;
                        }
                    }
                    if (!"1".equals(Settings.Secure.getString(r, FOREGROUND))) {
                        if (!Settings.Secure.putInt(r, FOREGROUND, 1)) {
                            throw new IllegalStateException("write foreground failed");
                        }
                        changed[0] = true;
                    }
                });
                step("offhost", () -> {
                    Object m = manager();
                    if (m == null) return;
                    Object cache = get(m, "mServiceCache");
                    for (String p : new String[] {FIN_SHELL, "com.heytap.tas"}) {
                        ComponentName c = new ComponentName(p, CARD_SERVICE);
                        Object info = call(cache, "getService", 0, c);
                        if (info == null) continue;
                        if (Boolean.TRUE.equals(call(info, "isOnHost"))) continue;
                        if (!"eSE1".equals(call(info, "getOffHostSecureElement"))) {
                            Object api = get(m, "mCardEmulationInterface");
                            if (!Boolean.TRUE.equals(call(api, "setOffHostForService", 0, c, "eSE1"))) {
                                throw new IllegalStateException("setOffHostForService rejected for " + p);
                            }
                            changed[0] = true;
                            routing[0] = true;
                        }
                    }
                });
                step("payment", () -> {
                    if (!PAYMENT_COMPONENT.equals(Settings.Secure.getString(r, DEFAULT))) {
                        Object m = manager();
                        if (m != null) {
                            call(m, "setDefaultServiceForCategoryChecked", 0,
                                    new ComponentName(FIN_SHELL, CARD_SERVICE), "payment");
                        }
                        if (!PAYMENT_COMPONENT.equals(Settings.Secure.getString(r, DEFAULT))) {
                            if (!Settings.Secure.putString(r, DEFAULT, PAYMENT_COMPONENT)) {
                                throw new IllegalStateException("write default payment failed");
                            }
                        }
                        changed[0] = true;
                        routing[0] = true;
                    }
                });
                step("wallet_role", () -> reconcileRole(ctx, reason));
                step("tag_preferences", () -> {
                    Object adapter = get(service, "mNfcAdapter");
                    Map<?, ?> current = (Map<?, ?>) call(adapter, "getTagIntentAppPreferenceForUser", 0);
                    for (Map.Entry<String, Boolean> e : TAG_PREFERENCES.entrySet()) {
                        Object cur = current == null ? null : current.get(e.getKey());
                        if (!e.getValue().equals(cur) && packageInstalled(ctx, e.getKey())) {
                            Object res = call(adapter, "setTagIntentAppPreferenceForUser", 0,
                                    e.getKey(), e.getValue());
                            if (!(res instanceof Number) || ((Number) res).intValue() != 0) {
                                throw new IllegalStateException("tag preference rejected " + e.getKey());
                            }
                            changed[0] = true;
                        }
                    }
                });
                if (changed[0] || !finishedLogged) {
                    finishedLogged = true;
                    log("fixed wallet policy reconciled reason=" + reason + " changed=" + changed[0]);
                }
                if (changed[0]) recordCorrection();
                return routing[0];
            } finally {
                Binder.restoreCallingIdentity(id);
            }
        }

        void resetCorrectionBudget() {
            correctionsPaused = false;
            correctionTimes.clear();
            roleAttempts = 0;
        }

        void recordCorrection() {
            long now = SystemClock.uptimeMillis();
            while (!correctionTimes.isEmpty() && now - correctionTimes.peekFirst() > CORRECTION_WINDOW_MS) {
                correctionTimes.removeFirst();
            }
            correctionTimes.addLast(now);
            if (correctionTimes.size() >= MAX_CORRECTIONS) {
                correctionsPaused = true;
                handler.removeCallbacks(reconcileTask);
                log("repeated wallet policy conflict; corrections paused until unlock, NFC ON or package update");
            }
        }

        void reconcileRole(Context ctx, String reason) throws Exception {
            Object roles = ctx.getSystemService("role");
            if (roles == null) return;
            if (!Boolean.TRUE.equals(call(roles, "isRoleAvailable", ROLE))) return;
            List<?> holders = (List<?>) call(roles, "getRoleHoldersAsUser", ROLE, owner());
            if (holders != null && holders.size() == 1 && FIN_SHELL.equals(holders.get(0))) {
                roleAttempts = 0;
                return;
            }
            if (roleInFlight || roleAttempts >= 3) return;
            UserManager um = ctx.getSystemService(UserManager.class);
            if (um == null || !um.isUserUnlocked()) return;
            roleAttempts++;
            roleInFlight = true;
            try {
                Consumer<Boolean> cb = accepted -> {
                    roleInFlight = false;
                    roleReplayPending = Boolean.TRUE.equals(accepted);
                    log("wallet role request accepted=" + accepted + " reason=" + reason);
                    schedule("wallet_role_result");
                };
                call(roles, "addRoleHolderAsUser", ROLE, FIN_SHELL, 0, owner(), executor, cb);
            } catch (Exception e) {
                roleInFlight = false;
                throw e;
            }
        }

        Object manager() {
            try {
                return get(service, "mCardEmulationManager");
            } catch (Throwable t) {
                return null;
            }
        }

        boolean isOwnerActive() {
            try {
                return ((Number) call(service, "getUserId")).intValue() == 0;
            } catch (Throwable t) {
                return false;
            }
        }

        static boolean walletInstalled(Context ctx) {
            try {
                ServiceInfo info = ctx.getPackageManager().getServiceInfo(
                        new ComponentName(FIN_SHELL, CARD_SERVICE), 0);
                return info.enabled && info.applicationInfo.enabled;
            } catch (Throwable t) {
                return false;
            }
        }

        static boolean packageInstalled(Context ctx, String pkg) {
            try {
                return ctx.getPackageManager().getApplicationInfo(pkg, 0).enabled;
            } catch (Throwable t) {
                return false;
            }
        }

        interface Step { void run() throws Exception; }

        void step(String name, Step block) {
            try {
                block.run();
                errors.remove(name);
            } catch (Throwable t) {
                if (errors.add(name)) log("fixed wallet policy " + name + " unavailable: " + t);
            }
        }
    }
}
