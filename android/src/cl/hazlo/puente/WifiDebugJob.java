package cl.hazlo.puente;

import android.app.job.JobParameters;
import android.app.job.JobService;

public final class WifiDebugJob extends JobService {
    @Override public boolean onStartJob(JobParameters p) {
        WifiDebug.apply(this);
        if (p.getJobId() == 1) {
            // Se reprograma para la próxima vez que vuelva el Wi‑Fi
            new android.os.Handler(getMainLooper()).postDelayed(() -> WifiDebug.schedule(this), 60_000);
        }
        return false;
    }
    @Override public boolean onStopJob(JobParameters p) { return true; }
}
