package local.boox.sidecar;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executor;

public final class InputDispatcherTest {
    private static int checks;

    public static void main(String[] args) {
        orderedInput();
        boundsAndFailure();
        obsoleteOwnership();
        System.out.println(checks + " ordered input checks passed.");
    }

    private static void orderedInput() {
        Fixture f = new Fixture();
        f.dispatcher.tap(f.owner, "capture", 0.1, 0.2);
        f.dispatcher.scroll(f.owner, "capture", 800);
        f.dispatcher.scroll(f.owner, "capture", 800);
        f.dispatcher.tap(f.owner, "capture", 0.3, 0.4, 2);
        f.dispatcher.scroll(f.owner, "capture", -50);
        f.dispatcher.scroll(f.owner, "capture", 30);
        check(f.executor.tasks.size() == 1);
        check(f.sender.events.isEmpty());
        f.executor.run();
        check(f.sender.events.size() == 6);
        check(!f.sender.events.get(0).scroll && f.sender.events.get(0).first == 0.1);
        check(f.sender.events.get(1).first == 1000);
        check(f.sender.events.get(2).first == 600);
        check(!f.sender.events.get(3).scroll && f.sender.events.get(3).first == 0.3);
        check(f.sender.events.get(3).clickCount == 2);
        check(f.sender.events.get(4).first == -50);
        check(f.sender.events.get(5).first == 30);
        check(f.pauses.isEmpty());

        f.dispatcher.scroll(f.owner, "capture", 10);
        f.dispatcher.rightClick(f.owner, "capture", 0.6, 0.7);
        f.dispatcher.scroll(f.owner, "capture", 20);
        f.executor.run();
        check(f.sender.events.size() == 9);
        check(f.sender.events.get(6).first == 10);
        InputDispatcher.Event right = f.sender.events.get(7);
        check(right.rightClick && !right.scroll && right.first == 0.6 && right.second == 0.7);
        check(f.sender.events.get(8).first == 20);
    }

    private static void boundsAndFailure() {
        Fixture full = new Fixture();
        for (int i = 0; i < InputDispatcher.CAPACITY; i++) full.dispatcher.tap(full.owner, "capture", 0.1, 0.2);
        check(full.pauses.isEmpty());
        full.dispatcher.tap(full.owner, "capture", 0.1, 0.2);
        check(full.pauses.size() == 1 && full.sender.cancelled);
        full.executor.run();
        check(full.sender.events.isEmpty());

        Fixture aged = new Fixture();
        aged.dispatcher.scroll(aged.owner, "capture", 1);
        aged.now[0] = 1900;
        aged.dispatcher.scroll(aged.owner, "capture", 1);
        aged.now[0] = 2000;
        aged.executor.run();
        check(aged.sender.events.isEmpty() && aged.pauses.size() == 1);

        Fixture failed = new Fixture();
        failed.sender.fail = true;
        failed.dispatcher.tap(failed.owner, "capture", 0.1, 0.2);
        failed.dispatcher.tap(failed.owner, "capture", 0.3, 0.4);
        failed.executor.run();
        check(failed.sender.events.size() == 1 && failed.pauses.size() == 1);
        failed.executor.run();
        check(failed.sender.events.size() == 1);
    }

    private static void obsoleteOwnership() {
        Fixture f = new Fixture();
        f.dispatcher.tap(new Object(), "capture", 0.1, 0.2);
        f.dispatcher.tap(f.owner, "old-capture", 0.1, 0.2);
        check(f.executor.tasks.isEmpty());
        f.dispatcher.tap(f.owner, "capture", 0.1, 0.2);
        f.dispatcher.stop();
        f.executor.run();
        check(f.sender.events.isEmpty());

        Sender replacement = new Sender();
        Object nextOwner = new Object();
        f.dispatcher.activate(f.owner, "capture", new Sender() {
            @Override public void send(InputDispatcher.Event event, String capture) throws Exception {
                f.dispatcher.activate(nextOwner, "next", replacement);
                f.dispatcher.tap(nextOwner, "next", 0.5, 0.6);
                throw new Exception("Late failure");
            }
        });
        f.dispatcher.tap(f.owner, "capture", 0.1, 0.2);
        f.executor.run();
        check(f.pauses.isEmpty());
        check(replacement.events.size() == 1 && replacement.events.get(0).first == 0.5);
        check(f.dispatcher.matches(nextOwner, "next"));

        Fixture churn = new Fixture();
        Sender latest = null;
        for (int i = 0; i < 100; i++) {
            latest = new Sender();
            churn.dispatcher.activate(churn.owner, "capture", latest);
            churn.dispatcher.tap(churn.owner, "capture", 0.1, 0.2);
        }
        check(churn.executor.tasks.size() == 1);
        churn.executor.run();
        check(latest.events.size() == 1 && churn.pauses.isEmpty());
    }

    private static final class Fixture {
        final TestExecutor executor = new TestExecutor();
        final long[] now = {0};
        final Object owner = new Object();
        final Sender sender = new Sender();
        final List<String> pauses = new ArrayList<>();
        final InputDispatcher dispatcher = new InputDispatcher(executor, () -> now[0], (epoch, reason) -> pauses.add(reason));
        Fixture() { dispatcher.activate(owner, "capture", sender); }
    }

    private static class Sender implements InputDispatcher.Sender {
        final List<InputDispatcher.Event> events = new ArrayList<>();
        boolean cancelled, fail;
        @Override public void send(InputDispatcher.Event event, String capture) throws Exception {
            check(!cancelled && !capture.isEmpty());
            events.add(event);
            if (fail) throw new Exception("Lost response");
        }
        @Override public void cancel() { cancelled = true; }
    }

    private static final class TestExecutor implements Executor {
        final ArrayDeque<Runnable> tasks = new ArrayDeque<>();
        @Override public void execute(Runnable task) { tasks.addLast(task); }
        void run() { while (!tasks.isEmpty()) tasks.removeFirst().run(); }
    }

    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
}
