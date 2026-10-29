package local.boox.sidecar;

final class SessionCoordinator<T> {
    enum State { PAUSED, CONNECTING, WAITING_FOR_CAPTURE, STREAMING, RECONNECTING }

    private int generation;
    private State state = State.PAUSED;
    private T owner;
    private boolean hostAsleep;
    private final CaptureSessionState capture = new CaptureSessionState();
    private boolean hostInputEnabled;
    private String lastCaptureSession = "";
    private String inputPauseReason = "";

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
        hostInputEnabled = false;
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
        hostInputEnabled = false;
        state = State.WAITING_FOR_CAPTURE;
        return true;
    }

    synchronized boolean updateCapture(int session, T candidate, boolean ready, String reported, boolean asleep) {
        if (!owns(session, candidate)) return false;
        hostAsleep = asleep;
        boolean changed = capture.update(reported, ready && !asleep);
        if (!capture.id().isEmpty() && !lastCaptureSession.equals(capture.id())) {
            lastCaptureSession = capture.id();
            inputPauseReason = "";
        }
        state = capture.id().isEmpty() ? State.WAITING_FOR_CAPTURE : State.STREAMING;
        return changed;
    }

    synchronized boolean failed(int session, T candidate) {
        if (!owns(session, candidate)) return false;
        owner = null;
        capture.update("", false);
        hostInputEnabled = false;
        state = State.RECONNECTING;
        return true;
    }

    synchronized boolean hostAsleep() { return hostAsleep; }
    synchronized boolean captureReady() { return state == State.STREAMING; }
    synchronized boolean acceptsCapture(String id) { return captureReady() && capture.accepts(id); }
    synchronized String captureSession() { return capture.id(); }
    synchronized State state() { return state; }

    synchronized void updateInputPermission(int session, T candidate, boolean enabled) {
        if (owns(session, candidate)) hostInputEnabled = enabled;
    }

    synchronized boolean hostInputEnabled() { return hostInputEnabled; }
    synchronized boolean inputAllowed() { return captureReady() && hostInputEnabled && inputPauseReason.isEmpty(); }
    synchronized String inputPauseReason() { return inputPauseReason; }

    synchronized boolean pauseInput(T candidate, String captureSession, String reason) {
        if (owner != candidate || !captureReady() || !capture.accepts(captureSession)) return false;
        inputPauseReason = reason;
        return true;
    }

    synchronized boolean resumeInput() {
        if (!captureReady() || !hostInputEnabled) return false;
        inputPauseReason = "";
        return true;
    }
}
