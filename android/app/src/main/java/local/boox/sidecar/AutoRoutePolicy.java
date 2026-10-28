package local.boox.sidecar;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/** Pure connection policy shared by production routing and JVM tests. */
final class AutoRoutePolicy {
    static final String USB = "https://127.0.0.1:8787";
    static List<String> candidates(String mode, String usbEndpoint, String savedWifi, String discoveredWifi) {
        ArrayList<String> result = new ArrayList<>(3);
        if (!"wifi".equals(mode)) addEndpoint(result, usbEndpoint);
        if (!"usb".equals(mode)) {
            addEndpoint(result, discoveredWifi);
            addEndpoint(result, savedWifi);
        }
        return result;
    }
    private static void addEndpoint(List<String> list, String endpoint) {
        if (endpoint == null || !endpoint.startsWith("https:")) return;
        try {
            String validated = PinnedClient.validateEndpoint(endpoint);
            if (!list.contains(validated)) list.add(validated);
        } catch (IOException ignored) { }
    }
    static boolean identityMatches(String saved, String reported) {
        return saved != null && saved.matches("[0-9a-f]{64}") && saved.equals(reported);
    }
    static long retryDelay(int attempts) {
        return Math.min(8000, 500L << Math.min(4, Math.max(0, attempts)));
    }
    static boolean shouldProbeUsb(String mode, String endpoint, String usbEndpoint, long now, long nextProbe) {
        return "auto".equals(mode) && endpoint != null && !endpoint.equals(usbEndpoint) && now >= nextProbe;
    }
}
