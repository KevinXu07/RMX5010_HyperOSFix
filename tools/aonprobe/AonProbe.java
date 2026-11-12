import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Root test tool for vendor.oplus.hardware.camera.aon.IAONService (V1).
 * Usage: app_process -cp probe.dex / AonProbe [serviceType=4] [seconds=25] [sensorId=-1]
 */
public final class AonProbe {
    static final String SERVICE = "vendor.oplus.hardware.camera.aon.IAONService/default";
    static final String DESC = "vendor.oplus.hardware.camera.aon.IAONService";
    static final String CB_DESC = "vendor.oplus.hardware.camera.aon.IAONServiceCallBack";
    static final String CB_HASH = "8d0c8f312ebf7c4e6a50ebba9432d2bde93c09c2";

    static final class Sensor {
        int d, e, f, g;
        List<int[]> frames = new ArrayList<>(); // {w?, h?, fps...}
        String raw;
    }

    public static void main(String[] args) throws Exception {
        int serviceType = args.length > 0 ? Integer.decode(args[0]) : 4;
        int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 25;
        int forcedSensor = args.length > 2 ? Integer.parseInt(args[2]) : -1;

        Method getService = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class);
        IBinder svc = (IBinder) getService.invoke(null, SERVICE);
        log("service=" + svc);
        if (svc == null) return;

        List<Sensor> sensors = getSensors(svc);
        for (Sensor s : sensors) log("sensor " + s.raw);

        Binder cb = new Binder() {
            @Override
            protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                try {
                    if (code == 0xfffffe) { reply.writeNoException(); reply.writeString(CB_HASH); return true; }
                    if (code == 0xffffff) { reply.writeNoException(); reply.writeInt(1); return true; }
                    if (code == INTERFACE_TRANSACTION) { reply.writeString(CB_DESC); return true; }
                    data.enforceInterface(CB_DESC);
                    long handle = data.readLong();
                    if (code == 1) {
                        log("onAONEvent handle=" + handle + " " + readCallbackInfo(data));
                    } else if (code == 2) {
                        log("onAONSensorEvent handle=" + handle + " " + readInts(data, "sensorState"));
                    } else {
                        log("unknown callback code " + code);
                    }
                    if (reply != null && (flags & FLAG_ONEWAY) == 0) reply.writeNoException();
                    return true;
                } catch (Throwable t) {
                    log("callback parse error " + t);
                    return true;
                }
            }
        };
        cb.attachInterface(null, CB_DESC);
        // Vendor HALs may only call back into binders marked VINTF-stable.
        Method mark = Binder.class.getDeclaredMethod("markVintfStability");
        mark.setAccessible(true);
        mark.invoke(cb);

        long handle;
        {
            Parcel d = Parcel.obtain(), r = Parcel.obtain();
            d.writeInterfaceToken(DESC);
            d.writeStrongBinder(cb);
            d.writeInt(0xf);
            svc.transact(1, d, r, 0);
            r.readException();
            handle = r.readLong();
            d.recycle(); r.recycle();
        }
        log("registerClient handle=" + handle);

        Sensor pick = null;
        for (Sensor s : sensors) if (forcedSensor < 0 ? pick == null : s.d == forcedSensor) pick = s;
        if (pick == null) { log("no sensor"); return; }
        int w = 0, h = 0, fps = 10;
        for (int[] fr : pick.frames) {
            if (fr.length >= 2 && fr[0] == 640 && fr[1] == 480) { w = 640; h = 480; }
        }
        if (w == 0) for (int[] fr : pick.frames) if (fr.length >= 2 && fr[0] == 320 && fr[1] == 240) { w = 320; h = 240; }
        if (w == 0 && !pick.frames.isEmpty()) { w = pick.frames.get(0)[0]; h = pick.frames.get(0)[1]; }
        // sensorId, width, height, frameRate, framesPerDelivery, deliveryPeriodMs, serviceType, deliveryMode
        int[] cfg = {pick.d, w, h, fps, fps, 1000, serviceType, 1};
        log("subscribe cfg=" + Arrays.toString(cfg));
        {
            Parcel d = Parcel.obtain(), r = Parcel.obtain();
            d.writeInterfaceToken(DESC);
            d.writeLong(handle);
            d.writeInt(1);
            d.writeInt(4 + cfg.length * 4);
            for (int v : cfg) d.writeInt(v);
            svc.transact(3, d, r, 0);
            r.readException();
            d.recycle(); r.recycle();
        }
        call(svc, 4, handle, serviceType, "startService");
        log("started, watching " + seconds + "s");
        Thread.sleep(seconds * 1000L);
        call(svc, 5, handle, serviceType, "stopService");
        call(svc, 6, handle, null, "unsubscribeSensor");
        call(svc, 7, handle, null, "unregisterClient");
        log("done");
        System.exit(0);
    }

    static void call(IBinder svc, int code, long handle, Integer arg, String name) {
        Parcel d = Parcel.obtain(), r = Parcel.obtain();
        try {
            d.writeInterfaceToken(DESC);
            d.writeLong(handle);
            if (arg != null) d.writeInt(arg);
            svc.transact(code, d, r, 0);
            r.readException();
            log(name + " ok");
        } catch (Throwable t) {
            log(name + " failed " + t);
        } finally {
            d.recycle(); r.recycle();
        }
    }

    static List<Sensor> getSensors(IBinder svc) throws Exception {
        Parcel d = Parcel.obtain(), r = Parcel.obtain();
        d.writeInterfaceToken(DESC);
        svc.transact(2, d, r, 0);
        r.readException();
        int n = r.readInt();
        List<Sensor> out = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            if (r.readInt() == 0) continue;
            int start = r.dataPosition();
            int size = r.readInt();
            Sensor s = new Sensor();
            s.d = r.readInt(); s.e = r.readInt(); s.f = r.readInt(); s.g = r.readInt();
            StringBuilder sb = new StringBuilder("{" + s.d + "," + s.e + "," + s.f + "," + s.g + ", frames=[");
            int fn = r.readInt();
            for (int j = 0; j < fn; j++) {
                if (r.readInt() == 0) continue;
                int fs = r.dataPosition();
                int fsize = r.readInt();
                int a = r.readInt(), b = r.readInt();
                int[] rates = r.createIntArray();
                int[] fr = new int[2 + (rates == null ? 0 : rates.length)];
                fr[0] = a; fr[1] = b;
                if (rates != null) System.arraycopy(rates, 0, fr, 2, rates.length);
                s.frames.add(fr);
                sb.append(Arrays.toString(fr));
                r.setDataPosition(fs + fsize);
            }
            s.raw = sb.append("]}").toString();
            r.setDataPosition(start + size);
            out.add(s);
        }
        d.recycle(); r.recycle();
        return out;
    }

    static String readInts(Parcel p, String what) {
        if (p.readInt() == 0) return what + "=null";
        int start = p.dataPosition(), size = p.readInt();
        StringBuilder sb = new StringBuilder(what + "{");
        while (p.dataPosition() < start + size) sb.append(p.readInt()).append(',');
        return sb.append('}').toString();
    }

    static String readCallbackInfo(Parcel p) {
        if (p.readInt() == 0) return "info=null";
        int start = p.dataPosition(), size = p.readInt();
        int type = p.readInt();
        StringBuilder sb = new StringBuilder("serviceType=0x" + Integer.toHexString(type) + " results=");
        int n = p.readInt();
        for (int i = 0; i < n; i++) {
            if (p.readInt() == 0) { sb.append("null;"); continue; }
            int rs = p.dataPosition(), rsize = p.readInt();
            int id = p.readInt();
            sb.append("[id=").append(id).append(' ');
            if (p.readInt() != 0) sb.append(readUnion(p));
            sb.append("] ");
            p.setDataPosition(rs + rsize);
        }
        p.setDataPosition(start + size);
        return sb.toString();
    }

    static String readUnion(Parcel p) {
        int tag = p.readInt();
        switch (tag) {
            case 0: return "byte=" + p.readByte();
            case 1: { byte[] b = p.createByteArray(); return "bytes(" + (b == null ? -1 : b.length) + ")"; }
            case 2: return "int=" + p.readInt();
            case 3: return "ints=" + Arrays.toString(p.createIntArray());
            case 4: return "str=" + p.readString();
            case 5: return "float=" + p.readFloat();
            case 6: return "floats=" + Arrays.toString(p.createFloatArray());
            case 7: return "double=" + p.readDouble();
            case 8: return "doubles=" + Arrays.toString(p.createDoubleArray());
            case 9: return "bool=" + (p.readInt() != 0);
            default: return "tag?" + tag;
        }
    }

    static void log(String s) {
        System.out.println(System.currentTimeMillis() % 100000 + " " + s);
    }
}
