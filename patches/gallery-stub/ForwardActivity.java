package com.coloros.gallery3d;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/**
 * OplusCamera addresses its gallery intents to com.coloros.gallery3d, which on
 * this port is only a stub:
 *
 *   thumbnail tap   com.android.camera.action.REVIEW, setPackage(com.coloros.gallery3d)
 *   watermark edit  android.intent.action.EDIT, component
 *                   com.coloros.gallery3d/com.oplus.gallery.pictureeditorpage.PhotoEditorActivity
 *
 * Re-send the same intent (action, data, type, extras, clip data) to the
 * HyperOS gallery / media editor.  The camera grants the URI to this package;
 * FLAG_GRANT_READ_URI_PERMISSION passes that grant on.  This replaces the
 * Sense CameraGalleryHooks redirect, so it also works without LSPosed.
 */
public final class ForwardActivity extends Activity {
    private static final String TAG = "GalleryStubForward";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent src = getIntent();
        String[] targets = Intent.ACTION_EDIT.equals(src.getAction())
                ? new String[] {"com.miui.mediaeditor", "com.miui.gallery"}
                : new String[] {"com.miui.gallery"};
        boolean started = false;
        for (String pkg : targets) {
            // With the camera's URI grant, pass it on; without one (e.g. the
            // intent did not come from the camera) the grant flag throws, and
            // the targets read MediaStore with their own media permissions.
            for (boolean grant : new boolean[] {true, false}) {
                Intent out = new Intent(src);
                out.setComponent(null);
                out.setPackage(pkg);
                if (grant) {
                    out.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                } else {
                    out.removeFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                            | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                }
                if (getCallingActivity() != null) {
                    out.addFlags(Intent.FLAG_ACTIVITY_FORWARD_RESULT);
                }
                try {
                    startActivity(out);
                    Log.i(TAG, src.getAction() + " -> " + pkg + (grant ? "" : " (no uri grant)"));
                    started = true;
                    break;
                } catch (SecurityException e) {
                    Log.w(TAG, pkg + " uri grant failed: " + e.getMessage());
                } catch (ActivityNotFoundException e) {
                    Log.w(TAG, src.getAction() + " not handled by " + pkg);
                    break;
                }
            }
            if (started) {
                break;
            }
        }
        if (!started) {
            Log.e(TAG, "no target for " + src);
        }
        finish();
    }
}
