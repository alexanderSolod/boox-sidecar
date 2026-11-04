package local.boox.sidecar;

import java.util.ArrayList;
import java.util.List;

public final class TouchGestureTest {
    private static int checks;

    public static void main(String[] args) {
        Fixture f = new Fixture();
        check(!f.gesture.down(50, 100, 0));
        check(f.gesture.down(200, 100, 10));
        check(f.gesture.up(200, 100, 20));
        check(f.counts.equals(List.of(1)) && f.x == 0.125 && f.y == 1.0 / 6);
        f.gesture.down(220, 110, 100); f.gesture.up(220, 110, 110);
        check(f.counts.equals(List.of(1, 2)));
        check(f.x == 0.125 && f.y == 1.0 / 6);
        f.gesture.down(200, 100, 120); f.gesture.up(200, 100, 130);
        check(f.counts.equals(List.of(1, 2, 1)));
        f.gesture.down(200, 100, 500); f.gesture.up(200, 100, 510);
        check(f.counts.get(3) == 1);
        f.gesture.down(400, 100, 520); f.gesture.up(400, 100, 530);
        check(f.counts.get(4) == 1);
        check(f.x == 0.375 && f.y == 1.0 / 6);
        f.gesture.down(400, 100, 540); f.gesture.up(400, 100, 1100);
        check(f.counts.size() == 5 && f.rightClicks == 1);

        Fixture scrolling = new Fixture();
        scrolling.gesture.down(200, 100, 0);
        check(scrolling.gesture.startScroll(200, 100));
        scrolling.gesture.move(200, 109.5);
        check(scrolling.deltas.equals(List.of(9.0)));
        scrolling.gesture.move(200, 120);
        check(scrolling.deltas.equals(List.of(9.0, 11.0)));
        check(!scrolling.gesture.up(200, 125, 100));
        check(scrolling.deltas.equals(List.of(9.0, 11.0, 5.0)) && scrolling.counts.isEmpty());
        check(scrolling.scrollX.stream().allMatch(x -> x == 0.125));
        check(scrolling.scrollY.stream().allMatch(y -> y == 1.0 / 6));
        scrolling.gesture.move(220, 150);
        check(!scrolling.gesture.up(220, 150, 105) && scrolling.deltas.size() == 3);
        scrolling.gesture.down(200, 100, 110); scrolling.gesture.up(200, 100, 120);
        check(scrolling.counts.equals(List.of(1)));
        scrolling.gesture.startScroll(200, 100); scrolling.gesture.up(200, 110.7, 160);
        check(scrolling.deltas.subList(3, 5).equals(List.of(10.0, 1.0)));
        scrolling.gesture.down(200, 100, 130); scrolling.gesture.move(250, 100); scrolling.gesture.up(200, 100, 140);
        check(scrolling.counts.equals(List.of(1)));

        Fixture changed = new Fixture();
        changed.gesture.down(200, 100, 0);
        changed.gesture.frame("next", 100, 0, 800, 600);
        check(!changed.gesture.up(200, 100, 50));
        changed.gesture.down(200, 100, 60);
        changed.gesture.frame("next", 0, 100, 600, 800);
        check(!changed.gesture.up(200, 100, 70));
        changed.gesture.down(300, 500, 80); changed.gesture.up(300, 500, 90);
        check(changed.x == 0.5 && changed.y == 0.5);
        changed.gesture.down(300, 500, 100); changed.gesture.cancel();
        check(!changed.gesture.up(300, 500, 110));
        changed.gesture.down(300, 500, 120); changed.gesture.up(300, 500, 130);
        check(changed.counts.equals(List.of(1, 1)));
        changed.gesture.clear();
        check(!changed.gesture.down(300, 500, 140));

        Fixture hold = new Fixture();
        hold.gesture.down(300, 300, 0);
        check(!hold.gesture.longPress(499));
        check(hold.gesture.longPress(500));
        check(hold.rightClicks == 1 && hold.x == 0.25 && hold.y == 0.5);
        check(!hold.gesture.longPress(1000));
        check(!hold.gesture.up(300, 300, 1100));
        check(hold.rightClicks == 1 && hold.counts.isEmpty());
        hold.gesture.down(300, 300, 1200); hold.gesture.up(300, 300, 1300);
        check(hold.counts.equals(List.of(1)));
        hold.gesture.down(300, 300, 1400); hold.gesture.move(320, 300);
        check(!hold.gesture.longPress(2000));
        hold.gesture.cancel();
        hold.gesture.down(300, 300, 2100); hold.gesture.move(300, 320);
        check(!hold.gesture.longPress(2700));
        hold.gesture.cancel();
        hold.gesture.down(300, 300, 2800); hold.gesture.frame("replacement", 100, 0, 800, 600);
        check(!hold.gesture.longPress(3400));
        hold.gesture.down(300, 300, 3500); hold.gesture.cancel();
        check(!hold.gesture.longPress(4100));
        check(hold.rightClicks == 1);
        dragGestures();
        System.out.println(checks + " touch gesture checks passed.");
    }

    private static void dragGestures() {
        Fixture f = new Fixture();
        f.gesture.down(200, 100, 0);
        f.gesture.move(205, 105);
        check(f.drags.isEmpty());
        f.gesture.move(220, 110);
        check(f.drags.size() == 2 && f.drags.get(0).phase.equals("start") && f.drags.get(1).phase.equals("move"));
        check(f.drags.get(0).x == 0.125 && f.drags.get(0).y == 1.0 / 6);
        check(f.drags.get(1).x == 0.15 && f.drags.get(1).y == 110.0 / 600);
        String id = f.drags.get(0).id;
        f.gesture.heartbeat();
        check(f.drags.get(2).phase.equals("move") && f.drags.get(2).id.equals(id));
        check(!f.gesture.longPress(1000));
        check(!f.gesture.up(240, 130, 1100));
        check(f.drags.get(4).phase.equals("end") && f.drags.get(4).id.equals(id));
        check(f.drags.get(4).x == 0.175 && f.drags.get(4).y == 130.0 / 600);
        f.gesture.heartbeat();
        check(f.drags.size() == 5 && f.counts.isEmpty() && f.deltas.isEmpty() && f.rightClicks == 0);

        Fixture transition = new Fixture();
        transition.gesture.down(200, 100, 0);
        transition.gesture.move(250, 100);
        check(transition.gesture.startScroll(300, 200));
        check(transition.drags.get(2).phase.equals("cancel"));
        check(transition.drags.get(2).id.equals(transition.drags.get(0).id));
        transition.gesture.move(310, 220);
        check(transition.deltas.equals(List.of(20.0)));
        check(transition.scrollX.equals(List.of(0.25)) && transition.scrollY.equals(List.of(1.0 / 3)));
        check(!transition.gesture.up(310, 220, 100));
        transition.gesture.move(330, 240);
        check(transition.drags.size() == 3 && transition.deltas.size() == 1 && transition.counts.isEmpty());

        Fixture changed = new Fixture();
        changed.gesture.down(200, 100, 0);
        changed.gesture.move(1000, 700);
        check(changed.drags.get(1).x == 1 && changed.drags.get(1).y == 1);
        changed.gesture.frame("replacement", 0, 0, 600, 800);
        check(changed.drags.get(2).phase.equals("cancel") && changed.drags.get(2).capture.equals("capture"));
        changed.gesture.heartbeat();
        check(!changed.gesture.up(300, 400, 100) && changed.drags.size() == 3);
        changed.gesture.down(300, 400, 200);
        changed.gesture.move(320, 400);
        check(!changed.drags.get(3).id.equals(changed.drags.get(0).id));
        changed.gesture.cancel();
        check(changed.drags.get(5).phase.equals("cancel"));
    }

    private static final class Drag {
        final String capture, phase, id;
        final double x, y;
        Drag(String capture, String phase, String id, double x, double y) {
            this.capture = capture; this.phase = phase; this.id = id; this.x = x; this.y = y;
        }
    }

    private static final class Fixture implements TouchGesture.Listener {
        final List<Integer> counts = new ArrayList<>();
        final List<Double> deltas = new ArrayList<>();
        final List<Double> scrollX = new ArrayList<>(), scrollY = new ArrayList<>();
        final List<Drag> drags = new ArrayList<>();
        double x, y;
        int rightClicks;
        final TouchGesture gesture = new TouchGesture(8, 30, 300, 500, this);
        Fixture() { gesture.frame("capture", 100, 0, 800, 600); }
        @Override public void tap(String capture, double x, double y, int count) {
            check(!capture.isEmpty()); counts.add(count); this.x = x; this.y = y;
        }
        @Override public void scroll(String capture, double x, double y, double delta) {
            check(!capture.isEmpty()); deltas.add(delta); scrollX.add(x); scrollY.add(y);
        }
        @Override public void drag(String capture, String phase, String id, double x, double y) {
            check(!capture.isEmpty() && java.util.UUID.fromString(id).toString().equals(id));
            drags.add(new Drag(capture, phase, id, x, y));
        }
        @Override public void rightClick(String capture, double x, double y) {
            check(!capture.isEmpty()); rightClicks++; this.x = x; this.y = y;
        }
    }

    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
}
