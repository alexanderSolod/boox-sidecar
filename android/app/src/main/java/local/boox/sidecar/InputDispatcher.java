package local.boox.sidecar;

import java.util.ArrayDeque;
import java.util.concurrent.Executor;
import java.util.function.LongSupplier;

final class InputDispatcher {
    static final int CAPACITY = 64;
    static final long MAX_AGE_MILLIS = 2000;

    interface Sender {
        void send(Event event, String captureSession) throws Exception;
        void cancel();
    }

    interface Listener { void paused(long epoch, String reason); }

    static final class Event {
        final boolean scroll;
        final boolean rightClick;
        final double first, second;
        final Double scrollX, scrollY;
        final String dragPhase, dragId;
        final long createdAt;
        final int clickCount;

        Event(boolean scroll, double first, double second, long createdAt) {
            this(scroll, first, second, createdAt, 1);
        }

        Event(boolean scroll, double first, double second, long createdAt, int clickCount) {
            this(scroll ? "scroll" : "tap", first, second, createdAt, clickCount);
        }

        Event(String type, double first, double second, long createdAt, int clickCount) {
            this(type, first, second, createdAt, clickCount, null, null);
        }

        Event(String type, double first, double second, long createdAt, int clickCount, Double scrollX, Double scrollY) {
            this(type, first, second, createdAt, clickCount, scrollX, scrollY, null, null);
        }

        Event(String type, double first, double second, long createdAt, int clickCount, Double scrollX, Double scrollY, String dragPhase, String dragId) {
            this.scroll = "scroll".equals(type);
            this.rightClick = "rightClick".equals(type);
            this.first = first;
            this.second = second;
            this.createdAt = createdAt;
            this.clickCount = clickCount;
            this.scrollX = scrollX;
            this.scrollY = scrollY;
            this.dragPhase = dragPhase;
            this.dragId = dragId;
        }

        Event scrollDelta(double delta) {
            return new Event("scroll", delta, 0, createdAt, 1, scrollX, scrollY);
        }
    }

    private final Executor executor;
    private final LongSupplier clock;
    private final Listener listener;
    private final ArrayDeque<Event> queue = new ArrayDeque<>();
    private Object owner;
    private String captureSession = "";
    private Sender sender;
    private long epoch;
    private boolean draining;

    InputDispatcher(Executor executor, LongSupplier clock, Listener listener) {
        this.executor = executor;
        this.clock = clock;
        this.listener = listener;
    }

    synchronized boolean matches(Object owner, String captureSession) {
        return sender != null && this.owner == owner && this.captureSession.equals(captureSession);
    }

    synchronized boolean isCurrent(long candidate) { return epoch == candidate; }

    synchronized void activate(Object owner, String captureSession, Sender sender) {
        stop();
        this.owner = owner;
        this.captureSession = captureSession;
        this.sender = sender;
    }

    synchronized void stop() {
        epoch++;
        if (sender != null) sender.cancel();
        sender = null;
        owner = null;
        captureSession = "";
        queue.clear();
    }

    void tap(Object owner, String captureSession, double x, double y) {
        tap(owner, captureSession, x, y, 1);
    }

    void tap(Object owner, String captureSession, double x, double y, int clickCount) {
        if (clickCount == 1 || clickCount == 2) enqueue(owner, captureSession, "tap", x, y, clickCount);
    }

    void rightClick(Object owner, String captureSession, double x, double y) {
        enqueue(owner, captureSession, "rightClick", x, y, 1);
    }

    void scroll(Object owner, String captureSession, double delta) {
        if (delta != 0) enqueue(owner, captureSession, "scroll", delta, 0, 1);
    }

    void scroll(Object owner, String captureSession, double x, double y, double delta) {
        if (delta != 0 && Double.isFinite(x) && Double.isFinite(y) && x >= 0 && x <= 1 && y >= 0 && y <= 1)
            enqueue(owner, captureSession, "scroll", delta, 0, 1, x, y);
    }

    void drag(Object owner, String captureSession, String phase, String dragId, double x, double y) {
        if (!("start".equals(phase) || "move".equals(phase) || "end".equals(phase) || "cancel".equals(phase))
                || dragId == null || !dragId.matches("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
                || !Double.isFinite(x) || !Double.isFinite(y) || x < 0 || x > 1 || y < 0 || y > 1) return;
        enqueue(owner, captureSession, "drag", x, y, 1, null, null, phase, dragId);
    }

    private void enqueue(Object owner, String captureSession, String type, double first, double second, int clickCount) {
        enqueue(owner, captureSession, type, first, second, clickCount, null, null);
    }

    private void enqueue(Object owner, String captureSession, String type, double first, double second, int clickCount, Double scrollX, Double scrollY) {
        enqueue(owner, captureSession, type, first, second, clickCount, scrollX, scrollY, null, null);
    }

    private record Pause(long epoch, String reason) {}

    private void enqueue(Object owner, String captureSession, String type, double first, double second, int clickCount, Double scrollX, Double scrollY, String dragPhase, String dragId) {
        Pause paused;
        boolean schedule;
        synchronized (this) {
            paused = enqueueLocked(owner, captureSession, type, first, second, clickCount, scrollX, scrollY, dragPhase, dragId);
            schedule = sender != null && !queue.isEmpty() && !draining;
            if (schedule) draining = true;
        }
        notifyPaused(paused);
        if (schedule) executor.execute(this::drain);
    }

    private Pause enqueueLocked(Object owner, String captureSession, String type, double first, double second, int clickCount, Double scrollX, Double scrollY, String dragPhase, String dragId) {
        if (!matches(owner, captureSession) || !Double.isFinite(first) || !Double.isFinite(second)) return null;
        boolean scroll = "scroll".equals(type);
        long now = clock.getAsLong();
        if (!queue.isEmpty() && now - queue.peekFirst().createdAt >= MAX_AGE_MILLIS) {
            return pauseLocked("Input waited too long.");
        }
        Event tail = queue.peekLast();
        if ("move".equals(dragPhase) && tail != null && "move".equals(tail.dragPhase) && dragId.equals(tail.dragId)) {
            queue.removeLast();
            queue.addLast(new Event(type, first, second, tail.createdAt, clickCount, null, null, dragPhase, dragId));
        } else if (scroll && tail != null && tail.scroll && Math.signum(tail.first) == Math.signum(first)
                && java.util.Objects.equals(tail.scrollX, scrollX) && java.util.Objects.equals(tail.scrollY, scrollY)) {
            double accumulated = tail.first + first;
            if (!Double.isFinite(accumulated)) { return pauseLocked("Too much input is waiting."); }
            queue.removeLast();
            queue.addLast(tail.scrollDelta(accumulated));
        } else {
            if (queue.size() >= CAPACITY) { return pauseLocked("Too much input is waiting."); }
            queue.addLast(new Event(type, first, second, now, clickCount, scrollX, scrollY, dragPhase, dragId));
        }
        return null;
    }

    private void drain() {
        while (true) {
            Event event;
            Sender target;
            String capture;
            long current;
            Pause paused = null;
            synchronized (this) {
                current = epoch;
                if (sender == null) { draining = false; return; }
                event = queue.pollFirst();
                if (event == null) { draining = false; return; }
                if (clock.getAsLong() - event.createdAt >= MAX_AGE_MILLIS) {
                    paused = pauseLocked("Input waited too long.");
                }
                if (paused == null && event.scroll && Math.abs(event.first) > 1000) {
                    double delta = Math.copySign(1000, event.first);
                    queue.addFirst(event.scrollDelta(event.first - delta));
                    event = event.scrollDelta(delta);
                }
                target = sender;
                capture = captureSession;
            }
            if (paused != null) { notifyPaused(paused); continue; }
            try { target.send(event, capture); }
            catch (Exception exception) {
                synchronized (this) {
                    if (current == epoch) paused = pauseLocked("Input delivery could not be confirmed.");
                }
                notifyPaused(paused);
            }
        }
    }

    private Pause pauseLocked(String reason) {
        stop();
        return new Pause(epoch, reason);
    }

    private void notifyPaused(Pause paused) {
        if (paused != null && isCurrent(paused.epoch())) listener.paused(paused.epoch(), paused.reason());
    }
}
