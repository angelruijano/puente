package cl.hazlo.puente;

import android.app.Activity;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        WifiDebug.apply(this);
        WifiDebug.schedule(this);
        ClipProvider.dir(this);
    }

    @Override protected void onResume() {
        super.onResume();
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setGravity(Gravity.CENTER);
        int pad = (int) (32 * getResources().getDisplayMetrics().density);
        l.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Puente");
        title.setTextSize(40);
        title.setTypeface(Typeface.create("sans-serif-light", Typeface.NORMAL));
        title.setGravity(Gravity.CENTER);

        TextView body = new TextView(this);
        body.setTextSize(16);
        body.setGravity(Gravity.CENTER);
        body.setPadding(0, pad / 2, 0, 0);
        boolean perm = WifiDebug.canWrite(this);
        java.util.Set<String> trusted = WifiDebug.trustedSet(this);
        body.setText("Tu celular y tu Mac, conectados.\n\n"
                + (perm ? "✓" : "✗") + "  Permisos de reconexión (los concede install.sh)\n\n"
                + "Redes de confianza (tu casa):\n"
                + (trusted.isEmpty() ? "ninguna todavía" : String.join("\n", trusted)) + "\n\n"
                + "Solo en estas redes el Mac se conecta por Wi‑Fi y se puede encender la depuración inalámbrica.");

        String ssid = WifiDebug.currentSsid(this);
        android.widget.Button add = new android.widget.Button(this);
        if (ssid == null) {
            add.setText("Permitir ubicación para ver la red actual");
            add.setOnClickListener(v -> requestPermissions(new String[]{
                    android.Manifest.permission.ACCESS_FINE_LOCATION}, 1));
        } else if (trusted.contains(ssid)) {
            add.setText("Dejar de confiar en \"" + ssid + "\"");
            add.setOnClickListener(v -> { trusted.remove(ssid); WifiDebug.setTrusted(this, trusted); onResume(); });
        } else {
            add.setText("Confiar en \"" + ssid + "\"");
            add.setOnClickListener(v -> { trusted.add(ssid); WifiDebug.setTrusted(this, trusted); onResume(); });
        }

        l.addView(title);
        l.addView(body);
        l.addView(add);
        setContentView(l);
    }
}
