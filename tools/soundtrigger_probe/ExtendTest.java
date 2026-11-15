import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.lang.reflect.Array;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;

/**
 * Builds a user-dependent SVA model the way the old VoiceTrigger did:
 * ListenSoundModel.extend(uim, keyword, user, N, recordings, out, conf),
 * using the old APK's own com.qualcomm.listen client (vendor LSM AIDL service).
 *
 * usage: ExtendTest <old.apk> <model.uim> <out.udm> <user> <rec.pcm>...
 */
public class ExtendTest {
    static void log(String s) {
        System.out.println(s);
        System.out.flush();
    }

    static byte[] read(String p) throws Exception {
        try (FileInputStream in = new FileInputStream(p)) {
            return in.readAllBytes();
        }
    }

    static String dump(Object o, int depth) throws Exception {
        if (o == null) return "null";
        Class<?> c = o.getClass();
        if (c.isArray()) {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < Array.getLength(o); i++) sb.append(dump(Array.get(o, i), depth + 1)).append(", ");
            return sb.append("]").toString();
        }
        if (c.getName().startsWith("java.") || depth > 3) return String.valueOf(o);
        StringBuilder sb = new StringBuilder(c.getSimpleName()).append("{");
        for (Field f : c.getDeclaredFields()) {
            if (java.lang.reflect.Modifier.isStatic(f.getModifiers())) continue;
            f.setAccessible(true);
            sb.append(f.getName()).append("=").append(dump(f.get(o), depth + 1)).append(" ");
        }
        return sb.append("}").toString();
    }

    static Method find(Class<?> c, String name, int argc) {
        for (Method m : c.getMethods())
            if (m.getName().equals(name) && m.getParameterCount() == argc) return m;
        throw new RuntimeException("no " + name + "/" + argc);
    }

    public static void main(String[] a) throws Exception {
        ClassLoader cl = new dalvik.system.DexClassLoader(a[0], "/data/local/tmp/ovt/oat", null,
                ExtendTest.class.getClassLoader());
        Class<?> lsm = Class.forName("com.qualcomm.listen.ListenSoundModel", true, cl);
        Class<?> types = Class.forName("com.qualcomm.listen.ListenTypes", true, cl);

        byte[] uim = read(a[1]);
        ByteBuffer sm = ByteBuffer.allocate(uim.length);
        sm.put(uim);
        sm.rewind();

        Object smi = find(lsm, "query", 1).invoke(null, sm);
        sm.rewind();
        log("query info=" + dump(smi, 0));
        String keyword = null;
        for (int i = 4; i < a.length; i++) if (a[i].startsWith("kw=")) keyword = a[i].substring(3);
        if (keyword == null && smi != null) {
            Field kf = smi.getClass().getField("keywordInfo");
            Object arr = kf.get(smi);
            if (arr != null && Array.getLength(arr) > 0)
                keyword = (String) Array.get(arr, 0).getClass().getField("keywordPhrase").get(Array.get(arr, 0));
        }
        String user = a[3];
        log("keyword=" + keyword + " user=" + user);

        int nrec = 0;
        for (int i = 4; i < a.length; i++) if (a[i].endsWith(".pcm")) nrec++;
        ShortBuffer[] recs = new ShortBuffer[nrec];
        int k = 0;
        for (int i = 4; i < a.length; i++) {
            if (!a[i].endsWith(".pcm")) continue;
            byte[] pcm = read(a[i]);
            ShortBuffer sb = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
            short[] s = new short[sb.remaining()];
            sb.get(s);
            recs[k++] = ShortBuffer.wrap(s);
        }
        log("recordings=" + nrec);

        int size = (Integer) find(lsm, "getSizeWhenExtended", 3).invoke(null, sm, keyword, user);
        log("sizeWhenExtended=" + size);
        sm.rewind();
        if (size <= 0) return;
        ByteBuffer out = ByteBuffer.allocate(size);
        Object conf = Class.forName("com.qualcomm.listen.ListenTypes$ConfidenceData", true, cl)
                .getDeclaredConstructor().newInstance();
        int ret = (Integer) find(lsm, "extend", 7).invoke(null, sm, keyword, user, nrec, recs, out, conf);
        log("extend ret=" + ret + " conf=" + dump(conf, 0));
        if (ret != 0) return;
        out.rewind();
        byte[] o = new byte[out.remaining()];
        out.get(o);
        try (FileOutputStream fo = new FileOutputStream(a[2])) {
            fo.write(o);
        }
        log("wrote " + a[2] + " " + o.length);
        System.exit(0);
    }
}
