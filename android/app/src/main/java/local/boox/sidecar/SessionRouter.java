package local.boox.sidecar;

import android.os.SystemClock;
import org.json.JSONObject;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

final class SessionRouter {
    interface Listener {
        boolean current(int session);
        String discoveredEndpoint();
        void selected(Route route);
        void retrying(String message);
    }

    static final class Pairing {
        final String token, pin, hostId, usb, wifi, mode;
        Pairing(PairingStore.Record record) {
            token = record.token;
            pin = record.pin;
            hostId = record.hostId;
            usb = record.usb;
            wifi = record.wifi;
            mode = record.mode;
        }
    }

    static final class Route {
        final int session;
        final PinnedClient client;
        final String endpoint;
        final JSONObject status;
        Route(int session, PinnedClient client, String endpoint, JSONObject status) {
            this.session = session;
            this.client = client;
            this.endpoint = endpoint;
            this.status = status;
        }
    }

    private static final class Attempt {
        final int session;
        final Pairing pairing;
        final Listener listener;
        int retries;
        Attempt(int session, Pairing pairing, Listener listener) {
            this.session = session;
            this.pairing = pairing;
            this.listener = listener;
        }
    }

    private final ScheduledThreadPoolExecutor worker;
    private final ScheduledThreadPoolExecutor probeWorker = new ScheduledThreadPoolExecutor(1);
    private final AtomicBoolean probeBusy = new AtomicBoolean();
    private final AtomicReference<Route> verifiedUsb = new AtomicReference<>();
    private volatile Attempt attempt;
    private volatile PinnedClient selectingClient;
    private volatile PinnedClient probeClient;
    private volatile long nextProbeAt;

    SessionRouter(ScheduledThreadPoolExecutor worker) { this.worker = worker; }

    void start(int session, Pairing pairing, Listener listener) {
        stop();
        Attempt next = new Attempt(session, pairing, listener);
        attempt = next;
        worker.execute(() -> select(next));
    }

    private boolean current(Attempt candidate) {
        return candidate != null && attempt == candidate && candidate.listener.current(candidate.session);
    }

    private void select(Attempt active) {
        if (!current(active)) return;
        String failure = "Mac unavailable. Keep the Mac app open and press Connect there.";
        Pairing pairing = active.pairing;
        for (String endpoint : AutoRoutePolicy.candidates(pairing.mode, pairing.usb, pairing.wifi, active.listener.discoveredEndpoint())) {
            if (!current(active)) return;
            PinnedClient candidate = null;
            try {
                candidate = new PinnedClient(endpoint, pairing.token, pairing.pin);
                selectingClient = candidate;
                if (!current(active)) { candidate.cancel(); return; }
                if (pairing.usb.equals(endpoint)) candidate.setTimeouts(200, 500);
                JSONObject status = candidate.json("/api/status", null);
                validateHost(pairing, status);
                if (!current(active)) { candidate.cancel(); return; }
                candidate.setTimeouts(2500, 3500);
                active.listener.selected(new Route(active.session, candidate, endpoint, status));
                return;
            } catch (Exception exception) {
                if (candidate != null) candidate.cancel();
                failure = connectionError(exception);
            } finally {
                if (selectingClient == candidate) selectingClient = null;
            }
        }
        if (!current(active)) return;
        active.listener.retrying("Reconnecting · " + failure + "\nUSB and saved Wi-Fi retry automatically.");
        worker.schedule(() -> select(active), AutoRoutePolicy.retryDelay(active.retries++), TimeUnit.MILLISECONDS);
    }

    void activated(int session) {
        Attempt active = attempt;
        if (!current(active) || active.session != session) return;
        active.retries = 0;
        nextProbeAt = SystemClock.elapsedRealtime() + 10000;
    }

    void reconnect(int session) {
        Attempt active = attempt;
        if (!current(active) || active.session != session) return;
        clearVerifiedUsb();
        worker.schedule(() -> select(active), 300, TimeUnit.MILLISECONDS);
    }

    void networkChanged() { nextProbeAt = 0; }

    void maybeProbeUsb(int session, String endpoint) {
        Attempt active = attempt;
        long now = SystemClock.elapsedRealtime();
        if (!current(active) || active.session != session || !AutoRoutePolicy.shouldProbeUsb(active.pairing.mode, endpoint, active.pairing.usb, now, nextProbeAt)
                || !probeBusy.compareAndSet(false, true)) return;
        nextProbeAt = now + 10000;
        probeWorker.execute(() -> {
            PinnedClient probe = null;
            boolean accepted = false;
            try {
                if (!current(active)) return;
                probe = new PinnedClient(active.pairing.usb, active.pairing.token, active.pairing.pin);
                probeClient = probe;
                if (!current(active)) return;
                probe.setTimeouts(200, 300);
                JSONObject status = probe.json("/api/status", null);
                validateHost(active.pairing, status);
                if (!current(active)) return;
                probe.setTimeouts(2500, 3500);
                Route replacement = new Route(active.session, probe, active.pairing.usb, status);
                Route old = verifiedUsb.getAndSet(replacement);
                if (old != null) old.client.cancel();
                accepted = true;
                if (!current(active) && verifiedUsb.compareAndSet(replacement, null)) probe.cancel();
            } catch (Exception ignored) {
            } finally {
                if (!accepted && probe != null) probe.cancel();
                if (probeClient == probe) probeClient = null;
                probeBusy.set(false);
            }
        });
    }

    Route takeUsbUpgrade() { return verifiedUsb.getAndSet(null); }

    void stop() {
        attempt = null;
        PinnedClient selecting = selectingClient;
        if (selecting != null) selecting.cancel();
        PinnedClient probing = probeClient;
        if (probing != null) probing.cancel();
        clearVerifiedUsb();
    }

    private void clearVerifiedUsb() {
        Route route = verifiedUsb.getAndSet(null);
        if (route != null) route.client.cancel();
    }

    void close() {
        stop();
        probeWorker.shutdownNow();
    }

    static void validateHost(Pairing pairing, JSONObject status) throws Exception {
        if (status.optInt("protocol", -1) != 2) throw new Exception("Unsupported Mac protocol.");
        if (!AutoRoutePolicy.identityMatches(pairing.hostId, status.optString("host_id", "")))
            throw new Exception("Mac identity mismatch. No connection was accepted.");
    }

    static String connectionError(Exception exception) {
        return exception instanceof javax.net.ssl.SSLException
                ? "Mac certificate verification failed. Re-pair over USB if the Mac identity changed."
                : exception.getMessage() == null ? "Mac unavailable" : exception.getMessage();
    }
}
