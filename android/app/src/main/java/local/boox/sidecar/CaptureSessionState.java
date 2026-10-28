package local.boox.sidecar;

final class CaptureSessionState {
    private volatile String id = "";

    String id() { return id; }

    boolean update(String reported, boolean capturing) {
        String next = capturing && valid(reported) ? reported : "";
        boolean changed = !id.equals(next);
        id = next;
        return changed;
    }

    boolean accepts(String candidate) {
        String current = id;
        return !current.isEmpty() && current.equals(candidate);
    }

    static boolean valid(String value) {
        return value != null && value.matches("[A-Za-z0-9_-]{1,128}");
    }
}
