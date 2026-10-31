import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;

public final class VideoServiceProxy extends Binder {
    private static final String NAME =
            "vendor.xiaomi.hardware.videoservice.IVideoService/default";
    private static final String DESCRIPTOR =
            "vendor.xiaomi.hardware.videoservice.IVideoService";
    private static final String LISTENER_DESCRIPTOR =
            "vendor.xiaomi.hardware.videoservice.IVideoServiceListener";
    private static final String TARGET_NAME =
            "vendor.qti.hardware.embmssl.IEmbms/default";
    private static final String TARGET_DESCRIPTOR =
            "vendor.qti.hardware.embmssl.IEmbms";
    private static final Object LOCK = new Object();
    private static Parcel sPendingRelease;
    private static IBinder sListener;

    public static void main(String[] args) throws Exception {
        VideoServiceProxy proxy = new VideoServiceProxy();
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object ok = sm.getMethod("addService", String.class, IBinder.class)
                .invoke(null, NAME, proxy);
        System.out.println("VideoServiceProxy registered=" + ok);
        Thread.sleep(Long.MAX_VALUE);
    }

    @Override
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
            throws RemoteException {
        if (code == INTERFACE_TRANSACTION) {
            reply.writeString(DESCRIPTOR);
            return true;
        }
        IBinder target = getService(TARGET_NAME);
        if (target == null) {
            System.out.println("proxy target missing code=" + code);
            return false;
        }

        if (code == 5 || code == 7) {
            reply.writeNoException();
            reply.writeIntArray(new int[0]);
            System.out.println("proxy vpp off code=" + code);
            return true;
        }
        if (code == 6) {
            reply.writeNoException();
            reply.writeStringArray(new String[0]);
            System.out.println("proxy vpp off code=" + code);
            return true;
        }
        if (code == 8) {
            reply.writeNoException();
            reply.writeCharArray(new char[0]);
            System.out.println("proxy vpp off code=" + code);
            return true;
        }
        if (code == 10 || code == 19 || code == 34) {
            reply.writeNoException();
            reply.writeInt(0);
            System.out.println("proxy vpp off code=" + code);
            return true;
        }

        if (code == 11) {
            rememberListener(data);
        }

        if (code == 12) {
            // The V12 client releases the listener before clearCodecInfo /
            // reportCodecStatus.  Deliver the frame-capture stop callbacks
            // while the listener is still alive, then defer the real release.
            notifyListener(4); // onStopFrameCapture
            notifyListener(5); // onReleaseFrameCapture
            data.enforceInterface(DESCRIPTOR);
            Parcel payload = Parcel.obtain();
            int off = data.dataPosition();
            payload.appendFrom(data, off, data.dataSize() - off);
            synchronized (LOCK) {
                if (sPendingRelease != null) sPendingRelease.recycle();
                sPendingRelease = payload;
            }
            reply.writeNoException();
            reply.writeInt(0);
            System.out.println("proxy deferred releaseListener");
            return true;
        }

        data.enforceInterface(DESCRIPTOR);
        Parcel out = Parcel.obtain();
        boolean result;
        try {
            out.writeInterfaceToken(TARGET_DESCRIPTOR);
            int off = data.dataPosition();
            out.appendFrom(data, off, data.dataSize() - off);
            result = target.transact(code, out, reply, flags);
        } finally {
            out.recycle();
        }

        if (code == 2 || code == 20) {
            Parcel pending;
            synchronized (LOCK) {
                pending = sPendingRelease;
                sPendingRelease = null;
            }
            if (pending != null) {
                Parcel rel = Parcel.obtain();
                Parcel relReply = Parcel.obtain();
                try {
                    rel.writeInterfaceToken(TARGET_DESCRIPTOR);
                    rel.appendFrom(pending, 0, pending.dataSize());
                    target.transact(12, rel, relReply, 0);
                    System.out.println("proxy forwarded deferred releaseListener");
                } catch (Throwable t) {
                    System.out.println("proxy deferred release failed " + t);
                } finally {
                    rel.recycle();
                    relReply.recycle();
                    pending.recycle();
                }
            }
        }
        return result;
    }

    private static void rememberListener(Parcel data) {
        Parcel copy = Parcel.obtain();
        try {
            copy.appendFrom(data, 0, data.dataSize());
            copy.setDataPosition(0);
            copy.enforceInterface(DESCRIPTOR);
            copy.readInt();
            copy.readInt();
            IBinder listener = copy.readStrongBinder();
            if (listener != null) {
                sListener = listener;
                System.out.println("proxy remembered listener");
            }
        } catch (Throwable t) {
            System.out.println("proxy rememberListener failed " + t);
        } finally {
            copy.recycle();
        }
    }

    private static void notifyListener(int code) {
        IBinder listener = sListener;
        if (listener == null) {
            return;
        }
        Parcel d = Parcel.obtain();
        Parcel r = Parcel.obtain();
        try {
            d.writeInterfaceToken(LISTENER_DESCRIPTOR);
            boolean ok = listener.transact(code, d, r, 0);
            System.out.println("listener code=" + code + " ok=" + ok);
        } catch (Throwable t) {
            System.out.println("listener code=" + code + " failed " + t);
        } finally {
            d.recycle();
            r.recycle();
        }
    }

    private static IBinder getService(String name) {
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            return (IBinder) sm.getMethod("getService", String.class).invoke(null, name);
        } catch (Throwable t) {
            return null;
        }
    }
}
