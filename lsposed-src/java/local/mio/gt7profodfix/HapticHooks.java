package local.mio.gt7profodfix;

import android.content.Context;
import android.os.CombinedVibration;
import android.os.SystemClock;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.util.SparseBooleanArray;

import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedHelpers;

/**
 * RMX5010 haptic compatibility.
 *
 * HyperOS requests Xiaomi private effect IDs (back gesture 162/163, FOD,
 * keyboard, screen lock, todo, ...), but the Realme/AAC vibrator HAL only
 * advertises AOSP 0..12. The framework therefore drops those requests before
 * they reach the HAL. Translate each private ID to the closest RMX effect and
 * expose the translated IDs through VibratorInfo so callers such as SystemUI
 * and the launcher do not skip haptics after an areEffectsSupported() check.
 */
final class HapticHooks {
    /** Xiaomi IDs sent by HyperOS UI; values are RMX-supported effect IDs. */
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

    private static volatile float cachedScale = 1.0f;
    private static volatile long cachedScaleAt;

    private HapticHooks() {
    }

    static void install(ClassLoader loader) {
        int mapHooks = hookEffectTranslation(loader);
        int infoHooks = hookSupportedEffects(loader);
        int scaleHooks = hookScaleFactor(loader);
        int clickHooks = hookTouchStepEffects(loader);
        if (mapHooks == 0 || infoHooks == 0 || scaleHooks == 0 || clickHooks == 0) {
            HookLog.info("haptic compatibility incomplete: map=" + mapHooks
                    + " info=" + infoHooks + " scale=" + scaleHooks
                    + " click=" + clickHooks);
        } else {
            HookLog.info("haptic compatibility active: map=" + mapHooks
                    + " info=" + infoHooks + " scale=" + scaleHooks
                    + " click=" + clickHooks);
        }
    }

    /**
     * HyperOS sends the Xiaomi keyboard/settings feedback as a 75-79 ms Step.
     * A sustained Step on this LRA reads as a rotor-like buzz instead of a
     * crisp click. Rewrite short touch Steps to a 12 ms one-shot before the
     * HAL sees them; VibrationScaler still applies the user's strength.
     */
    private static int hookTouchStepEffects(ClassLoader loader) {
        Class<?> service = Reflect.findClass(loader,
                "com.android.server.vibrator.VibratorManagerService");
        if (service == null) {
            HookLog.info("VibratorManagerService missing; touch click rewrite skipped");
            return 0;
        }
        return Reflect.hookNamedMethods(service, "vibrateInternal",
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        int effectIndex = -1;
                        int attrsIndex = -1;
                        int reasonIndex = -1;
                        for (int i = 0; i < param.args.length; i++) {
                            Object arg = param.args[i];
                            if (arg instanceof CombinedVibration) {
                                effectIndex = i;
                            } else if (arg instanceof VibrationAttributes) {
                                attrsIndex = i;
                            } else if (arg instanceof String) {
                                reasonIndex = i;
                            }
                        }
                        if (effectIndex < 0 || attrsIndex < 0) {
                            return;
                        }
                        VibrationAttributes attrs =
                                (VibrationAttributes) param.args[attrsIndex];
                        String reason = reasonIndex >= 0
                                ? (String) param.args[reasonIndex] : null;
                        int usage = attrs.getUsage();
                        HookLog.once("haptic-vibrate-internal-seen",
                                "vibrateInternal seen usage=" + usage
                                        + " reason=" + reason);
                        try {
                            CombinedVibration original =
                                    (CombinedVibration) param.args[effectIndex];
                            Object rawDuration =
                                    XposedHelpers.callMethod(original, "getDuration");
                            long duration = rawDuration instanceof Number
                                    ? ((Number) rawDuration).longValue() : -1L;
                            if (duration < 30 || duration > 90) {
                                return;
                            }
                            VibrationEffect click = VibrationEffect.createOneShot(
                                    12, VibrationEffect.DEFAULT_AMPLITUDE);
                            param.args[effectIndex] =
                                    CombinedVibration.createParallel(click);
                            HookLog.once("haptic-touch-step-" + duration,
                                    "haptic touch step " + duration
                                            + "ms -> 12ms click (usage="
                                            + usage + ")");
                        } catch (Throwable error) {
                            HookLog.once("haptic-touch-step-error",
                                    "haptic touch step rewrite failed: " + error);
                        }
                    }
                });
    }

    /**
     * RMX-specific strength calibration. The Realme LRA is driven at full
     * amplitude by the MIUI_SDK 75 ms keyboard/settings patterns; the setting
     * lets the same waveforms be scaled without replacing them. Only feedback
     * usages are touched: alarms, ringtones, notifications and media keep the
     * stock ColorOS/HyperOS level.
     */
    private static int hookScaleFactor(ClassLoader loader) {
        Class<?> scaler = Reflect.findClass(loader,
                "com.android.server.vibrator.VibrationScaler");
        if (scaler == null) {
            HookLog.info("VibrationScaler missing; haptic strength scale skipped");
            return 0;
        }
        return Reflect.hookNamedMethods(scaler, "getScaleFactor",
                new XC_MethodHook() {
                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        // OS4 signature is getScaleFactor(int usage, boolean adaptive).
                        if (param.args.length == 0
                                || !(param.args[0] instanceof Integer)) {
                            return;
                        }
                        int usage = (Integer) param.args[0];
                        if (usage == VibrationAttributes.USAGE_ALARM
                                || usage == VibrationAttributes.USAGE_NOTIFICATION
                                || usage == VibrationAttributes.USAGE_RINGTONE
                                || usage == VibrationAttributes.USAGE_COMMUNICATION_REQUEST
                                || usage == VibrationAttributes.USAGE_MEDIA) {
                            return;
                        }
                        float factor = feedbackScale();
                        if (Math.abs(factor - 1.0f) < 0.001f) {
                            return;
                        }
                        Object result = param.getResult();
                        if (result instanceof Float) {
                            param.setResult((Float) result * factor);
                            HookLog.once("haptic-scale-" + factor,
                                    "haptic feedback scale=" + factor);
                        }
                    }
                });
    }

    private static float feedbackScale() {
        Context context = ModuleConfig.systemContext();
        if (context == null) {
            return 1.0f;
        }
        long now = SystemClock.uptimeMillis();
        if (now - cachedScaleAt < 500L) {
            return cachedScale;
        }
        String raw = ModuleConfig.getString(context, ModuleConfig.HAPTIC_SCALE, "1.0");
        float value;
        try {
            value = Float.parseFloat(raw.trim());
        } catch (Throwable ignored) {
            value = 1.0f;
        }
        value = Math.max(0.3f, Math.min(1.2f, value));
        // The LRA amplitude response is not linear. Apply a mild perceptual
        // curve so equal slider steps feel closer to equal strength changes;
        // 1.0 remains 1.0 and the ends stay inside the tested range.
        float factor = (float) Math.pow(value, 1.35f);
        factor = Math.max(0.2f, Math.min(1.2f, factor));
        cachedScale = factor;
        cachedScaleAt = now;
        return factor;
    }

    private static int hookEffectTranslation(ClassLoader loader) {
        Class<?> segment = Reflect.findClass(loader,
                "android.os.vibrator.PrebakedSegment");
        if (segment == null) {
            HookLog.info("PrebakedSegment missing; haptic effect mapping skipped");
            return 0;
        }
        return Reflect.hookNamedMethods(segment, "getEffectId", new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                int source = (Integer) param.getResult();
                int target = mapEffect(source);
                if (target == source) {
                    return;
                }
                param.setResult(target);
                HookLog.once("haptic-map-" + source,
                        "haptic effect " + source + " -> " + target);
            }
        });
    }

    private static int hookSupportedEffects(ClassLoader loader) {
        Class<?> service = Reflect.findClass(loader,
                "com.android.server.vibrator.VibratorManagerService");
        if (service == null) {
            HookLog.info("VibratorManagerService missing; haptic support list skipped");
            return 0;
        }
        XC_MethodHook extend = new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                Object result = param.getResult();
                if (result instanceof Iterable<?>) {
                    for (Object info : (Iterable<?>) result) {
                        extendSupportedEffects(info);
                    }
                } else {
                    extendSupportedEffects(result);
                }
            }
        };
        int hooks = Reflect.hookNamedMethods(service, "getVibratorInfo", extend);
        hooks += Reflect.hookNamedMethods(service, "getVibratorInfos", extend);
        return hooks;
    }

    private static void extendSupportedEffects(Object info) {
        if (info == null) {
            return;
        }
        try {
            Object current;
            try {
                current = XposedHelpers.getObjectField(info, "mSupportedEffects");
            } catch (Throwable ignored) {
                current = null;
            }
            SparseBooleanArray supported;
            if (current instanceof SparseBooleanArray) {
                supported = (SparseBooleanArray) current;
            } else {
                supported = new SparseBooleanArray();
                XposedHelpers.setObjectField(info, "mSupportedEffects", supported);
            }
            for (int effect : XIAOMI_EFFECTS) {
                supported.put(effect, true);
            }
        } catch (Throwable error) {
            HookLog.once("haptic-info-error",
                    "haptic VibratorInfo extension failed: " + error);
        }
    }

    /**
     * Semantics follow the HyperOS UI meaning, not the OnePlus IDs used by the
     * OP13 module: RMX effects 0..12 are the only ones the AAC/Qcom HAL plays.
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
            case 106: return 6;  // four-pulse cadence approximated by effect 6
            case 114: return 6;

            case 157: return 4;
            case 158: return 3;
            case 159: return 4;  // FOD ripple
            case 160:
            case 161: return 0;
            case 162: return 7;  // back gesture start/strong fallback
            case 163: return 2;  // back gesture quick click
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
            case 192: return 6;

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
            default: return source;
        }
    }
}
