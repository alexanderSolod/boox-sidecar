package local.boox.sidecar;

final class SessionCoordinator<T> {
    enum State { PAUSED, CONNECTING, WAITING_FOR_CAPTURE, STREAMING, RECONNECTING }

    private int generation;
    private State state = State.PAUSED;
    private T owner;
    private boolean hostAsleep;
    private final CaptureSessionState capture = new CaptureSessionState();

    synchronized int begin() {
        invalidate(State.CONNECTING);
        return generation;
    }

    synchronized void stop() { invalidate(State.PAUSED); }

    private void invalidate(State next) {
        generation++;
        owner = null;
        hostAsleep = false;
        capture.update("", false);
        state = next;
    }

    synchronized boolean isCurrent(int session) {
        return generation == session && state != State.PAUSED;
    }

    synchronized boolean owns(int session, T candidate) {
        return isCurrent(session) && candidate != null && owner == candidate;
    }

    synchronized boolean activate(int session, T candidate) {
        if (!isCurrent(session) || candidate == null) return false;
        owner = candidate;
        capture.update("", false);
        state = State.WAITING_FOR_CAPTURE;
        return true;
    }

    synchronized boolean updateCapture(int session, T candidate, boolean ready, String reported, boolean asleep) {
        if (!owns(session, candidate)) return false;
        hostAsleep = asleep;
        boolean changed = capture.update(reported, ready && !asleep);
        state = capture.id().isEmpty() ? State.WAITING_FOR_CAPTURE : State.STREAMING;
        return changed;
    }

    synchronized boolean failed(int session, T candidate) {
        if (!owns(session, candidate)) return false;
        owner = null;
        capture.update("", false);
        state = State.RECONNECTING;
        return true;
    }

    synchronized boolean hostAsleep() { return hostAsleep; }
    synchronized boolean captureReady() { return state == State.STREAMING; }
    synchronized boolean acceptsCapture(String id) { return captureReady() && capture.accepts(id); }
    synchronized String captureSession() { return capture.id(); }
    synchronized State state() { return state; }
}
