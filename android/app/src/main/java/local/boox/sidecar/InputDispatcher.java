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
        final double first, second;
        final long createdAt;

        Event(boolean scroll, double first, double second, long createdAt) {
            this.scroll = scroll;
            this.first = first;
            this.second = second;
            this.createdAt = createdAt;
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
        draining = false;
    }

    void tap(Object owner, String captureSession, double x, double y) {
        enqueue(owner, captureSession, false, x, y);
    }

    void scroll(Object owner, String captureSession, double delta) {
        if (delta != 0) enqueue(owner, captureSession, true, delta, 0);
    }

    private synchronized void enqueue(Object owner, String captureSession, boolean scroll, double first, double second) {
        if (!matches(owner, captureSession) || !Double.isFinite(first) || !Double.isFinite(second)) return;
        long now = clock.getAsLong();
        if (!queue.isEmpty() && now - queue.peekFirst().createdAt >= MAX_AGE_MILLIS) {
            pause("Input waited too long.");
            return;
        }
        Event tail = queue.peekLast();
        if (scroll && tail != null && tail.scroll && Math.signum(tail.first) == Math.signum(first)) {
            double accumulated = tail.first + first;
            if (!Double.isFinite(accumulated)) { pause("Too much input is waiting."); return; }
            queue.removeLast();
            queue.addLast(new Event(true, accumulated, 0, tail.createdAt));
        } else {
            if (queue.size() >= CAPACITY) { pause("Too much input is waiting."); return; }
            queue.addLast(new Event(scroll, first, second, now));
        }
        if (!draining) {
            draining = true;
            long current = epoch;
            executor.execute(() -> drain(current));
        }
    }

    private void drain(long current) {
        while (true) {
            Event event;
            Sender target;
            String capture;
            synchronized (this) {
                if (current != epoch || sender == null) return;
                event = queue.pollFirst();
                if (event == null) { draining = false; return; }
                if (clock.getAsLong() - event.createdAt >= MAX_AGE_MILLIS) {
                    pause("Input waited too long.");
                    return;
                }
                if (event.scroll && Math.abs(event.first) > 1000) {
                    double delta = Math.copySign(1000, event.first);
                    queue.addFirst(new Event(true, event.first - delta, 0, event.createdAt));
                    event = new Event(true, delta, 0, event.createdAt);
                }
                target = sender;
                capture = captureSession;
            }
            try { target.send(event, capture); }
            catch (Exception exception) {
                synchronized (this) {
                    if (current == epoch) pause("Input delivery could not be confirmed.");
                }
                return;
            }
        }
    }

    private void pause(String reason) {
        stop();
        listener.paused(epoch, reason);
    }
}
