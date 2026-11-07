package cl.hazlo.puente;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.graphics.drawable.Icon;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;

/**
 * "Buscar mi celular": suena fuerte por el canal de alarma (se oye aunque esté en silencio),
 * vibra y parpadea el flash hasta que lo encuentres o pase un minuto.
 */
final class Ring {
    private static final String CHANNEL = "find";
    private static final int NOTIF_ID = 77;
    private static final long MAX_MS = 60000;

    private static MediaPlayer player;
    private static int oldVolume = -1;
    private static boolean torchOn;
    private static String torchId;
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static Runnable blink, autoStop;
    static Runnable onStop;

    static synchronized boolean ringing() { return player != null; }

    static void start(Context c) {
        main.post(() -> startOnMain(c.getApplicationContext()));
    }

    private static synchronized void startOnMain(Context c) {
        if (player != null) return;
        AudioManager am = c.getSystemService(AudioManager.class);
        oldVolume = am.getStreamVolume(AudioManager.STREAM_ALARM);
        try { am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0); } catch (Exception ignored) {}

        Uri sound = RingtoneManager.getActualDefaultRingtoneUri(c, RingtoneManager.TYPE_RINGTONE);
        if (sound == null) sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
        try {
            MediaPlayer mp = new MediaPlayer();
            mp.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build());
            mp.setDataSource(c, sound);
            mp.setLooping(true);
            mp.prepare();
            mp.start();
            player = mp;
        } catch (Exception e) {
            android.util.Log.w("Puente", "ring", e);
            player = new MediaPlayer(); // marcar como sonando igual (vibración y flash)
        }

        Vibrator v = c.getSystemService(Vibrator.class);
        if (v != null) v.vibrate(VibrationEffect.createWaveform(new long[]{0, 600, 400}, 0),
                new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());

        CameraManager cm = c.getSystemService(CameraManager.class);
        try {
            for (String id : cm.getCameraIdList()) {
                Boolean f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
                if (Boolean.TRUE.equals(f)) { torchId = id; break; }
            }
        } catch (Exception ignored) {}
        blink = new Runnable() {
            @Override public void run() {
                torchOn = !torchOn;
                if (torchId != null) try { cm.setTorchMode(torchId, torchOn); } catch (Exception ignored) {}
                Glyph.all(torchOn ? 1f : 0f);
                main.postDelayed(this, 500);
            }
        };
        Glyph.open(c, null);
        main.post(blink);
        autoStop = () -> stop(c);
        main.postDelayed(autoStop, MAX_MS);
        notify(c);
    }

    static void stop(Context c) {
        main.post(() -> stopOnMain(c.getApplicationContext()));
    }

    private static synchronized void stopOnMain(Context c) {
        if (player == null) return;
        try { player.stop(); } catch (Exception ignored) {}
        player.release();
        player = null;
        if (blink != null) main.removeCallbacks(blink);
        if (autoStop != null) main.removeCallbacks(autoStop);
        if (torchId != null) try { c.getSystemService(CameraManager.class).setTorchMode(torchId, false); } catch (Exception ignored) {}
        torchOn = false;
        Glyph.close(c);
        Vibrator v = c.getSystemService(Vibrator.class);
        if (v != null) v.cancel();
        if (oldVolume >= 0) try { c.getSystemService(AudioManager.class).setStreamVolume(AudioManager.STREAM_ALARM, oldVolume, 0); } catch (Exception ignored) {}
        c.getSystemService(NotificationManager.class).cancel(NOTIF_ID);
        Runnable r = onStop;
        if (r != null) r.run();
    }

    private static void notify(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Buscar mi celular", NotificationManager.IMPORTANCE_HIGH);
        ch.setSound(null, null);
        ch.setBypassDnd(true);
        nm.createNotificationChannel(ch);
        PendingIntent stop = PendingIntent.getBroadcast(c, 1,
                new Intent(c, RotateReceiver.class).setAction("cl.hazlo.puente.STOP_RING"), PendingIntent.FLAG_IMMUTABLE);
        Notification n = new Notification.Builder(c, CHANNEL)
                .setSmallIcon(Icon.createWithResource(c, c.getResources().getIdentifier("ic_stat_mac", "drawable", c.getPackageName())))
                .setContentTitle("Tu Mac está buscando este celular")
                .setContentText("Toca para dejar de sonar")
                .setCategory(Notification.CATEGORY_ALARM)
                .setOngoing(true)
                .setContentIntent(stop)
                .setDeleteIntent(stop)
                .addAction(new Notification.Action.Builder(null, "Lo encontré", stop).build())
                .build();
        nm.notify(NOTIF_ID, n);
    }
}
