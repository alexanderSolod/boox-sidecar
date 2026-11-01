package local.boox.sidecar;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;
import java.net.Inet4Address;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.HashSet;

/** Bounded mDNS discovery. Advertisements are hints; TLS + token + host_id still authenticate. */
final class MacDiscovery {
    interface Listener { void found(String endpoint); }
    private static final String TYPE = "_boox-sidecar._tcp.";
    private final NsdManager manager;
    private final Handler main = new Handler(Looper.getMainLooper());
    private NsdManager.DiscoveryListener discovery;
    private int generation;
    private final ArrayDeque<NsdServiceInfo> pending = new ArrayDeque<>();
    private final HashSet<String> queued = new HashSet<>();
    private boolean resolving;
    private String hostId;
    private Listener listener;

    MacDiscovery(Context context) { manager = (NsdManager) context.getSystemService(Context.NSD_SERVICE); }

    void start(String expectedHostId, Listener callback) {
        stop();
        if (manager == null || expectedHostId == null || !expectedHostId.matches("[0-9a-f]{64}")) return;
        hostId = expectedHostId;
        listener = callback;
        final int epoch = generation;
        discovery = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) { }
            @Override public void onDiscoveryStopped(String type) { }
            @Override public void onStartDiscoveryFailed(String type, int error) { }
            @Override public void onStopDiscoveryFailed(String type, int error) { }
            @Override public void onServiceLost(NsdServiceInfo info) { }
            @Override public void onServiceFound(NsdServiceInfo info) {
                main.post(() -> {
                    if (epoch != generation || pending.size() >= 8) return;
                    if (!TYPE.equals(info.getServiceType()) && !"_boox-sidecar._tcp".equals(info.getServiceType())) return;
                    if (!queued.add(info.getServiceName())) return;
                    pending.add(info);
                    resolveNext(epoch);
                });
            }
        };
        try { manager.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, discovery); }
        catch (RuntimeException ignored) { discovery = null; }
    }

    @SuppressWarnings("deprecation")
    private void resolveNext(int epoch) {
        if (epoch != generation || resolving || pending.isEmpty()) return;
        NsdServiceInfo next = pending.remove();
        resolving = true;
        try {
            manager.resolveService(next, new NsdManager.ResolveListener() {
                @Override public void onResolveFailed(NsdServiceInfo info, int error) { complete(null); }
                @Override public void onServiceResolved(NsdServiceInfo info) { complete(info); }
                private void complete(NsdServiceInfo info) {
                    main.post(() -> {
                        if (epoch != generation) return;
                        resolving = false;
                        queued.remove(next.getServiceName());
                        if (info != null && info.getPort() > 0 && info.getPort() <= 65535 && info.getHost() instanceof Inet4Address) {
                            byte[] identity = info.getAttributes().get("host_id");
                            String reported = identity == null ? "" : new String(identity, StandardCharsets.UTF_8);
                            if (AutoRoutePolicy.identityMatches(hostId, reported)) {
                                listener.found("https://" + info.getHost().getHostAddress() + ":" + info.getPort());
                            }
                        }
                        resolveNext(epoch);
                    });
                }
            });
        } catch (RuntimeException ignored) {
            resolving = false;
            queued.remove(next.getServiceName());
            resolveNext(epoch);
        }
    }

    void stop() {
        generation++;
        pending.clear();
        queued.clear();
        resolving = false;
        if (discovery != null && manager != null) {
            try { manager.stopServiceDiscovery(discovery); } catch (RuntimeException ignored) { }
        }
        discovery = null;
        listener = null;
    }
}
