import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.SharedMemory;

import java.io.FileInputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/**
 * Loads the stock OPPO OVMS first-stage wake model ("小布小布") into the DSP the
 * same way OVoiceManagerService does, and logs every HAL callback.
 *
 * usage: OvmsTest <ovms.apk> <OVMS_1st_wakeup.bin> <confidence> <vprintType> <seconds>
 */
public class OvmsTest {
    static final String MODEL_UUID = "7d5b82e9-e5c9-477e-afa4-60e68d30b462";
    static final String VENDOR_UUID = "68ac2d41-e861-11e4-95ed-0002a5d5c51c";

    static void log(String s) {
        System.out.println(s);
        System.out.flush();
    }

    static Object newObj(String cls) throws Exception {
        return Class.forName(cls).getDeclaredConstructor().newInstance();
    }

    static void set(Object o, String f, Object v) throws Exception {
        o.getClass().getField(f).set(o, v);
    }

    static Method find(Object o, String name) {
        for (Method m : o.getClass().getMethods()) if (m.getName().equals(name)) return m;
        throw new RuntimeException("no method " + name);
    }

    static Object arrayOf(Object e) {
        Object a = Array.newInstance(e.getClass(), 1);
        Array.set(a, 0, e);
        return a;
    }

    /** Runs OVMS's own s3.d#j(byte[]) packer (it does not touch instance state). */
    static byte[] pack(String apk, byte[] raw) throws Exception {
        ClassLoader cl = new dalvik.system.DexClassLoader(apk, "/data/local/tmp/ovt/oat", null,
                OvmsTest.class.getClassLoader());
        Class<?> d = Class.forName("s3.d", false, cl);
        Class<?> us = Class.forName("sun.misc.Unsafe");
        Field f = us.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Object unsafe = f.get(null);
        Object inst = us.getMethod("allocateInstance", Class.class).invoke(unsafe, d);
        Method j = d.getDeclaredMethod("j", byte[].class);
        j.setAccessible(true);
        return (byte[]) j.invoke(inst, raw);
    }

    public static void main(String[] a) throws Exception {
        String apk = a[0], path = a[1];
        int conf = Integer.parseInt(a[2]);
        int vprint = Integer.parseInt(a[3]);
        int secs = Integer.parseInt(a[4]);
        int modes = a.length > 5 ? Integer.parseInt(a[5]) : 3;

        byte[] raw;
        try (FileInputStream in = new FileInputStream(path)) {
            raw = in.readAllBytes();
        }
        byte[] data = pack(apk, raw);
        log("raw " + raw.length + " packed " + data.length);

        SharedMemory shm = SharedMemory.create("ovms", data.length);
        ByteBuffer bb = shm.mapReadWrite();
        bb.put(data);
        SharedMemory.unmap(bb);
        ParcelFileDescriptor pfd = (ParcelFileDescriptor)
                SharedMemory.class.getMethod("getFdDup").invoke(shm);

        IBinder svc = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "soundtrigger_middleware");
        Object mw = Class.forName("android.media.soundtrigger_middleware.ISoundTriggerMiddlewareService$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, svc);

        final String cbDesc = "android.media.soundtrigger_middleware.ISoundTriggerCallback";
        Binder cb = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel p, Parcel reply, int flags) {
                if (code == INTERFACE_TRANSACTION) {
                    reply.writeString(cbDesc);
                    return true;
                }
                log("CALLBACK code=" + code + " size=" + p.dataSize()
                        + " t=" + System.currentTimeMillis());
                return true;
            }
        };
        Object cbIf = Class.forName(cbDesc + "$Stub").getMethod("asInterface", IBinder.class)
                .invoke(null, cb);

        Object id = newObj("android.media.permission.Identity");
        set(id, "uid", 0);
        set(id, "pid", android.os.Process.myPid());
        set(id, "packageName", "root");
        Object module = find(mw, "attachAsOriginator").invoke(mw, 0, id, cbIf);

        Object sm = newObj("android.media.soundtrigger.SoundModel");
        set(sm, "type", 0);
        set(sm, "uuid", MODEL_UUID);
        set(sm, "vendorUuid", VENDOR_UUID);
        set(sm, "data", pfd);
        set(sm, "dataSize", data.length);
        Object phrase = newObj("android.media.soundtrigger.Phrase");
        set(phrase, "id", 0);
        set(phrase, "recognitionModes", modes);
        set(phrase, "users", new int[]{0});
        set(phrase, "locale", "en-US");
        set(phrase, "text", "aispeech");
        Object psm = newObj("android.media.soundtrigger.PhraseSoundModel");
        set(psm, "common", sm);
        set(psm, "phrases", arrayOf(phrase));

        int handle = (Integer) find(module, "loadPhraseModel").invoke(module, psm);
        log("loaded handle " + handle);

        Object lvl = newObj("android.media.soundtrigger.ConfidenceLevel");
        set(lvl, "userId", 0);
        set(lvl, "levelPercent", conf);
        Object ex = newObj("android.media.soundtrigger.PhraseRecognitionExtra");
        set(ex, "id", 0);
        set(ex, "recognitionModes", modes);
        set(ex, "confidenceLevel", conf);
        set(ex, "levels", arrayOf(lvl));
        Object rc = newObj("android.media.soundtrigger.RecognitionConfig");
        set(rc, "captureRequested", true);
        set(rc, "phraseRecognitionExtras", arrayOf(ex));
        set(rc, "data", new byte[]{(byte) vprint, (byte) (vprint >> 8),
                (byte) (vprint >> 16), (byte) (vprint >> 24)});
        set(rc, "audioCapabilities", 0);

        find(module, "startRecognition").invoke(module, handle, rc);
        log("recognition started conf=" + conf + " vprint=" + vprint + " modes=" + modes + " t=" + System.currentTimeMillis() + " for " + secs + "s");

        Thread.sleep(secs * 1000L);
        try { find(module, "stopRecognition").invoke(module, handle); } catch (Throwable t) { log("stop: " + t); }
        try { find(module, "unloadModel").invoke(module, handle); } catch (Throwable t) { log("unload: " + t); }
        try { find(module, "detach").invoke(module); } catch (Throwable t) { log("detach: " + t); }
        log("done");
        System.exit(0);
    }
}
