package cl.hazlo.puente;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.drawable.Icon;
import android.media.MediaMetadata;
import android.media.VolumeProvider;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Base64;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/**
 * "Parlante" del Mac: lo que suena en el Mac aparece como reproductor nativo (panel y pantalla de bloqueo),
 * y los botones de volumen del celular controlan el volumen del Mac.
 * Lo arranca el ayudante (shell) con el puerto y token de su socket local.
 */
public class MediaService extends Service {
    private static final String CHANNEL = "mac_media";
    private static final int NOTIF_ID = 7;
    private static final int VOL_STEPS = 16; // como las teclas de volumen del Mac
    private static final long IDLE_STOP_MS = 30 * 60 * 1000; // pausado 30 min: ocultar

    private final Handler main = new Handler(Looper.getMainLooper());
    private MediaSession session;
    private VolumeProvider volume;
    private Bitmap art;
    private String artKey = "";
    private boolean playing;
    private boolean canSeek;
    private volatile int port;
    private volatile String token;
    private volatile OutputStream out;
    private volatile Thread conn;
    private volatile boolean stopping;

    private final Runnable idleStop = this::shutdown;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(CHANNEL, "Música del Mac", NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("Controla lo que suena en tu Mac");
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);

        session = new MediaSession(this, "PuenteMac");
        session.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() { cmd("play"); }
            @Override public void onPause() { cmd("pause"); }
            @Override public void onSkipToNext() { cmd("next"); }
            @Override public void onSkipToPrevious() { cmd("prev"); }
            @Override public void onStop() { cmd("pause"); }
            @Override public void onSeekTo(long pos) {
                try { send(new JSONObject().put("t", "media").put("c", "seek").put("to", pos / 1000.0)); } catch (Exception ignored) {}
            }
        });
        Intent open = new Intent(this, MainActivity.class);
        session.setSessionActivity(PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE));
        volume = new VolumeProvider(VolumeProvider.VOLUME_CONTROL_ABSOLUTE, VOL_STEPS, VOL_STEPS / 2) {
            @Override public void onSetVolumeTo(int v) { setVol(v); }
            @Override public void onAdjustVolume(int dir) { setVol(getCurrentVolume() + dir); }
        };
        session.setPlaybackToRemote(volume);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Hay que mostrar la notificación de inmediato (servicio en primer plano)
        startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        if (intent != null && intent.hasExtra("token")) {
            int p = intent.getIntExtra("port", 0);
            String t = intent.getStringExtra("token");
            boolean changed = p != port || !t.equals(token);
            port = p; token = t;
            if (changed || conn == null) connect();
        } else if (conn == null) {
            shutdown(); // reinicio del sistema sin datos: nada que mostrar
        }
        return START_NOT_STICKY;
    }

    // ---------- conexión con el ayudante ----------

    private void connect() {
        Thread old = conn;
        Thread t = new Thread(() -> {
            long deadline = SystemClock.elapsedRealtime() + 30000;
            final int myPort = port; final String myToken = token;
            while (!stopping && conn == Thread.currentThread() && SystemClock.elapsedRealtime() < deadline) {
                try (Socket s = new Socket()) {
                    s.connect(new InetSocketAddress("127.0.0.1", myPort), 3000);
                    s.setTcpNoDelay(true);
                    OutputStream os = s.getOutputStream();
                    os.write((myToken + "\n").getBytes(StandardCharsets.UTF_8));
                    os.flush();
                    out = os;
                    BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                    String line;
                    while ((line = in.readLine()) != null) {
                        final JSONObject m = new JSONObject(line);
                        main.post(() -> handle(m));
                        deadline = SystemClock.elapsedRealtime() + 30000;
                    }
                } catch (Exception ignored) {
                } finally {
                    out = null;
                }
                SystemClock.sleep(2000);
            }
            // Sin Mac por 30 s: quitar el reproductor
            if (conn == Thread.currentThread()) main.post(this::shutdown);
        }, "puente-media");
        conn = t;
        if (old != null) old.interrupt();
        t.start();
    }

    private void handle(JSONObject m) {
        if (stopping) return;
        if ("vol".equals(m.optString("t"))) {
            volume.setCurrentVolume(Math.round(m.optInt("v") * VOL_STEPS / 100f));
            return;
        }
        if (m.optBoolean("none")) { shutdown(); return; }

        String key = m.optString("artKey");
        if (m.has("art")) {
            byte[] b = Base64.decode(m.optString("art"), Base64.DEFAULT);
            art = BitmapFactory.decodeByteArray(b, 0, b.length);
            artKey = key;
        } else if (key.isEmpty()) {
            art = null; artKey = "";
        }

        String title = m.optString("title");
        String artist = m.optString("artist");
        String appName = m.optString("appName");
        double duration = m.optDouble("duration", 0);
        double elapsed = m.optDouble("elapsed", 0);
        double rate = m.optDouble("rate", 0);
        playing = m.optBoolean("playing");
        canSeek = duration > 0;

        MediaMetadata.Builder md = new MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist.isEmpty() ? appName : artist)
                .putString(MediaMetadata.METADATA_KEY_ALBUM, m.optString("album"));
        if (canSeek) md.putLong(MediaMetadata.METADATA_KEY_DURATION, (long) (duration * 1000));
        if (art != null) md.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, art);
        session.setMetadata(md.build());

        long actions = PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE | PlaybackState.ACTION_PLAY_PAUSE
                | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS;
        if (canSeek) actions |= PlaybackState.ACTION_SEEK_TO;
        session.setPlaybackState(new PlaybackState.Builder()
                .setActions(actions)
                .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                        (long) (elapsed * 1000), playing ? (float) (rate > 0 ? rate : 1) : 0f,
                        SystemClock.elapsedRealtime())
                .build());
        session.setActive(true);

        main.removeCallbacks(idleStop);
        if (!playing) main.postDelayed(idleStop, IDLE_STOP_MS);
        getSystemService(NotificationManager.class).notify(NOTIF_ID, buildNotification());
    }

    private Notification buildNotification() {
        MediaMetadata md = session.getController().getMetadata();
        String title = cleared ? "" : md != null ? md.getString(MediaMetadata.METADATA_KEY_TITLE) : "Tu Mac";
        String artist = cleared ? "" : md != null ? md.getString(MediaMetadata.METADATA_KEY_ARTIST) : "Conectando…";
        Notification.Builder b = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(Icon.createWithResource(this, getResources().getIdentifier("ic_stat_mac", "drawable", getPackageName())))
                .setContentTitle(title)
                .setContentText(artist)
                .setSubText("En tu Mac")
                .setOngoing(playing)
                .setShowWhen(false)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .setContentIntent(session.getController().getSessionActivity())
                .setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken()));
        if (art != null) b.setLargeIcon(art);
        return b.build();
    }

    // ---------- hacia el Mac ----------

    private void cmd(String c) {
        try { send(new JSONObject().put("t", "media").put("c", c)); } catch (Exception ignored) {}
    }

    private void setVol(int steps) {
        steps = Math.max(0, Math.min(VOL_STEPS, steps));
        volume.setCurrentVolume(steps);
        try { send(new JSONObject().put("t", "setvol").put("v", Math.round(steps * 100f / VOL_STEPS))); } catch (Exception ignored) {}
    }

    private void send(JSONObject m) {
        final OutputStream os = out;
        if (os == null) return;
        final byte[] b = (m.toString() + "\n").getBytes(StandardCharsets.UTF_8);
        new Thread(() -> { try { synchronized (os) { os.write(b); os.flush(); } } catch (Exception ignored) {} }).start();
    }

    private void shutdown() {
        if (stopping) return;
        stopping = true;
        Thread t = conn; conn = null;
        if (t != null) t.interrupt();
        main.removeCallbacks(idleStop);
        // El widget de música de Nothing guarda la última notificación que vio: publicar una
        // vacía y esperar un momento antes de quitarla, para que no quede la carátula pegada.
        clearSession();
        art = null;
        cleared = true;
        try { getSystemService(NotificationManager.class).notify(NOTIF_ID, buildNotification()); } catch (Exception ignored) {}
        main.postDelayed(() -> {
            session.setActive(false);
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        }, 1500);
    }

    private boolean cleared = false;

    /** Avisar a widgets y controles que ya no suena nada, para que no quede la última carátula. */
    private void clearSession() {
        try {
            session.setPlaybackState(new android.media.session.PlaybackState.Builder()
                    .setState(android.media.session.PlaybackState.STATE_NONE, 0, 0f).setActions(0).build());
            session.setMetadata(null);
        } catch (Exception ignored) {}
    }

    @Override
    public void onDestroy() {
        stopping = true;
        Thread t = conn; conn = null;
        if (t != null) t.interrupt();
        clearSession();
        session.setActive(false);
        session.release();
        super.onDestroy();
    }
}
