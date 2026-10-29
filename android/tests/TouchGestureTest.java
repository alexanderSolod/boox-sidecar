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
        f.gesture.down(201, 101, 100); f.gesture.up(201, 101, 110);
        check(f.counts.equals(List.of(1, 2)));
        f.gesture.down(200, 100, 120); f.gesture.up(200, 100, 130);
        check(f.counts.equals(List.of(1, 2, 1)));
        f.gesture.down(200, 100, 500); f.gesture.up(200, 100, 510);
        check(f.counts.get(3) == 1);
        f.gesture.down(400, 100, 520); f.gesture.up(400, 100, 530);
        check(f.counts.get(4) == 1);
        f.gesture.down(400, 100, 540); f.gesture.up(400, 100, 1100);
        check(f.counts.get(5) == 1);

        Fixture scrolling = new Fixture();
        scrolling.gesture.down(200, 100, 0);
        scrolling.gesture.move(200, 109.5);
        check(scrolling.deltas.equals(List.of(9.0)));
        scrolling.gesture.move(200, 120);
        check(scrolling.deltas.equals(List.of(9.0, 11.0)));
        check(!scrolling.gesture.up(200, 125, 100));
        check(scrolling.deltas.equals(List.of(9.0, 11.0, 5.0)) && scrolling.counts.isEmpty());
        scrolling.gesture.down(200, 100, 110); scrolling.gesture.up(200, 100, 120);
        check(scrolling.counts.equals(List.of(1)));
        scrolling.gesture.down(200, 100, 150); scrolling.gesture.up(200, 110.7, 160);
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
        System.out.println(checks + " touch gesture checks passed.");
    }

    private static final class Fixture implements TouchGesture.Listener {
        final List<Integer> counts = new ArrayList<>();
        final List<Double> deltas = new ArrayList<>();
        double x, y;
        final TouchGesture gesture = new TouchGesture(8, 30, 300, 500, this);
        Fixture() { gesture.frame("capture", 100, 0, 800, 600); }
        @Override public void tap(String capture, double x, double y, int count) {
            check(!capture.isEmpty()); counts.add(count); this.x = x; this.y = y;
        }
        @Override public void scroll(String capture, double delta) { check(!capture.isEmpty()); deltas.add(delta); }
    }

    private static void check(boolean value) { if (!value) throw new AssertionError(); checks++; }
}
