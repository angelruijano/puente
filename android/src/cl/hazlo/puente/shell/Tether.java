package cl.hazlo.puente.shell;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Hotspot del celular vía las APIs internas (shell tiene TETHER_PRIVILEGED y NETWORK_SETTINGS). */
final class Tether {
    private static final String PKG = "com.android.shell";
    private static final int TETHERING_WIFI = 0;

    private static Object service(String name, String iface) throws Exception {
        IBinder b = (IBinder) Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, name);
        return Class.forName(iface + "$Stub").getMethod("asInterface", IBinder.class).invoke(null, b);
    }

    private static Method method(Object o, String name, int params) throws NoSuchMethodException {
        for (Method m : o.getClass().getMethods()) if (m.getName().equals(name) && m.getParameterCount() == params) return m;
        throw new NoSuchMethodException(name);
    }

    /** Listener AIDL oneway onResult(int): devuelve el código de resultado (0 = OK). */
    private static Object resultListener(int[] out, CountDownLatch done) throws Exception {
        final Binder b = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                if (code == IBinder.FIRST_CALL_TRANSACTION) {
                    try { data.enforceInterface("android.net.IIntResultListener"); } catch (Exception ignored) {}
                    out[0] = data.readInt(); done.countDown(); return true;
                }
                try { return super.onTransact(code, data, reply, flags); } catch (Exception e) { return false; }
            }
        };
        Class<?> iface = Class.forName("android.net.IIntResultListener");
        return Proxy.newProxyInstance(iface.getClassLoader(), new Class<?>[]{iface}, (p, m, a) -> {
            switch (m.getName()) {
                case "asBinder": return b;
                case "onResult": out[0] = (Integer) a[0]; done.countDown(); return null;
                case "hashCode": return System.identityHashCode(p);
                case "equals": return p == a[0];
            }
            return null;
        });
    }

    static int start() throws Exception {
        Object tc = service("tethering", "android.net.ITetheringConnector");
        Class<?> pc = Class.forName("android.net.TetheringRequestParcel");
        Object req = pc.getConstructor().newInstance();
        set(req, "tetheringType", TETHERING_WIFI);
        set(req, "exemptFromEntitlementCheck", true);
        set(req, "showProvisioningUi", false);
        set(req, "connectivityScope", 1); // CONNECTIVITY_SCOPE_GLOBAL
        int[] r = {-1};
        CountDownLatch done = new CountDownLatch(1);
        method(tc, "startTethering", 4).invoke(tc, req, PKG, null, resultListener(r, done));
        done.await(10, TimeUnit.SECONDS);
        return r[0];
    }

    static int stop() throws Exception {
        Object tc = service("tethering", "android.net.ITetheringConnector");
        int[] r = {-1};
        CountDownLatch done = new CountDownLatch(1);
        method(tc, "stopTethering", 4).invoke(tc, TETHERING_WIFI, PKG, null, resultListener(r, done));
        done.await(10, TimeUnit.SECONDS);
        return r[0];
    }

    /** 13 = WIFI_AP_STATE_ENABLED */
    static boolean isOn() throws Exception {
        Object wm = service("wifi", "android.net.wifi.IWifiManager");
        return (Integer) method(wm, "getWifiApEnabledState", 0).invoke(wm) == 13;
    }

    /** {ssid, passphrase} del hotspot configurado por el usuario. */
    static String[] credentials() throws Exception {
        Object wm = service("wifi", "android.net.wifi.IWifiManager");
        Object cfg = method(wm, "getSoftApConfiguration", 0).invoke(wm);
        Object ssid = cfg.getClass().getMethod("getSsid").invoke(cfg);
        Object pass = cfg.getClass().getMethod("getPassphrase").invoke(cfg);
        return new String[]{ssid == null ? "" : ssid.toString(), pass == null ? "" : pass.toString()};
    }

    private static void set(Object o, String field, Object v) {
        try { Field f = o.getClass().getField(field); f.set(o, v); } catch (Exception ignored) {}
    }
}
