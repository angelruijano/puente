package cl.hazlo.puente;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Alarma cada 15 min (cambia el identificador Bluetooth) y botón "Lo encontré". */
public class RotateReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        if ("cl.hazlo.puente.STOP_RING".equals(i.getAction())) { Ring.stop(c); return; }
        NotifListener l = NotifListener.instance;
        if (l != null) l.ble().rotate();
    }
}
