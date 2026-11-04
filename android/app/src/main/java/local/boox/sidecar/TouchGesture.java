package local.boox.sidecar;

final class TouchGesture {
    interface Listener {
        void tap(String captureSession, double x, double y, int clickCount);
        void rightClick(String captureSession, double x, double y);
        void scroll(String captureSession, double x, double y, double delta);
        void drag(String captureSession, String phase, String dragId, double x, double y);
    }

    private final double touchSlop, doubleTapSlop;
    private final long doubleTapTimeout, longPressTimeout;
    private final Listener listener;
    private String capture = "", active = "", lastTapCapture = "";
    private String dragId = "";
    private double left, top, width, height, startX, startY, currentX, currentY, lastY, remainder, lastTapX, lastTapY;
    private double lastTapNormalizedX, lastTapNormalizedY;
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
        String authority = active, cancelledDrag = dragId;
        double x = normalizedX(currentX), y = normalizedY(currentY);
        active = "";
        dragId = "";
        lastTapCapture = "";
        remainder = 0;
        scrolling = false;
        moved = false;
        if (!cancelledDrag.isEmpty()) listener.drag(authority, "cancel", cancelledDrag, x, y);
    }

    boolean down(double x, double y, long time) {
        if (!active.isEmpty()) cancel();
        active = "";
        if (capture.isEmpty() || !contains(x, y)) { cancel(); return false; }
        active = capture;
        startX = x;
        startY = lastY = y;
        currentX = x;
        currentY = y;
        downAt = time;
        remainder = 0;
        scrolling = false;
        moved = false;
        return true;
    }

    boolean startScroll(double x, double y) {
        cancel();
        if (capture.isEmpty() || !contains(x, y)) return false;
        active = capture;
        startX = currentX = x;
        startY = currentY = lastY = y;
        scrolling = true;
        return true;
    }

    boolean dragging() { return !active.isEmpty() && !dragId.isEmpty(); }

    void heartbeat() {
        if (dragging()) listener.drag(active, "move", dragId, normalizedX(currentX), normalizedY(currentY));
    }

    void move(double x, double y) {
        if (active.isEmpty()) return;
        currentX = x;
        currentY = y;
        if (scrolling) {
            remainder += y - lastY;
            lastY = y;
            double delta = Math.copySign(Math.floor(Math.abs(remainder)), remainder);
            remainder -= delta;
            if (delta != 0) listener.scroll(active, (startX - left) / width, (startY - top) / height, delta);
            return;
        }
        if (!dragging() && (Math.abs(x - startX) > touchSlop || Math.abs(y - startY) > touchSlop)) {
            moved = true;
            lastTapCapture = "";
            dragId = java.util.UUID.randomUUID().toString();
            listener.drag(active, "start", dragId, normalizedX(startX), normalizedY(startY));
        }
        heartbeat();
    }

    boolean up(double x, double y, long time) {
        if (active.isEmpty()) return false;
        move(x, y);
        if (dragging()) {
            String authority = active, endedDrag = dragId;
            active = "";
            dragId = "";
            lastTapCapture = "";
            listener.drag(authority, "end", endedDrag, normalizedX(x), normalizedY(y));
            return false;
        }
        if (longPress(time)) return false;
        String authority = active;
        active = "";
        if (scrolling && Math.abs(remainder) >= 0.5) listener.scroll(authority, (startX - left) / width, (startY - top) / height, Math.copySign(1, remainder));
        if (scrolling || moved || !contains(x, y)) {
            lastTapCapture = "";
            return false;
        }
        double dx = startX - lastTapX, dy = startY - lastTapY;
        boolean quick = time >= downAt && time - downAt < longPressTimeout;
        boolean twice = quick && authority.equals(lastTapCapture) && downAt >= lastTapAt && downAt - lastTapAt <= doubleTapTimeout
                && dx * dx + dy * dy <= doubleTapSlop * doubleTapSlop;
        double normalizedX = twice ? lastTapNormalizedX : (x - left) / width;
        double normalizedY = twice ? lastTapNormalizedY : (y - top) / height;
        lastTapCapture = twice || !quick ? "" : authority;
        lastTapAt = time;
        lastTapX = x;
        lastTapY = y;
        lastTapNormalizedX = normalizedX;
        lastTapNormalizedY = normalizedY;
        listener.tap(authority, normalizedX, normalizedY, twice ? 2 : 1);
        return true;
    }

    boolean longPress(long time) {
        if (active.isEmpty() || scrolling || moved || dragging() || time - downAt < longPressTimeout || !contains(currentX, currentY)) return false;
        String authority = active;
        cancel();
        listener.rightClick(authority, (currentX - left) / width, (currentY - top) / height);
        return true;
    }

    private boolean contains(double x, double y) {
        return width > 0 && height > 0 && x >= left && x < left + width && y >= top && y < top + height;
    }

    private double normalizedX(double x) { return width > 0 ? Math.max(0, Math.min(1, (x - left) / width)) : 0; }
    private double normalizedY(double y) { return height > 0 ? Math.max(0, Math.min(1, (y - top) / height)) : 0; }
}
