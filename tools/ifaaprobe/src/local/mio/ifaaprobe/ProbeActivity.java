package local.mio.ifaaprobe;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * Minimal real-app probe for the IFAA service. app_process cannot bind services
 * (AMS has no package for the caller), so this APK is installed temporarily and
 * launched with am start. Results go to logcat and to the app's external files.
 */
public class ProbeActivity extends Activity {
    private static final String TAG = "IfaaProbe";
    private static final String PKG = "org.ifaa.aidl.manager";
    private static final String ACTION = "org.ifaa.aidl.manager.IfaaManagerService";
    private static final String DESCRIPTOR = "org.ifaa.aidl.manager.IfaaManagerService";

    private boolean bound;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            Log.i(TAG, "connected " + name + " binder=" + binder);
            new Thread(() -> {
                probe(binder);
                runOnUiThread(() -> {
                    try {
                        unbindService(connection);
                    } catch (Throwable ignored) {
                    }
                    finish();
                });
            }, "ifaa-probe").start();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            Log.w(TAG, "disconnected " + name);
        }

        @Override
        public void onBindingDied(ComponentName name) {
            Log.w(TAG, "binding died " + name);
        }

        @Override
        public void onNullBinding(ComponentName name) {
            Log.e(TAG, "null binding " + name);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Intent intent = new Intent(ACTION).setPackage(PKG);
        try {
            bound = bindService(intent, connection, Context.BIND_AUTO_CREATE);
            Log.i(TAG, "bindService(" + intent + ") returned " + bound);
            write("bindService returned " + bound);
        } catch (Throwable error) {
            Log.e(TAG, "bindService threw", error);
            write("bindService threw " + error);
        }
        new Thread(() -> {
            try {
                Thread.sleep(15000);
            } catch (InterruptedException ignored) {
            }
            if (!bound) {
                Log.e(TAG, "not connected after 15s, finishing");
                write("not connected after 15s");
                runOnUiThread(this::finish);
            }
        }, "ifaa-probe-timeout").start();
    }

    private void probe(IBinder binder) {
        int support = transactInt(binder, 1);
        Log.i(TAG, "T1 getSupportBIOTypes=" + support);
        write("T1 getSupportBIOTypes=" + support);
        String model = transactString(binder, 3);
        Log.i(TAG, "T3 getDeviceModel=" + model);
        write("T3 getDeviceModel=" + model);
        int[] ids = transactIntArray(binder, 9, 1);
        Log.i(TAG, "T9 getIDList(authType=1)=" + Arrays.toString(ids));
        write("T9 getIDList(authType=1)=" + Arrays.toString(ids));
        int[] fodIds = transactIntArray(binder, 9, 16);
        Log.i(TAG, "T9 getIDList(authType=16)=" + Arrays.toString(fodIds));
        write("T9 getIDList(authType=16)=" + Arrays.toString(fodIds));
        byte[] response = transactBytes(binder, 4, new byte[0]);
        Log.i(TAG, "T4 processCmd(empty)=" + Arrays.toString(response));
        write("T4 processCmd(empty)=" + Arrays.toString(response));
    }

    private int transactInt(IBinder binder, int code) {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            binder.transact(code, data, reply, 0);
            reply.readException();
            return reply.readInt();
        } catch (Throwable error) {
            Log.e(TAG, "transaction " + code + " failed", error);
            write("transaction " + code + " failed " + error);
            return Integer.MIN_VALUE;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private String transactString(IBinder binder, int code) {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            binder.transact(code, data, reply, 0);
            reply.readException();
            return reply.readString();
        } catch (Throwable error) {
            Log.e(TAG, "transaction " + code + " failed", error);
            write("transaction " + code + " failed " + error);
            return "<error:" + error + ">";
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private int[] transactIntArray(IBinder binder, int code, int authType) {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            data.writeInt(authType);
            binder.transact(code, data, reply, 0);
            reply.readException();
            return reply.createIntArray();
        } catch (Throwable error) {
            Log.e(TAG, "transaction " + code + " authType=" + authType + " failed", error);
            write("transaction " + code + " authType=" + authType + " failed " + error);
            return null;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private byte[] transactBytes(IBinder binder, int code, byte[] request) {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            data.writeByteArray(request);
            binder.transact(code, data, reply, 0);
            reply.readException();
            byte[] response = reply.createByteArray();
            if (reply.dataAvail() > 0) {
                byte[] echo = reply.createByteArray();
                Log.i(TAG, "T4 echoed request=" + Arrays.toString(echo));
            }
            return response;
        } catch (Throwable error) {
            Log.e(TAG, "transaction " + code + " failed", error);
            write("transaction " + code + " failed " + error);
            return null;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private void write(String line) {
        Log.i(TAG, line);
        try {
            File dir = getExternalFilesDir(null);
            if (dir == null) {
                return;
            }
            if (!dir.exists() && !dir.mkdirs()) {
                return;
            }
            try (FileOutputStream out = new FileOutputStream(new File(dir, "probe.txt"), true)) {
                out.write((line + "\n").getBytes(StandardCharsets.UTF_8));
            }
        } catch (Throwable error) {
            Log.e(TAG, "write failed", error);
        }
    }
}
