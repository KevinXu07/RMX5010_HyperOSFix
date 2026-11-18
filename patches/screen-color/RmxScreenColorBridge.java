package com.android.server.display;

import android.content.ContentResolver;
import android.content.Context;
import android.provider.Settings;
import android.util.Log;

import java.lang.reflect.Method;
import java.util.Arrays;

/**
 * RMX5010 HyperOS port: bridge HyperOS screen colour settings to the ColorOS
 * display stack (image version of Sense ScreenColorBridgeHooks).
 *
 * HyperOS Settings writes screen_optimize_mode / screen_color_level and MIUI's
 * DisplayFeatureManagerService turns them into setDisplayFeature(displayId,
 * mode, value, cookie) calls on vendor.xiaomi.hardware.displayfeature.  The
 * stock ColorOS vendor has no such HAL, so every call is dropped.  The patched
 * DisplayFeatureManagerService.setDisplayFeature calls {@link #onSetDisplayFeature}
 * first (scripts/patch_miui_services_greeze.py).
 *
 *  - Colour modes map to the panel's calibrated ColorOS render intents
 *    (standard 301, nature 303, vivid 307).  They are written to
 *    Settings.System display_color_mode, so ColorDisplayService applies them
 *    through DisplayTransformManager.setColorMode (vendor range 256..511 ->
 *    setDisplayColor) and restores them at boot and on user switch.  The
 *    RMX5010ColorModes overlay adds the three intents to
 *    config_availableColorModes; without it ColorDisplayService would reject
 *    them.
 *  - Colour temperature presets / custom picker, reading mode and the expert
 *    mode parameters become DisplayTransformManager colour matrices.
 *
 * Everything is reached by reflection (services.jar is not on the compile
 * classpath) and every failure is caught: the bridge must never break
 * DisplayFeatureManagerService.
 */
public final class RmxScreenColorBridge {
    private static final String TAG = "RmxScreenColor";
    private static final String DTM = "com.android.server.display.color.DisplayTransformManager";
    private static final String LOCAL_SERVICES = "com.android.server.LocalServices";
    private static final String DISPLAY_COLOR_MODE = "display_color_mode";

    // MIUI setFeature modes
    private static final int MIUI_MODE_ADAPTIVE = 0; // 生动 (screen_optimize_mode 1)
    private static final int MIUI_MODE_VIVID = 1;    // 鲜艳 (screen_optimize_mode 2)
    private static final int MIUI_MODE_STANDARD = 2; // 专业原色 (screen_optimize_mode 3)
    private static final int MIUI_MODE_READING = 3;  // 阅读/护眼
    // Colour temperature alone (ro.all_modes.colorpick_adjust=true).
    private static final int MIUI_MODE_UNLIMITED_COLOR = 23;
    // 高级模式: setFeature(26, value, cookie), cookie = parameter index.
    private static final int MIUI_MODE_EXPERT = 26;

    // ColorOS WCG 2.0 render intents (OplusFeatureColorMode)
    private static final int INTENT_STANDARD = 301;
    private static final int INTENT_NATURE = 303;
    private static final int INTENT_VIVID = 307;

    // Colour matrix levels (DisplayTransformManager multiplies them in order).
    private static final int LEVEL_READING = 101;     // just after night display (100)
    private static final int LEVEL_TEMPERATURE = 126; // just after white balance (125)
    private static final int LEVEL_EXPERT = 127;

    private static final int EXPERT_GAMUT = 0;
    private static final int EXPERT_R = 1;
    private static final int EXPERT_G = 2;
    private static final int EXPERT_B = 3;
    private static final int EXPERT_HUE = 4;
    private static final int EXPERT_SATURATION = 5;
    private static final int EXPERT_VALUE = 6;
    private static final int EXPERT_CONTRAST = 7;
    private static final int EXPERT_GAMMA = 8;
    private static final int EXPERT_COOKIE_RESTORE = 9;
    private static final int EXPERT_COOKIE_SET_LAST = 10;
    private static final String[] EXPERT_KEYS = {
            "color_gamut", "color_r", "color_g", "color_b", "color_hue",
            "color_saturation", "color_value", "contrast_ratio", "gamma"};
    // haotian device_features expert_*_default
    private static final int[] EXPERT_DEFAULTS = {0, 255, 255, 255, 0, 0, 0, 0, 220};
    /** Expert gamut index (expert_gamut 0..3) -> ColorOS render intent. */
    private static final int[] EXPERT_GAMUT_INTENTS = {
            INTENT_VIVID, INTENT_STANDARD, INTENT_NATURE, INTENT_STANDARD};

    private static final int USER_CURRENT = -2;

    private static int sIntent = -1;
    private static final int[] sExpert = EXPERT_DEFAULTS.clone();
    private static boolean sExpertActive;
    private static Context sContext;
    private static ClassLoader sLoader;
    private static Method sSetColorMatrix;

    private RmxScreenColorBridge() {
    }

    /** Called first thing in DisplayFeatureManagerService.setDisplayFeature. */
    public static void onSetDisplayFeature(Object service, int displayId, int mode,
            int value, int cookie) {
        try {
            synchronized (RmxScreenColorBridge.class) {
                if (sContext == null) {
                    sLoader = service.getClass().getClassLoader();
                    java.lang.reflect.Field f = service.getClass().getDeclaredField("mContext");
                    f.setAccessible(true);
                    sContext = (Context) f.get(service);
                }
                handle(displayId, mode, value, cookie);
            }
        } catch (Throwable error) {
            Log.e(TAG, "bridge failed mode=" + mode + " value=" + value, error);
        }
    }

    private static void handle(int displayId, int mode, int value, int cookie) throws Exception {
        if (displayId != 0) {
            return;
        }
        switch (mode) {
            case MIUI_MODE_ADAPTIVE:
                leaveExpert();
                applyIntent(INTENT_NATURE);
                applyTemperature(value);
                break;
            case MIUI_MODE_VIVID:
                leaveExpert();
                applyIntent(INTENT_VIVID);
                applyTemperature(value);
                break;
            case MIUI_MODE_STANDARD:
                leaveExpert();
                applyIntent(INTENT_STANDARD);
                applyTemperature(value);
                break;
            case MIUI_MODE_READING:
                applyReading(value);
                break;
            case MIUI_MODE_UNLIMITED_COLOR:
                if (!sExpertActive) {
                    applyTemperature(value);
                }
                break;
            case MIUI_MODE_EXPERT:
                applyExpert(value, cookie);
                break;
            default:
                break;
        }
    }

    private static void leaveExpert() throws Exception {
        if (sExpertActive) {
            sExpertActive = false;
            setColorMatrix(LEVEL_EXPERT, null);
            Log.i(TAG, "expert mode off");
        }
    }

    /**
     * cookie 0..8: one parameter changed; 9: restore defaults; 10: re-apply the
     * saved expert_data (sent when the expert page opens).
     */
    private static void applyExpert(int value, int cookie) throws Exception {
        if (!sExpertActive) {
            sExpertActive = true;
            // MIUI disables the colour temperature picker in expert mode.
            setColorMatrix(LEVEL_TEMPERATURE, null);
        }
        if (cookie >= 0 && cookie < EXPERT_KEYS.length) {
            sExpert[cookie] = value;
        } else if (cookie == EXPERT_COOKIE_RESTORE) {
            System.arraycopy(EXPERT_DEFAULTS, 0, sExpert, 0, sExpert.length);
        } else if (cookie == EXPERT_COOKIE_SET_LAST) {
            loadExpertFromSettings();
        } else {
            return;
        }
        int gamut = Math.max(0, Math.min(sExpert[EXPERT_GAMUT], EXPERT_GAMUT_INTENTS.length - 1));
        applyIntent(EXPERT_GAMUT_INTENTS[gamut]);
        setColorMatrix(LEVEL_EXPERT, expertMatrix());
        Log.i(TAG, "expert cookie=" + cookie + " value=" + value
                + " params=" + Arrays.toString(sExpert));
    }

    private static void loadExpertFromSettings() {
        try {
            String json = Settings.System.getString(sContext.getContentResolver(), "expert_data");
            if (json == null || json.isEmpty()) {
                return;
            }
            org.json.JSONObject data = new org.json.JSONObject(json);
            for (int i = 0; i < EXPERT_KEYS.length; i++) {
                sExpert[i] = data.optInt(EXPERT_KEYS[i], sExpert[i]);
            }
        } catch (Throwable error) {
            Log.w(TAG, "read expert_data failed", error);
        }
    }

    /**
     * RGB gains, hue rotation, saturation, value and contrast as one affine
     * colour transform (column-major 4x4).  Gamma has no linear equivalent.
     */
    private static float[] expertMatrix() {
        boolean identity = true;
        for (int i = 1; i < EXPERT_GAMMA; i++) {
            if (sExpert[i] != EXPERT_DEFAULTS[i]) {
                identity = false;
                break;
            }
        }
        if (identity) {
            return null;
        }
        float[][] m = {
                {sExpert[EXPERT_R] / 255f, 0f, 0f},
                {0f, sExpert[EXPERT_G] / 255f, 0f},
                {0f, 0f, sExpert[EXPERT_B] / 255f}};
        // hue rotation around the luminance axis (-180..180 degrees)
        double th = Math.toRadians(sExpert[EXPERT_HUE]);
        float c = (float) Math.cos(th);
        float s = (float) Math.sin(th);
        m = mul(new float[][] {
                {0.213f + c * 0.787f - s * 0.213f, 0.715f - c * 0.715f - s * 0.715f,
                        0.072f - c * 0.072f + s * 0.928f},
                {0.213f - c * 0.213f + s * 0.143f, 0.715f + c * 0.285f + s * 0.140f,
                        0.072f - c * 0.072f - s * 0.283f},
                {0.213f - c * 0.213f - s * 0.787f, 0.715f - c * 0.715f + s * 0.715f,
                        0.072f + c * 0.928f + s * 0.072f}}, m);
        // saturation -50..50 -> 0.5x..1.5x
        float sat = 1f + sExpert[EXPERT_SATURATION] / 100f;
        m = mul(new float[][] {
                {0.213f + 0.787f * sat, 0.715f - 0.715f * sat, 0.072f - 0.072f * sat},
                {0.213f - 0.213f * sat, 0.715f + 0.285f * sat, 0.072f - 0.072f * sat},
                {0.213f - 0.213f * sat, 0.715f - 0.715f * sat, 0.072f + 0.928f * sat}}, m);
        // value -255..255 -> 0.7x..1.3x
        float val = 1f + 0.3f * sExpert[EXPERT_VALUE] / 255f;
        // contrast -100..100 -> 0.5x..1.5x around mid grey
        float con = 1f + 0.5f * sExpert[EXPERT_CONTRAST] / 100f;
        float scale = val * con;
        float offset = 0.5f * (1f - con);
        float[] out = new float[16];
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 3; col++) {
                out[col * 4 + row] = m[row][col] * scale;
            }
            out[12 + row] = offset;
        }
        out[15] = 1f;
        return out;
    }

    private static float[][] mul(float[][] a, float[][] b) {
        float[][] r = new float[3][3];
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
            }
        }
        return r;
    }

    /**
     * Hand the render intent to ColorDisplayService through its own setting; it
     * applies it now (settings observer) and again at boot / user switch.
     */
    private static void applyIntent(int intent) throws Exception {
        if (intent == sIntent) {
            return;
        }
        ContentResolver cr = sContext.getContentResolver();
        Method put = Settings.System.class.getMethod("putIntForUser",
                ContentResolver.class, String.class, int.class, int.class);
        put.invoke(null, cr, DISPLAY_COLOR_MODE, intent, USER_CURRENT);
        sIntent = intent;
        Log.i(TAG, "render intent " + intent);
    }

    /** value: 1 warm, 2 default, 3 cool, otherwise an ARGB colour from the custom picker. */
    private static void applyTemperature(int value) throws Exception {
        float[] gains;
        if (value == 1) {
            gains = new float[] {1.0f, 0.94f, 0.82f};
        } else if (value == 2 || value == 0) {
            gains = null;
        } else if (value == 3) {
            gains = new float[] {0.90f, 0.95f, 1.0f};
        } else {
            gains = pickerGains(value);
        }
        setGains(LEVEL_TEMPERATURE, gains);
    }

    /**
     * The custom picker stores ScreenColorAlgorithm.encode(pixel): same hue as
     * the picked tint with log-compressed chroma.  Scale channels so the
     * strongest stays at 1.0.
     */
    private static float[] pickerGains(int argb) {
        float r = ((argb >> 16) & 0xff) / 255f;
        float g = ((argb >> 8) & 0xff) / 255f;
        float b = (argb & 0xff) / 255f;
        float max = Math.max(r, Math.max(g, b));
        if (max <= 0f) {
            return null;
        }
        return new float[] {clamp(r / max), clamp(g / max), clamp(b / max)};
    }

    /** value: 0 off, otherwise MIUI reading-mode level (larger = warmer, up to 255). */
    private static void applyReading(int value) throws Exception {
        float[] gains = null;
        if (value > 0) {
            float t = Math.min(1f, value / 255f);
            gains = new float[] {1.0f, 1.0f - 0.25f * t, 1.0f - 0.6f * t};
        }
        setGains(LEVEL_READING, gains);
    }

    private static void setGains(int level, float[] gains) throws Exception {
        float[] matrix = null;
        if (gains != null) {
            matrix = new float[] {
                    gains[0], 0f, 0f, 0f,
                    0f, gains[1], 0f, 0f,
                    0f, 0f, gains[2], 0f,
                    0f, 0f, 0f, 1f};
        }
        setColorMatrix(level, matrix);
    }

    private static void setColorMatrix(int level, float[] matrix) throws Exception {
        Object dtm = dtm();
        if (dtm == null) {
            return;
        }
        if (sSetColorMatrix == null) {
            sSetColorMatrix = dtm.getClass().getMethod("setColorMatrix", int.class, float[].class);
        }
        sSetColorMatrix.invoke(dtm, level, (Object) matrix);
    }

    private static Object dtm() throws Exception {
        Class<?> dtmClass = Class.forName(DTM, false, sLoader);
        Class<?> local = Class.forName(LOCAL_SERVICES, false, sLoader);
        Object dtm = local.getMethod("getService", Class.class).invoke(null, dtmClass);
        if (dtm == null) {
            Log.w(TAG, "DisplayTransformManager not ready");
        }
        return dtm;
    }

    private static float clamp(float v) {
        return Math.max(0.6f, Math.min(1f, v));
    }
}
