package com.android.server.vibrator;

import android.content.Context;
import android.os.CombinedVibration;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.provider.Settings;
import android.util.Log;
import android.util.SparseBooleanArray;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * RMX5010 HyperOS port: haptic compatibility in the image (image version of
 * Sense HapticHooks).
 *
 * HyperOS requests Xiaomi private effect IDs (back gesture 162/163, FOD,
 * keyboard, screen lock, todo, ...), but the Realme vibrator HAL only plays
 * AOSP 0..12, so without translation those requests fall back to nothing or
 * to the default buzz.  The patched miui-services calls
 *
 *  - {@link #onInit} from VibratorManagerServiceImpl.init(Context): once the
 *    vibrator service is up, the Xiaomi IDs are added to the HAL's cached
 *    VibratorInfo so callers (SystemUI, launcher) do not skip haptics after an
 *    areEffectsSupported() check;
 *  - {@link #onStartVibration} from VibratorManagerServiceImpl
 *    .startVibrationLockedInjector(Vibration), before the effect is scaled:
 *    private prebaked IDs become the closest RMX effect, and the 45/67/79 ms
 *    multi-step keyboard / launcher patterns become one calibrated click.
 *
 * Everything goes through reflection and every failure is caught.
 */
public final class RmxHapticBridge {
    private static final String TAG = "RmxHaptic";

    /** Xiaomi IDs sent by HyperOS UI (advertised as supported). */
    private static final int[] XIAOMI_EFFECTS = {
            72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87,
            88, 90, 91, 92, 93, 96, 98, 106, 114,
            157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168,
            169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
            181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192,
            201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
            213, 214, 215, 216, 217,
            401, 402, 403, 404, 405, 406, 407, 408, 410,
            10001
    };

    // Optional overrides, same keys as the Sense module (-1 = 12 ms raw step).
    private static final String CLICK_EFFECT_KEY = "op13_fix_haptic_click_effect";
    private static final String SYSTEM_EFFECT_KEY = "op13_fix_haptic_system_effect";

    private static final String INTENSITY_KEY = "haptic_feedback_infinite_intensity";
    private static final float INTENSITY_MAX = 1.5f;

    private static Context sContext;
    private static volatile boolean sIntensityApplied;
    private static Method sGetEffectToPlay;
    private static Method sUpdateEffectToPlay;
    private static Field sCallerInfo;

    private RmxHapticBridge() {
    }

    // ------------------------------------------------------------------ init

    public static void onInit(Context context) {
        try {
            sContext = context;
            final Handler handler = new Handler(Looper.getMainLooper());
            handler.post(new Runnable() {
                private int mTries;

                @Override
                public void run() {
                    boolean done = false;
                    try {
                        done = extendSupportedEffects();
                    } catch (Throwable error) {
                        Log.w(TAG, "extend supported effects failed", error);
                    }
                    if (!done && ++mTries < 120) {
                        handler.postDelayed(this, 500);
                        return;
                    }
                    watchIntensity(handler);
                }
            });
        } catch (Throwable error) {
            Log.e(TAG, "init failed", error);
        }
    }

    /** True once every vibrator's info has been extended. */
    private static boolean extendSupportedEffects() throws Exception {
        Method getService = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class);
        IBinder service = (IBinder) getService.invoke(null, "vibrator_manager");
        if (service == null) {
            return false;
        }
        // In system_server the binder is the VibratorManagerService itself, so
        // these calls return the HAL's cached VibratorInfo objects.
        int[] ids = (int[]) service.getClass().getMethod("getVibratorIds").invoke(service);
        if (ids == null || ids.length == 0) {
            return false;
        }
        Method getInfo = service.getClass().getMethod("getVibratorInfo", int.class);
        for (int id : ids) {
            Object info = getInfo.invoke(service, id);
            if (info == null) {
                return false;
            }
            Field f = info.getClass().getDeclaredField("mSupportedEffects");
            f.setAccessible(true);
            SparseBooleanArray supported = (SparseBooleanArray) f.get(info);
            if (supported == null) {
                supported = new SparseBooleanArray();
                f.set(info, supported);
            }
            for (int effect : XIAOMI_EFFECTS) {
                supported.put(effect, true);
            }
        }
        Log.i(TAG, "Xiaomi effects advertised on " + ids.length + " vibrator(s)");
        return true;
    }

    // ------------------------------------------------------------ intensity

    /**
     * HyperOS Settings stores the haptic strength slider in
     * haptic_feedback_infinite_intensity (0..1.5 without
     * sys.haptic.slide_version=2.0, default 1.5) and applies it through the
     * Xiaomi IVibratorExt HAL, which this phone does not have.  The real gain
     * on this LRA is the qcom-haptics fifo_vmax / vmax / cl_vmax nodes (stock
     * 8200 / 1280 / 1280); system_server cannot write sysfs, so publish the
     * values as properties and let /system_ext/etc/init/rmx5010_haptic.rc
     * (init domain, which may write sysfs_leds) write them.  The slider maximum
     * is the stock strength; the minimum is the old Sense slider's 0.3.
     */
    private static void watchIntensity(Handler handler) {
        try {
            sContext.getContentResolver().registerContentObserver(
                    Settings.System.getUriFor(INTENSITY_KEY), false,
                    new android.database.ContentObserver(handler) {
                        @Override
                        public void onChange(boolean selfChange) {
                            applyIntensity();
                        }
                    });
        } catch (Throwable error) {
            Log.w(TAG, "intensity observer failed", error);
        }
        applyIntensity();
    }

    private static void applyIntensity() {
        try {
            float value = Settings.System.getFloat(sContext.getContentResolver(),
                    INTENSITY_KEY, INTENSITY_MAX);
            float v = Math.max(0f, Math.min(1f, value / INTENSITY_MAX));
            int fifo = Math.round(600f + 7600f * v);
            int direct = Math.max(200, Math.round(1280f * fifo / 8200f));
            Method set = Class.forName("android.os.SystemProperties")
                    .getMethod("set", String.class, String.class);
            // The rc triggers on the fifo property, so publish direct first.
            set.invoke(null, "sys.rmx5010.haptic_direct", String.valueOf(direct));
            set.invoke(null, "sys.rmx5010.haptic_fifo", String.valueOf(fifo));
            sIntensityApplied = true;
        } catch (Throwable error) {
            Log.w(TAG, "apply intensity failed", error);
        }
    }

    // ------------------------------------------------------------ vibration

    public static void onStartVibration(Object vibration) {
        try {
            if (vibration == null) {
                return;
            }
            if (!sIntensityApplied && sContext != null) {
                applyIntensity();
            }
            Class<?> cls = vibration.getClass();
            if (sGetEffectToPlay == null) {
                sGetEffectToPlay = cls.getMethod("getEffectToPlay");
                sUpdateEffectToPlay = cls.getMethod("updateEffectToPlay", CombinedVibration.class);
                sCallerInfo = findField(cls, "callerInfo");
            }
            CombinedVibration effect = (CombinedVibration) sGetEffectToPlay.invoke(vibration);
            if (effect == null) {
                return;
            }
            Object caller = sCallerInfo.get(vibration);
            CombinedVibration out = rewriteTouchStep(effect, caller);
            if (out == null) {
                out = mapEffects(effect);
            }
            if (out != null && out != effect) {
                sUpdateEffectToPlay.invoke(vibration, out);
            }
        } catch (Throwable error) {
            Log.w(TAG, "vibration rewrite failed", error);
        }
    }

    private static Field findField(Class<?> cls, String name) throws NoSuchFieldException {
        for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
            try {
                Field f = c.getDeclaredField(name);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
            }
        }
        throw new NoSuchFieldException(name);
    }

    /**
     * HyperOS / Sogou keyboard feedback and the launcher / SystemUI feedback
     * are 45/67/79 ms multi-step patterns; a sustained multi-pulse step on this
     * LRA reads as a rotor-like double thump.  Replace them (and short single
     * steps) with the HAL's calibrated click.  Returns null when unchanged.
     */
    private static CombinedVibration rewriteTouchStep(CombinedVibration effect, Object caller)
            throws Exception {
        long duration = (Long) CombinedVibration.class.getMethod("getDuration").invoke(effect);
        VibrationAttributes attrs = (VibrationAttributes) caller.getClass()
                .getField("attrs").get(caller);
        String opPkg = (String) caller.getClass().getField("opPkg").get(caller);
        String reason = (String) caller.getClass().getField("reason").get(caller);
        int usage = attrs == null ? VibrationAttributes.USAGE_UNKNOWN : attrs.getUsage();

        boolean keyboardPattern = reason != null
                && (reason.contains("MIUI_SDK") || reason.contains("pattern_vibration"));
        boolean systemPattern = opPkg != null
                && (opPkg.contains("miui.home") || opPkg.contains("launcher")
                || opPkg.contains("systemui"))
                && duration > 90;
        boolean longFeedback = duration > 90 && isFeedbackUsage(usage);
        if (!keyboardPattern && !systemPattern && !longFeedback
                && (duration < 30 || duration > 90)) {
            return null;
        }
        if (duration > 500) {
            return null;
        }
        int effectId = keyboardPattern
                ? globalInt(CLICK_EFFECT_KEY, 2) : globalInt(SYSTEM_EFFECT_KEY, 4);
        VibrationEffect click = effectId >= 0
                ? VibrationEffect.createPredefined(effectId)
                : VibrationEffect.createOneShot(12, VibrationEffect.DEFAULT_AMPLITUDE);
        return CombinedVibration.createParallel(click);
    }

    private static int globalInt(String key, int def) {
        try {
            String raw = Settings.Global.getString(sContext.getContentResolver(), key);
            if (raw == null) {
                return def;
            }
            return Math.max(-1, Math.min(5, Integer.parseInt(raw.trim())));
        } catch (Throwable ignored) {
            return def;
        }
    }

    private static boolean isFeedbackUsage(int usage) {
        return usage != VibrationAttributes.USAGE_ALARM
                && usage != VibrationAttributes.USAGE_NOTIFICATION
                && usage != VibrationAttributes.USAGE_RINGTONE
                && usage != VibrationAttributes.USAGE_COMMUNICATION_REQUEST
                && usage != VibrationAttributes.USAGE_MEDIA;
    }

    /**
     * Rewrite private prebaked IDs in a mono vibration (the form every
     * predefined / composed haptic uses).  Returns null when unchanged.
     */
    private static CombinedVibration mapEffects(CombinedVibration combined) throws Exception {
        Method getEffect;
        try {
            getEffect = combined.getClass().getMethod("getEffect");
        } catch (NoSuchMethodException notMono) {
            return null;
        }
        Object effect = getEffect.invoke(combined);
        if (effect == null) {
            return null;
        }
        Method getSegments;
        try {
            getSegments = effect.getClass().getMethod("getSegments");
        } catch (NoSuchMethodException notComposed) {
            return null;
        }
        List<?> segments = (List<?>) getSegments.invoke(effect);
        Class<?> prebaked = Class.forName("android.os.vibrator.PrebakedSegment");
        List<Object> out = new ArrayList<>(segments.size());
        boolean changed = false;
        for (Object seg : segments) {
            if (prebaked.isInstance(seg)) {
                int id = (Integer) prebaked.getMethod("getEffectId").invoke(seg);
                int target = mapEffect(id);
                if (target != id) {
                    boolean fallback = (Boolean) prebaked.getMethod("shouldFallback").invoke(seg);
                    int strength = (Integer) prebaked.getMethod("getEffectStrength").invoke(seg);
                    Constructor<?> ctor = prebaked.getDeclaredConstructor(
                            int.class, boolean.class, int.class);
                    ctor.setAccessible(true);
                    seg = ctor.newInstance(target, fallback, strength);
                    changed = true;
                }
            }
            out.add(seg);
        }
        if (!changed) {
            return null;
        }
        int repeat = (Integer) effect.getClass().getMethod("getRepeatIndex").invoke(effect);
        Constructor<?> composed = effect.getClass().getDeclaredConstructor(List.class, int.class);
        composed.setAccessible(true);
        VibrationEffect mapped = (VibrationEffect) composed.newInstance(out, repeat);
        return CombinedVibration.createParallel(mapped);
    }

    /**
     * HyperOS UI meaning -> RMX effect (0..12, the only ones the HAL plays).
     * Same table as Sense HapticHooks.
     */
    private static int mapEffect(int source) {
        switch (source) {
            case 72: return 0;   // gesture up
            case 73: return 4;   // FOD planet
            case 74:
            case 75: return 3;   // wired/wireless charge
            case 76:
            case 82: return 12;  // unlock/face failure
            case 77: return 0;
            case 78: return 0;
            case 79: return 5;
            case 80: return 4;
            case 81: return 6;
            case 83: return 0;
            case 84: return 0;
            case 85: return 2;   // screenshot
            case 86: return 6;
            case 87: return 0;
            case 88: return 2;   // short click
            case 90:
            case 93: return 10;  // task/notification clean all
            case 91: return 6;
            case 92: return 3;
            case 96: return 6;
            case 98: return 3;
            case 106: return 6;
            case 114: return 6;

            case 157: return 4;
            case 158: return 3;
            case 159: return 4;  // FOD ripple
            case 160:
            case 161: return 0;
            case 162: return 5;  // flick (back gesture start)
            case 163: return 7;  // flick.light (quick back)
            case 164: return 0;
            case 165:
            case 174: return 12; // negative feedback
            case 166: return 2;
            case 167: return 6;  // positive feedback
            case 168: return 6;
            case 169: return 12; // lockdown
            case 170: return 0;
            case 171: return 10; // todo all done
            case 172: return 6;
            case 173: return 6;
            case 175: return 0;
            case 176: return 2;
            case 177: return 0;
            case 178: return 0;
            case 179: return 0;
            case 180: return 5;
            case 181: return 0;
            case 182: return 6;
            case 183: return 0;
            case 184: return 3;
            case 185: return 6;
            case 186: return 0;
            case 187: return 6;
            case 188: return 2;
            case 189: return 6;
            case 190: return 6;
            case 191: return 4;
            // Settings haptic demo video (rtp 0xc0): /odm/etc/vibrator plays it.
            case 192: return 192;

            case 201: return 10;
            case 202:
            case 203: return 6;
            case 204: return 10;
            case 205: return 10; // todo all done
            case 206: return 6;  // todo finish one
            case 207: return 12;
            case 208: return 6;
            case 209: return 3;  // screen lock
            case 210: return 4;  // fingerprint unlock
            case 211: return 4;
            case 212:
            case 213: return 10;
            case 214: return 6;
            case 215: return 0;
            case 216: return 6;
            case 217: return 6;

            case 401: return 6;
            case 402: return 6;
            case 403: return 12;
            case 404: return 6;
            case 405: return 6;
            case 406: return 10;
            case 407: return 6;
            case 408: return 6;
            case 410: return 6;

            case 10001: return 1; // notification long press
            default:
                // Keep AOSP 0..12; other private IDs get a calibrated TICK.
                return source >= 0 && source <= 12 ? source : 2;
        }
    }
}
