package local.boox.sidecar;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class SessionCoordinatorTest {
    private static void check(boolean result) {
        if (!result) throw new AssertionError();
    }

    public static void main(String[] args) throws Exception {
        SessionCoordinator<Object> sessions = new SessionCoordinator<>();
        int first = sessions.begin();
        Object usb = new Object();
        Object wifi = new Object();
        check(sessions.state() == SessionCoordinator.State.CONNECTING);
        check(sessions.activate(first, usb));
        check(sessions.state() == SessionCoordinator.State.WAITING_FOR_CAPTURE);
        check(!sessions.updateCapture(first, usb, false, "", false));
        check(!sessions.captureReady());
        check(sessions.updateCapture(first, usb, true, "capture-one", false));
        check(sessions.captureReady() && sessions.acceptsCapture("capture-one"));
        check(sessions.failed(first, usb));
        check(sessions.state() == SessionCoordinator.State.RECONNECTING);
        check(!sessions.acceptsCapture("capture-one"));
        check(sessions.activate(first, wifi));
        check(!sessions.owns(first, usb));
        check(!sessions.failed(first, usb));
        check(!sessions.updateCapture(first, usb, true, "stale", false));
        check(sessions.updateCapture(first, wifi, true, "capture-two", false));
        check(!sessions.updateCapture(first, usb, false, "", false));
        check(sessions.acceptsCapture("capture-two"));
        check(sessions.updateCapture(first, wifi, true, "source-change", false));
        check(!sessions.acceptsCapture("capture-two"));
        check(sessions.updateCapture(first, wifi, false, "source-change", false));
        check(!sessions.captureReady());
        sessions.stop();
        check(sessions.state() == SessionCoordinator.State.PAUSED);
        check(!sessions.activate(first, usb));
        int resumed = sessions.begin();
        check(resumed != first && !sessions.isCurrent(first));
        check(sessions.activate(resumed, usb));
        check(!sessions.updateCapture(first, usb, true, "old-lifecycle", false));
        check(!sessions.updateCapture(resumed, usb, true, "bad\r\nsession", false));
        check(!sessions.captureReady());
        check(sessions.updateCapture(resumed, usb, true, "fresh", false));
        check(sessions.activate(resumed, wifi));
        check(!sessions.acceptsCapture("fresh"));
        check(sessions.state() == SessionCoordinator.State.WAITING_FOR_CAPTURE);
        sleepRecovery();
        delayedCompletion(false);
        delayedCompletion(true);
        System.out.println("PASS: session startup, route recovery, ownership, capture changes and pause/resume");
    }

    private static void sleepRecovery() {
        SessionCoordinator<Object> sessions = new SessionCoordinator<>();
        int session = sessions.begin();
        Object usb = new Object(), wifi = new Object();
        check(sessions.activate(session, usb));
        check(sessions.updateCapture(session, usb, true, "before-sleep", false));
        check(sessions.updateCapture(session, usb, true, "before-sleep", true));
        check(sessions.hostAsleep() && !sessions.captureReady());
        check(!sessions.acceptsCapture("before-sleep"));
        check(sessions.failed(session, usb));
        check(sessions.hostAsleep());
        check(sessions.activate(session, wifi));
        check(!sessions.updateCapture(session, usb, true, "stale", false));
        check(sessions.hostAsleep());
        check(!sessions.updateCapture(session, wifi, false, "", true));
        check(sessions.updateCapture(session, wifi, true, "after-wake", false));
        check(!sessions.hostAsleep() && sessions.acceptsCapture("after-wake"));
        check(!sessions.acceptsCapture("before-sleep"));
        check(!sessions.updateCapture(session, usb, false, "", true));
        check(!sessions.hostAsleep() && sessions.acceptsCapture("after-wake"));
        check(sessions.updateCapture(session, wifi, false, "", true));
        sessions.stop();
        check(!sessions.hostAsleep());
        int resumed = sessions.begin();
        check(sessions.activate(resumed, usb));
        check(!sessions.updateCapture(session, wifi, false, "", true));
        check(!sessions.hostAsleep());
    }

    private static void delayedCompletion(boolean pauseAndResume) throws Exception {
        SessionCoordinator<Object> sessions = new SessionCoordinator<>();
        int oldSession = sessions.begin();
        Object oldOwner = new String("same-host");
        Object newOwner = new String("same-host");
        check(oldOwner.equals(newOwner));
        check(sessions.activate(oldSession, oldOwner));
        check(sessions.updateCapture(oldSession, oldOwner, true, "same-capture", false));
        CountDownLatch inFlight = new CountDownLatch(1);
        CountDownLatch complete = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread response = new Thread(() -> {
            try {
                inFlight.countDown();
                check(complete.await(5, TimeUnit.SECONDS));
                check(!sessions.owns(oldSession, oldOwner));
                check(!sessions.updateCapture(oldSession, oldOwner, false, "", false));
                check(!sessions.failed(oldSession, oldOwner));
                if (pauseAndResume) check(!sessions.activate(oldSession, oldOwner));
            } catch (Throwable error) { failure.set(error); }
        });
        response.start();
        check(inFlight.await(5, TimeUnit.SECONDS));
        int newSession = oldSession;
        if (pauseAndResume) {
            sessions.stop();
            newSession = sessions.begin();
        }
        check(sessions.activate(newSession, newOwner));
        check(sessions.updateCapture(newSession, newOwner, true, "same-capture", false));
        complete.countDown();
        response.join(5000);
        check(!response.isAlive());
        if (failure.get() != null) throw new AssertionError("Delayed response changed a replacement session", failure.get());
        check(sessions.owns(newSession, newOwner));
        check(sessions.acceptsCapture("same-capture"));
    }
}
