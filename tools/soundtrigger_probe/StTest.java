import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.SharedMemory;

import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/**
 * Root-only SoundTrigger probe: loads a phrase model straight into the
 * soundtrigger middleware with a chosen confidence level and logs every
 * callback transaction the HAL sends back.
 *
 * usage: app_process / StTest <model> <vendor-uuid> <confidence> <seconds>
 */
public class StTest {
    static volatile boolean detected;
    static void log(String s) {
        System.out.println(s);
        System.out.flush();
    }

    static Object newObj(String cls) throws Exception {
        return Class.forName(cls).getDeclaredConstructor().newInstance();
    }

    static void set(Object o, String f, Object v) throws Exception {
        Field fl = o.getClass().getField(f);
        fl.set(o, v);
    }

    static Method find(Object o, String name) {
        for (Method m : o.getClass().getMethods()) if (m.getName().equals(name)) return m;
        throw new RuntimeException("no method " + name + " on " + o.getClass());
    }

    /** Plays raw 16 kHz mono s16le PCM through the speaker and blocks until done. */
    static void play(String path) throws Exception {
        byte[] pcm;
        try (FileInputStream in = new FileInputStream(path)) {
            pcm = in.readAllBytes();
        }
        android.media.AudioTrack t = new android.media.AudioTrack.Builder()
                .setAudioAttributes(new android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(new android.media.AudioFormat.Builder()
                        .setSampleRate(16000)
                        .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO)
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT).build())
                .setTransferMode(android.media.AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.length).build();
        t.write(pcm, 0, pcm.length);
        log("play " + path + " t=" + System.currentTimeMillis());
        t.play();
        Thread.sleep(pcm.length / 32 + 300);
        t.stop();
        t.release();
    }

    public static void main(String[] a) throws Exception {
        if (a.length == 1) { play(a[0]); System.exit(0); }
        String path = a[0], uuid = a[1];
        int conf = Integer.parseInt(a[2]);
        int secs = Integer.parseInt(a[3]);

        byte[] data;
        try (FileInputStream in = new FileInputStream(path)) {
            data = in.readAllBytes();
        }
        log("model " + path + " size " + data.length);

        SharedMemory shm = SharedMemory.create("sttest", data.length);
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
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (code == INTERFACE_TRANSACTION) {
                    reply.writeString(cbDesc);
                    return true;
                }
                detected = code == 2 || detected;
                log("CALLBACK code=" + code + " dataSize=" + data.dataSize()
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
        log("attached " + module);

        Object sm = newObj("android.media.soundtrigger.SoundModel");
        set(sm, "type", 0);
        set(sm, "uuid", uuid);
        set(sm, "vendorUuid", uuid);
        set(sm, "data", pfd);
        set(sm, "dataSize", data.length);
        Object phrase = newObj("android.media.soundtrigger.Phrase");
        set(phrase, "id", 0);
        boolean uv = System.getenv("ST_UV") != null;
        set(phrase, "recognitionModes", uv ? 3 : 1);
        set(phrase, "users", uv ? new int[]{1} : new int[0]);
        set(phrase, "locale", "en-US");
        set(phrase, "text", "xiaoaitongxue");
        Object psm = newObj("android.media.soundtrigger.PhraseSoundModel");
        set(psm, "common", sm);
        Object phrases = java.lang.reflect.Array.newInstance(phrase.getClass(), 1);
        java.lang.reflect.Array.set(phrases, 0, phrase);
        set(psm, "phrases", phrases);

        int handle = (Integer) find(module, "loadPhraseModel").invoke(module, psm);
        log("loaded handle " + handle);

        Object ex = newObj("android.media.soundtrigger.PhraseRecognitionExtra");
        set(ex, "id", 0);
        set(ex, "recognitionModes", uv ? 3 : 1);
        set(ex, "confidenceLevel", conf);
        Class<?> clC = Class.forName("android.media.soundtrigger.ConfidenceLevel");
        Object lv = java.lang.reflect.Array.newInstance(clC, uv ? 1 : 0);
        if (uv) {
            Object l = clC.getDeclaredConstructor().newInstance();
            set(l, "userId", 1);
            set(l, "levelPercent", conf);
            java.lang.reflect.Array.set(lv, 0, l);
        }
        set(ex, "levels", lv);
        Object rc = newObj("android.media.soundtrigger.RecognitionConfig");
        set(rc, "captureRequested", false);
        Object exs = java.lang.reflect.Array.newInstance(ex.getClass(), 1);
        java.lang.reflect.Array.set(exs, 0, ex);
        set(rc, "phraseRecognitionExtras", exs);
        set(rc, "data", new byte[0]);
        set(rc, "audioCapabilities", 0);

        find(module, "startRecognition").invoke(module, handle, rc);
        log("recognition started, confidence " + conf + ", listening " + secs + "s");

        // app_process already runs a binder thread pool for the callbacks.
        long end = System.currentTimeMillis() + secs * 1000L;
        Thread.sleep(1500);
        while (!detected && System.currentTimeMillis() < end) {
            if (a.length <= 4) { Thread.sleep(500); continue; }
            for (int i = 4; i < a.length && !detected && System.currentTimeMillis() < end; i++) {
                play(a[i]);
                Thread.sleep(1500);
            }
        }
        log(detected ? "DETECTED" : "timeout, no detection");
        try { find(module, "stopRecognition").invoke(module, handle); } catch (Throwable t) { log("stop: " + t); }
        try { find(module, "unloadModel").invoke(module, handle); } catch (Throwable t) { log("unload: " + t); }
        try { find(module, "detach").invoke(module); } catch (Throwable t) { log("detach: " + t); }
        log("done");
        System.exit(0);
    }
}
