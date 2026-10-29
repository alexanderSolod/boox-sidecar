package local.boox.sidecar;

final class TouchGesture {
    interface Listener {
        void tap(String captureSession, double x, double y, int clickCount);
        void scroll(String captureSession, double delta);
    }

    private final double touchSlop, doubleTapSlop;
    private final long doubleTapTimeout, longPressTimeout;
    private final Listener listener;
    private String capture = "", active = "", lastTapCapture = "";
    private double left, top, width, height, startX, startY, lastY, remainder, lastTapX, lastTapY;
    private long downAt, lastTapAt;
    private boolean scrolling, moved;

    TouchGesture(double touchSlop, double doubleTapSlop, long doubleTapTimeout, long longPressTimeout, Listener listener) {
        this.touchSlop = touchSlop;
        this.doubleTapSlop = doubleTapSlop;
        this.doubleTapTimeout = doubleTapTimeout;
        this.longPressTimeout = longPressTimeout;
        this.listener = listener;
    }

    void frame(String capture, double left, double top, double width, double height) {
        if (!this.capture.equals(capture) || this.left != left || this.top != top || this.width != width || this.height != height) cancel();
        this.capture = capture;
        this.left = left;
        this.top = top;
        this.width = width;
        this.height = height;
    }

    void clear() { cancel(); capture = ""; }

    void cancel() {
        active = "";
        lastTapCapture = "";
        remainder = 0;
        scrolling = false;
        moved = false;
    }

    boolean down(double x, double y, long time) {
        active = "";
        if (capture.isEmpty() || !contains(x, y)) { cancel(); return false; }
        active = capture;
        startX = x;
        startY = lastY = y;
        downAt = time;
        remainder = 0;
        scrolling = false;
        moved = false;
        return true;
    }

    void move(double x, double y) {
        if (active.isEmpty()) return;
        if (!scrolling && Math.abs(y - startY) > touchSlop) {
            scrolling = true;
            lastTapCapture = "";
        }
        if (scrolling) {
            remainder += y - lastY;
            lastY = y;
            double delta = Math.copySign(Math.floor(Math.abs(remainder)), remainder);
            remainder -= delta;
            if (delta != 0) listener.scroll(active, delta);
        }
        if (Math.abs(x - startX) > touchSlop) { moved = true; lastTapCapture = ""; }
    }

    boolean up(double x, double y, long time) {
        if (active.isEmpty()) return false;
        move(x, y);
        String authority = active;
        active = "";
        if (scrolling && Math.abs(remainder) >= 0.5) listener.scroll(authority, Math.copySign(1, remainder));
        if (scrolling || moved || !contains(x, y)) {
            lastTapCapture = "";
            return false;
        }
        double dx = startX - lastTapX, dy = startY - lastTapY;
        boolean quick = time >= downAt && time - downAt < longPressTimeout;
        boolean twice = quick && authority.equals(lastTapCapture) && downAt >= lastTapAt && downAt - lastTapAt <= doubleTapTimeout
                && dx * dx + dy * dy <= doubleTapSlop * doubleTapSlop;
        lastTapCapture = twice || !quick ? "" : authority;
        lastTapAt = time;
        lastTapX = x;
        lastTapY = y;
        listener.tap(authority, (x - left) / width, (y - top) / height, twice ? 2 : 1);
        return true;
    }

    private boolean contains(double x, double y) {
        return width > 0 && height > 0 && x >= left && x < left + width && y >= top && y < top + height;
    }
}
