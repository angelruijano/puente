package cl.hazlo.puente;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertisingSet;
import android.bluetooth.le.AdvertisingSetCallback;
import android.bluetooth.le.AdvertisingSetParameters;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.os.SystemClock;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.UUID;
import java.util.function.Consumer;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Señal Bluetooth para el Mac:
 *  - Anuncio con un identificador que cambia cada 15 min (HMAC con una llave que solo conocen el Mac y el celular),
 *    para medir la distancia sin que terceros puedan rastrear el celular.
 *  - Servicio GATT que recibe comandos firmados del Mac (prender/apagar hotspot), aun sin Wi‑Fi en común.
 */
final class Ble {
    static final UUID SERVICE = UUID.fromString("6b1f3a52-9d2e-4c47-8a51-50756e746531");
    static final UUID COMMAND = UUID.fromString("6b1f3a52-9d2e-4c47-8a51-50756e746532");
    static final int MANUFACTURER = 0xFFFF;
    static final long WINDOW_S = 900;

    private final Context ctx;
    private final Consumer<JSONObject> report;
    private BluetoothLeAdvertiser advertiser;
    private AdvertisingSet set;
    private BluetoothGattServer gatt;
    private byte[] key;
    private long lastCmdTs;
    private final java.util.Map<String, byte[]> prepared = new java.util.HashMap<>();
    private boolean receiverOn;

    Ble(Context ctx, Consumer<JSONObject> report) { this.ctx = ctx; this.report = report; }

    private SharedPreferences prefs() { return ctx.getSharedPreferences("link", Context.MODE_PRIVATE); }

    synchronized void start() {
        String hex = prefs().getString("bleKey", null);
        if (hex == null) return;
        key = hexToBytes(hex);
        if (!receiverOn) {
            ctx.registerReceiver(btState, new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED);
            receiverOn = true;
        }
        BluetoothAdapter a = ctx.getSystemService(BluetoothManager.class).getAdapter();
        if (a == null || !a.isEnabled()) { state(false); return; }
        try {
            startGatt();
            startAdvertising(a);
            scheduleRotation();
        } catch (SecurityException e) {
            state(false);
        }
    }

    synchronized void stop() {
        try {
            if (set != null && advertiser != null) advertiser.stopAdvertisingSet(advCallback);
            if (gatt != null) gatt.close();
        } catch (SecurityException ignored) {}
        set = null; gatt = null; advertiser = null;
    }

    // ---------- anuncio ----------

    private final AdvertisingSetCallback advCallback = new AdvertisingSetCallback() {
        @Override public void onAdvertisingSetStarted(AdvertisingSet s, int txPower, int status) {
            set = s;
            state(status == ADVERTISE_SUCCESS);
        }
        @Override public void onAdvertisingSetStopped(AdvertisingSet s) { set = null; }
    };

    private void startAdvertising(BluetoothAdapter a) {
        if (set != null) { rotate(); return; }
        advertiser = a.getBluetoothLeAdvertiser();
        if (advertiser == null) { state(false); return; }
        AdvertisingSetParameters p = new AdvertisingSetParameters.Builder()
                .setLegacyMode(true).setConnectable(true).setScannable(true)
                .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
                .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM)
                .build();
        advertiser.startAdvertisingSet(p, data(), null, null, null, advCallback);
    }

    private AdvertiseData data() {
        return new AdvertiseData.Builder().setIncludeDeviceName(false).setIncludeTxPowerLevel(false)
                .addManufacturerData(MANUFACTURER, payload()).build();
    }

    /** 'P', versión 1 y 8 bytes de HMAC(llave, 'P' + ventana de 15 min). */
    private byte[] payload() {
        long w = System.currentTimeMillis() / 1000 / WINDOW_S;
        byte[] h = hmac(ByteBuffer.allocate(9).put((byte) 'P').putLong(w).array());
        byte[] out = new byte[10];
        out[0] = 'P'; out[1] = 1;
        System.arraycopy(h, 0, out, 2, 8);
        return out;
    }

    synchronized void rotate() {
        try { if (set != null) set.setAdvertisingData(data()); } catch (SecurityException ignored) {}
        scheduleRotation();
    }

    private void scheduleRotation() {
        AlarmManager am = ctx.getSystemService(AlarmManager.class);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 1, new Intent(ctx, RotateReceiver.class), PendingIntent.FLAG_IMMUTABLE);
        long now = System.currentTimeMillis();
        long next = (now / 1000 / WINDOW_S + 1) * WINDOW_S * 1000 + 2000; // justo al empezar la ventana siguiente
        am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + (next - now), pi);
    }

    private final BroadcastReceiver btState = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            int s = i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1);
            if (s == BluetoothAdapter.STATE_ON) { stop(); start(); }
            else if (s == BluetoothAdapter.STATE_TURNING_OFF || s == BluetoothAdapter.STATE_OFF) { stop(); state(false); }
        }
    };

    private void state(boolean on) {
        try { report.accept(new JSONObject().put("t", "ble").put("on", on)); } catch (Exception ignored) {}
    }

    // ---------- comandos del Mac ----------

    private void startGatt() {
        if (gatt != null) return;
        gatt = ctx.getSystemService(BluetoothManager.class).openGattServer(ctx, gattCallback);
        if (gatt == null) return;
        BluetoothGattService svc = new BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY);
        svc.addCharacteristic(new BluetoothGattCharacteristic(COMMAND,
                BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE));
        gatt.addService(svc);
    }

    private final BluetoothGattServerCallback gattCallback = new BluetoothGattServerCallback() {
        @Override
        public void onCharacteristicWriteRequest(BluetoothDevice d, int req, BluetoothGattCharacteristic ch,
                                                 boolean preparedWrite, boolean needResponse, int offset, byte[] value) {
            boolean ok = true;
            if (preparedWrite) {
                synchronized (prepared) {
                    byte[] cur = prepared.getOrDefault(d.getAddress(), new byte[0]);
                    byte[] n = Arrays.copyOf(cur, Math.max(cur.length, offset + value.length));
                    System.arraycopy(value, 0, n, offset, value.length);
                    prepared.put(d.getAddress(), n);
                }
            } else {
                ok = COMMAND.equals(ch.getUuid()) && command(value);
            }
            if (needResponse) respond(d, req, ok ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, value);
        }

        @Override
        public void onExecuteWrite(BluetoothDevice d, int req, boolean execute) {
            byte[] v;
            synchronized (prepared) { v = prepared.remove(d.getAddress()); }
            boolean ok = !execute || (v != null && command(v));
            respond(d, req, ok ? BluetoothGatt.GATT_SUCCESS : BluetoothGatt.GATT_WRITE_NOT_PERMITTED, 0, null);
        }
    };

    private void respond(BluetoothDevice d, int req, int status, int offset, byte[] value) {
        try { gatt.sendResponse(d, req, status, offset, value); } catch (Exception ignored) {}
    }

    /** [comando][segundos unix, 8 bytes][HMAC(llave, 'C' + comando + segundos), 16 bytes] */
    private synchronized boolean command(byte[] v) {
        if (key == null || v == null || v.length != 25) return false;
        long ts = ByteBuffer.wrap(v, 1, 8).getLong();
        long now = System.currentTimeMillis() / 1000;
        if (Math.abs(now - ts) > 120 || ts <= lastCmdTs) return false; // viejo o repetido
        byte[] expect = Arrays.copyOf(hmac(ByteBuffer.allocate(10).put((byte) 'C').put(v[0]).putLong(ts).array()), 16);
        if (!MessageDigest.isEqual(expect, Arrays.copyOfRange(v, 9, 25))) return false;
        lastCmdTs = ts;
        if (v[0] == 3) return WifiDebug.request(ctx); // el Mac necesita adb (p. ej. tras reiniciar el celular)
        final boolean on = v[0] == 1;
        if (v[0] != 1 && v[0] != 2) return false;
        new Thread(() -> daemon("{\"c\":\"hotspot\",\"on\":" + on + "}"), "hotspot").start();
        return true;
    }

    private JSONObject daemon(String cmd) { return DaemonClient.ask(ctx, cmd); }

    // ---------- utilidades ----------

    private byte[] hmac(byte[] msg) {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(new SecretKeySpec(key, "HmacSHA256"));
            return m.doFinal(msg);
        } catch (Exception e) { throw new IllegalStateException(e); }
    }

    private static byte[] hexToBytes(String h) {
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }
}
