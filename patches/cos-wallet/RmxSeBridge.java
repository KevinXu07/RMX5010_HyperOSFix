package com.android.se;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.util.Log;

import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Map;

/**
 * SecureElement side of the ColorOS wallet set (image version of
 * COS-WALLET-FIX's hookSecureElementOplusAccessFallback).
 *
 * ColorOS SecureElement adds an OPlus fallback around the GlobalPlatform
 * access-rule check; the Xiaomi/AOSP SecureElement here does not, so the
 * genuine FinShell / TAS certificates are rejected although the eSE is there.
 * scripts/patch_secure_element.py makes
 * AccessControlEnforcer.setUpChannelAccess return
 * ChannelAccess.getPrivilegeAccess(pkg, callingPid) when isTrustedWallet(pkg):
 * the package name AND its PackageManager signer must match the original
 * ColorOS wallet certificates below.  No wildcard, no other caller, no change
 * to the on-card ARA-M rules.
 */
public final class RmxSeBridge {
    private static final String TAG = "RmxSeBridge";
    private static final Map<String, String> SIGNERS = new HashMap<>();

    static {
        SIGNERS.put("com.finshell.wallet",
                "7f68e808c85fc6f97f63197aad345a904242145ef4499310f90f8d0653e855be");
        SIGNERS.put("com.heytap.tas",
                "bdab0168db8aae8dd157d975ee63c129756d923b9bb64120086f78db26b9c6d2");
    }

    private RmxSeBridge() {}

    private static Context application() {
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            return (Context) at.getMethod("currentApplication").invoke(null);
        } catch (Throwable t) {
            return null;
        }
    }

    private static String sha256(byte[] data) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder sb = new StringBuilder();
        for (byte b : d) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }

    public static boolean isTrustedWallet(String pkg) {
        String expected = pkg == null ? null : SIGNERS.get(pkg);
        if (expected == null) return false;
        Context context = application();
        if (context == null) return false;
        try {
            PackageInfo info = context.getPackageManager().getPackageInfo(pkg,
                    PackageManager.GET_SIGNING_CERTIFICATES);
            SigningInfo si = info.signingInfo;
            if (si == null) return false;
            Signature[] sigs = si.hasMultipleSigners()
                    ? si.getApkContentsSigners() : si.getSigningCertificateHistory();
            if (sigs == null) return false;
            for (Signature s : sigs) {
                if (expected.equals(sha256(s.toByteArray()))) {
                    Log.i(TAG, "privileged eSE access for " + pkg);
                    return true;
                }
            }
            Log.w(TAG, pkg + " signer does not match the ColorOS wallet certificate");
        } catch (Throwable t) {
            Log.w(TAG, "signer check failed for " + pkg, t);
        }
        return false;
    }
}
