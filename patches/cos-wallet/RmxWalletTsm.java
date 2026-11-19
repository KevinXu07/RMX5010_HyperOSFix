package com.miui.tsmclient;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;
import android.util.Log;

/**
 * Mi TSM (com.miui.tsmclient) side of the ColorOS wallet set: image version of
 * COS-WALLET-FIX's hookMiuiAutomaticNfcActivityLaunch / hookMiuiTransitShortcut,
 * applied only while FinShell is the NFC payment default.
 *
 * scripts/patch_tsmclient.py routes Context.startActivity(Intent) call sites
 * through startActivity() below and calls afterDoubleClickCreate() after
 * DoubleClickActivity.onCreate:
 *  - Mi TSM's NFC event service turns RF_ON / TRANSACTION / SMART_SELECT_CARD
 *    notifications into a NEW_TASK launch of DoubleClickActivity, which steals
 *    the foreground from FinShell although the eSE transaction was routed
 *    correctly.  Those automatic launches are dropped;
 *  - a user launch of DoubleClickActivity (the transit shortcut) opens
 *    FinShell's card package page instead.
 */
public final class RmxWalletTsm {
    private static final String TAG = "ColorOSWalletCompat";
    static final String TSM = "com.miui.tsmclient";
    static final String FIN_SHELL = "com.finshell.wallet";
    static final String PAYMENT_COMPONENT = FIN_SHELL + "/com.nearme.wallet.nfc.CardService";
    static final String CARD_PACKAGE = "com.nearme.pay.business.cardpackage.ui.CardPackageActivity";
    static final String LOCKSCREEN_SESSION = "local.mio.coloroswalletcompat.extra.LOCKSCREEN_SESSION";
    static final String DOUBLE_CLICK = "com.miui.intent.action.DOUBLE_CLICK";
    static final String EVENT_SOURCE = "event_source_type";

    private RmxWalletTsm() {}

    static boolean finShellDefault(Context c) {
        try {
            return PAYMENT_COMPONENT.equals(Settings.Secure.getString(c.getContentResolver(),
                    "nfc_payment_default_component"));
        } catch (Throwable t) {
            return false;
        }
    }

    static boolean automaticNfcLaunch(Intent intent) {
        if (intent == null || !DOUBLE_CLICK.equals(intent.getAction())) return false;
        String src;
        try {
            src = intent.getStringExtra(EVENT_SOURCE);
        } catch (Throwable t) {
            return false;
        }
        return "com.miui.nfc.action.RF_ON".equals(src)
                || "com.miui.nfc.action.TRANSACTION".equals(src)
                || "com.miui.nfc.action.SMART_SELECT_CARD".equals(src);
    }

    /** Replaces Context.startActivity(Intent) call sites. */
    public static void startActivity(Context context, Intent intent) {
        if (automaticNfcLaunch(intent)
                && (intent.getPackage() == null || TSM.equals(intent.getPackage()))
                && finShellDefault(context)) {
            Log.i(TAG, "suppressed Mi TSM automatic NFC foreground launch "
                    + intent.getStringExtra(EVENT_SOURCE));
            return;
        }
        context.startActivity(intent);
    }

    /** DoubleClickActivity.onCreate(Bundle) after. */
    public static void afterDoubleClickCreate(Activity activity) {
        try {
            if (!finShellDefault(activity)) return;
            if (automaticNfcLaunch(activity.getIntent())) {
                activity.overridePendingTransition(0, 0);
                activity.finish();
                activity.overridePendingTransition(0, 0);
                Log.i(TAG, "finished Mi TSM automatic NFC activity fallback");
                return;
            }
            Intent redirect = new Intent();
            redirect.setComponent(new ComponentName(FIN_SHELL, CARD_PACKAGE));
            redirect.putExtra(LOCKSCREEN_SESSION, true);
            redirect.addFlags(0x00080000);
            activity.startActivity(redirect);
            activity.finish();
            Log.i(TAG, "redirected Mi TSM transit shortcut to FinShell");
        } catch (Throwable t) {
            Log.w(TAG, "Mi TSM transit shortcut redirect failed", t);
        }
    }
}
