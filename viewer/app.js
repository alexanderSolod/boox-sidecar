(function (root) {
  'use strict';
  function normalizedPoint(rect, clientX, clientY) {
    if (!(rect.width > 0 && rect.height > 0)) return null;
    var x = (clientX - rect.left) / rect.width;
    var y = (clientY - rect.top) / rect.height;
    return Number.isFinite(x) && Number.isFinite(y) && x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x: x, y: y } : null;
  }
  function frameDelay(fps, elapsed) { return Math.max(0, 1000 / Math.max(1, Math.min(60, Number(fps) || 60)) - elapsed); }
  function tokenFromHash(hash) { return new URLSearchParams(hash.replace(/^#/, '')).get('token') || ''; }
  function statusMessage(status) {
    if (!status.permission) return 'Allow Screen Recording for BOOX Sidecar in Mac System Settings, then start capture on your Mac.';
    if (!status.capturing) return 'Connected. Choose Start capture in the Mac app.';
    return status.message || 'USB display connected. BOOX refresh mode is controlled on the tablet.';
  }
  var helpers = { normalizedPoint: normalizedPoint, frameDelay: frameDelay, tokenFromHash: tokenFromHash, statusMessage: statusMessage };
  if (typeof module !== 'undefined' && module.exports) module.exports = helpers;
  if (!root.document) return;

  var $ = function (id) { return document.getElementById(id); };
  var active = false, generation = 0, session = null, token = '', status = null;
  var frameID = -1, currentURL = null, timer = null, lastStatusAt = 0, failures = 0, fit = true, pendingSettings = false, frameRevision = 0;
  var initialized = false, knownDisplays = [], cancelDecode = null;
  var inputQueue = [], inputEpoch = 0, inputDraining = false, inputRequest = null, inputMessage = '', inputPaused = false, pausedCapture = '';
  var touchGesture = null, lastTouchTap = null, ignoreClickUntil = 0, suppressTouchClick = false, wheelRemainder = 0, longPressTimer = null, lastPointerKind = 'mouse';
  var pointers = new Map(), scrollGesture = null, pointersBlocked = false, dragTimer = null, remoteDrag = null, cleanupRequest = null, wheelPoint = null;
  var frame = $('frame');
  function notice(message, error) { $('notice').textContent = message; $('notice').classList.toggle('error', !!error); }
  function panel(id, button, visible) { $(id).hidden = !visible; $(button).setAttribute('aria-expanded', String(visible)); }
  function updateControls() {
    var allowed = inputReady(), control = allowed && !inputPaused;
    $('inputStatus').textContent = inputPaused ? 'Remote input paused' : control ? 'Remote input enabled on Mac' : status && !status.inputEnabled ? 'Enable remote input on the Mac' : 'Remote input unavailable';
    $('resumeInput').hidden = !inputPaused;
    $('resumeInput').disabled = !allowed;
    if (!control && (inputDraining || inputQueue.length || inputRequest || touchGesture || lastTouchTap)) clearInput();
    $('scrollUp').disabled = !control;
    $('scrollDown').disabled = !control;
    $('viewport').classList.toggle('controlling', !!control);
    $('reload').disabled = !active;
    $('disconnect').disabled = !active;
    $('connect').disabled = active;
    ['fps', 'grayscale', 'maxWidth'].forEach(function (id) { $(id).disabled = !active || !initialized || pendingSettings; });
    $('frameInfo').textContent = (status && frameID >= 0 ? status.width + ' × ' + status.height + ' · ' : '') + (control ? 'Control enabled' : 'Viewing only');
  }
  function clearFrame() {
    clearInput();
    frameRevision += 1; frameID = -1;
    if (cancelDecode) { var cancel = cancelDecode; cancelDecode = null; cancel(); }
    frame.hidden = true; frame.removeAttribute('src'); $('placeholder').hidden = false;
    if (currentURL) URL.revokeObjectURL(currentURL);
    currentURL = null;
  }
  function applyStatus(next) {
    if (!next.capturing || !next.permission || (status && (next.displayID !== status.displayID || next.capture_session !== status.capture_session)) || (Number.isFinite(next.frameID) && next.frameID < frameID)) clearFrame();
    if (inputPaused && next.capture_session && next.capture_session !== pausedCapture) { inputPaused = false; inputMessage = ''; pausedCapture = ''; }
    status = next;
    var fps = String(next.fps || 60), fpsSelect = $('fps');
    if (!Array.from(fpsSelect.options || fpsSelect.children).some(function (option) { return String(option.value) === fps; })) {
      var customFPS = document.createElement('option'); customFPS.value = fps; customFPS.textContent = fps; fpsSelect.appendChild(customFPS);
    }
    fpsSelect.value = fps;
    $('grayscale').checked = !!next.grayscale;
    if (Number.isFinite(next.maxWidth)) {
      var width = String(next.maxWidth), select = $('maxWidth');
      if (!Array.from(select.options || select.children).some(function (option) { return String(option.value) === width; })) {
        var custom = document.createElement('option'); custom.value = width; custom.textContent = width + ' px'; select.appendChild(custom);
      }
      select.value = width;
    }
    updateDisplay();
    $('connection').textContent = next.capturing && next.permission ? 'Connected · live' : 'Connected · waiting';
    $('guidance').textContent = statusMessage(next);
    notice(inputMessage || statusMessage(next), !!inputMessage);
    updateControls();
  }
  function updateDisplay() {
    var source = status && knownDisplays.find(function (display) { return display.id === status.displayID; });
    $('display').textContent = source ? source.name + ' · ' + source.width + ' × ' + source.height : (status && status.displayID != null ? 'Display ' + status.displayID + ' · selected on Mac' : 'Waiting for Mac');
  }
  function stop(clearToken) {
    active = false; generation += 1;
    if (session) session.abort();
    clearTimeout(timer); timer = null; status = null; frameID = -1; pendingSettings = false; initialized = false;
    clearFrame();
    $('display').textContent = 'Waiting for Mac';
    knownDisplays = [];
    $('connection').textContent = 'Not connected';
    $('guidance').textContent = 'Connect above to start viewing a display.';
    if (clearToken) { token = ''; $('token').value = ''; try { sessionStorage.removeItem('booxToken'); } catch (_) {} }
    updateControls();
  }
  async function request(path, options, run, inputSignal) {
    var controller = new AbortController();
    var parent = session.signal;
    var abort = function () { controller.abort(); };
    parent.addEventListener('abort', abort);
    if (inputSignal) inputSignal.addEventListener('abort', abort);
    if (parent.aborted) controller.abort();
    if (inputSignal && inputSignal.aborted) controller.abort();
    var timeout = setTimeout(abort, inputSignal ? 2000 : 8000);
    try {
      var response = await fetch(path, Object.assign({}, options, {
        cache: 'no-store', credentials: 'omit', signal: controller.signal,
        headers: Object.assign({ Authorization: 'Bearer ' + token }, options && options.headers)
      }));
      if (run !== generation) throw new Error('Obsolete session');
      if (!response.ok) {
        var message = 'Mac returned HTTP ' + response.status;
        try { var payload = await response.json(); if (payload.error) message = payload.error; } catch (_) {}
        var error = new Error(message); error.status = response.status; throw error;
      }
      // Consume the body under the same timeout and cancellation signal.
      if (path.indexOf('/api/frame') === 0) return response.status === 204 ? null : { blob: await response.blob(), id: Number(response.headers.get('X-Frame-ID')), captureSession: response.headers.get('X-Capture-Session') };
      return await response.json();
    } finally { clearTimeout(timeout); parent.removeEventListener('abort', abort); if (inputSignal) inputSignal.removeEventListener('abort', abort); }
  }
  function handleError(error, run) {
    if (run !== generation || !active) return;
    if (error.status === 401) {
      stop(true); panel('pairPanel', 'pairButton', true);
      notice('Session token was rejected. Copy the current token from the Mac app and connect again.', true);
      return;
    }
    if (error.code === 'PROTOCOL') { stop(false); panel('pairPanel', 'pairButton', true); notice(error.message, true); return; }
    failures += 1;
    clearFrame();
    $('connection').textContent = 'Connection interrupted';
    notice('Cannot reach the Mac: ' + (error.name === 'AbortError' ? 'request timed out' : error.message) + '. Check USB and the host app. Retrying…', true);
    updateControls();
  }
  function decode(blob, run) {
    return new Promise(function (resolve, reject) {
      var image = new Image(), url = URL.createObjectURL(blob), done = false;
      var parent = session.signal;
      function finish(error) {
        if (done) return; done = true; clearTimeout(timeout); parent.removeEventListener('abort', aborted);
        image.onload = null; image.onerror = null;
        if (cancelDecode === stale) cancelDecode = null;
        if (error || run !== generation) { URL.revokeObjectURL(url); reject(error || new Error('Obsolete session')); }
        else resolve({ image: image, url: url });
      }
      function aborted() { finish(new Error('Obsolete session')); }
      function stale() { var error = new Error('Obsolete capture session'); error.code = 'STALE_FRAME'; finish(error); image.removeAttribute('src'); }
      cancelDecode = stale;
      var timeout = setTimeout(function () { finish(new Error('Frame decoding timed out')); }, 8000);
      parent.addEventListener('abort', aborted);
      image.onload = function () { finish(); };
      image.onerror = function () { finish(new Error('Could not decode the Mac frame')); };
      image.src = url;
      if (parent.aborted) aborted();
    });
  }
  function validateProtocol(next) {
    if (next.protocol !== 2 || (next.capturing && (typeof next.capture_session !== 'string' || !next.capture_session))) { var error = new Error('This host uses an unsupported protocol. Update the viewer and host together.'); error.code = 'PROTOCOL'; throw error; }
  }
  async function initialize(run) {
    var next = await request('/api/status', {}, run);
    if (run !== generation) return;
    validateProtocol(next);
    var displays = await request('/api/displays', {}, run);
    if (run !== generation) return;
    knownDisplays = displays.displays;
    initialized = true; failures = 0; lastStatusAt = Date.now(); applyStatus(next);
    panel('pairPanel', 'pairButton', false);
  }
  async function poll(run) {
    if (!active || run !== generation) return;
    var started = Date.now();
    try {
      if (!initialized) await initialize(run);
      if (!active || run !== generation) return;
      if (!pendingSettings && (!status || Date.now() - lastStatusAt >= 2000 || failures)) {
        var statusRevision = frameRevision;
        var next = await request('/api/status', {}, run);
        if (run !== generation) return;
        validateProtocol(next);
        if (statusRevision === frameRevision && !pendingSettings) {
          failures = 0; lastStatusAt = Date.now(); applyStatus(next);
          var displayRevision = frameRevision;
          var displays = await request('/api/displays', {}, run);
          if (run !== generation) return;
          if (displayRevision === frameRevision && !pendingSettings) { knownDisplays = displays.displays; updateDisplay(); }
        }
      }
      if (status && status.capturing && status.permission && !pendingSettings) {
        var revision = frameRevision, captureSession = status.capture_session;
        var result = await request('/api/frame?after=' + frameID, {}, run);
        if (run !== generation) return;
        if (result && revision === frameRevision) {
          if (result.captureSession !== captureSession) {
            clearFrame(); status = null; lastStatusAt = 0; updateControls();
            var mismatch = new Error('Obsolete capture session'); mismatch.code = 'STALE_FRAME'; throw mismatch;
          }
          var decoded = await decode(result.blob, run);
          if (run !== generation || revision !== frameRevision || !status || captureSession !== status.capture_session) { URL.revokeObjectURL(decoded.url); }
          else {
          decoded.image.id = 'frame'; decoded.image.alt = 'Live view of the selected Mac display'; decoded.image.draggable = false;
          frame.replaceWith(decoded.image); frame = decoded.image;
          if (currentURL) URL.revokeObjectURL(currentURL);
          currentURL = decoded.url; frameID = Number.isFinite(result.id) ? result.id : -1;
          $('placeholder').hidden = true;
          updateControls();
          }
        }
      }
    } catch (error) { if (error.code !== 'STALE_FRAME') handleError(error, run); }
    if (active && run === generation) timer = setTimeout(function () { poll(run); }, failures ? Math.min(8000, 1000 * Math.pow(2, failures - 1)) : frameDelay(status && status.fps, Date.now() - started));
  }
  async function connect(event) {
    event.preventDefault();
    var supplied = $('token').value.trim();
    if (!supplied) return;
    stop(false); token = supplied; active = true; session = new AbortController(); failures = 0; lastStatusAt = 0;
    var run = generation;
    try { sessionStorage.setItem('booxToken', token); } catch (_) {}
    $('connection').textContent = 'Connecting…'; notice('Connecting to the Mac host…'); updateControls();
    poll(run);
  }

  async function settings(event) {
    if (!active || !initialized || pendingSettings) return;
    var key = event.target.id;
    if (!['fps', 'grayscale', 'maxWidth'].includes(key)) return;
    var value = key === 'grayscale' ? event.target.checked : Number(event.target.value);
    var payload = {}; payload[key] = value;
    var run = generation; pendingSettings = true; frameRevision += 1; frameID = -1;
    updateControls();
    try {
      var next = await request('/api/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }, run);
      if (run !== generation) return;
      frameID = -1; lastStatusAt = Date.now(); applyStatus(next);
    } catch (error) { handleError(error, run); }
    finally { if (run === generation) { pendingSettings = false; updateControls(); } }
  }
  function clearInput() {
    var abandoned = remoteDrag;
    remoteDrag = null;
    inputEpoch += 1; inputQueue = []; inputDraining = false;
    clearTimeout(longPressTimer); longPressTimer = null;
    clearTimeout(dragTimer); dragTimer = null;
    if (touchGesture) suppressTouchClick = true;
    touchGesture = null; lastTouchTap = null; wheelRemainder = 0;
    scrollGesture = null; pointers.clear(); pointersBlocked = false; wheelPoint = null;
    if (inputRequest) inputRequest.abort();
    inputRequest = null;
    if (abandoned) cancelRemoteDrag(abandoned);
  }
  function cancelRemoteDrag(drag) {
    if (cleanupRequest) cleanupRequest.abort();
    var controller = new AbortController(); cleanupRequest = controller;
    var timeout = setTimeout(function () { controller.abort(); }, 1000);
    fetch('/api/input', { method: 'POST', cache: 'no-store', credentials: 'omit', keepalive: true, signal: controller.signal,
      headers: { Authorization: 'Bearer ' + drag.token, 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({}, drag.payload, { phase: 'cancel' }))
    }).catch(function () {}).finally(function () { clearTimeout(timeout); if (cleanupRequest === controller) cleanupRequest = null; });
  }
  function pauseInput(reason) {
    clearInput(); inputPaused = true; pausedCapture = status ? status.capture_session : '';
    inputMessage = reason + ' Remote input paused; choose Resume input to continue.';
    updateControls(); notice(inputMessage, true);
  }
  function inputTime() { return root.performance ? root.performance.now() : Date.now(); }
  function input(payload) {
    if (!controlling()) return;
    payload = Object.assign({}, payload, { capture_session: status.capture_session });
    var now = inputTime(), tail = inputQueue[inputQueue.length - 1];
    if (inputQueue.length && now - inputQueue[0].createdAt >= 2000) { pauseInput('Input waited too long.'); return; }
    if (payload.type === 'scroll' && tail && tail.payload.type === 'scroll' && tail.payload.x === payload.x && tail.payload.y === payload.y && Math.sign(tail.payload.deltaY) === Math.sign(payload.deltaY)) {
      tail.payload.deltaY += payload.deltaY;
    } else if (payload.type === 'drag' && payload.phase === 'move' && tail && tail.payload.type === 'drag' && tail.payload.phase === 'move' && tail.payload.drag_id === payload.drag_id) {
      tail.payload = payload;
    } else {
      if (inputQueue.length >= 64) { pauseInput('Too much input is waiting.'); return; }
      inputQueue.push({ payload: payload, createdAt: now });
    }
    if (!inputDraining) { inputDraining = true; drainInput(generation, inputEpoch); }
  }
  async function drainInput(run, epoch) {
    while (run === generation && epoch === inputEpoch && inputQueue.length) {
      var next = inputQueue.shift(), payload = next.payload;
      if (inputTime() - next.createdAt >= 2000) { pauseInput('Input waited too long.'); return; }
      if (payload.type === 'scroll' && Math.abs(payload.deltaY) > 1000) {
        var delta = Math.sign(payload.deltaY) * 1000;
        inputQueue.unshift({ payload: Object.assign({}, payload, { deltaY: payload.deltaY - delta }), createdAt: next.createdAt });
        payload = Object.assign({}, payload, { deltaY: delta });
      }
      if (payload.type === 'drag' && (payload.phase === 'start' || payload.phase === 'move')) remoteDrag = { payload: payload, token: token };
      inputRequest = new AbortController();
      try { await request('/api/input', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }, run, inputRequest.signal); }
      catch (error) {
        if (run !== generation || epoch !== inputEpoch) return;
        pauseInput('Input delivery could not be confirmed.');
        if (error.status === 401) handleError(error, run);
        return;
      }
      if (run !== generation || epoch !== inputEpoch) return;
      if (payload.type === 'drag' && (payload.phase === 'end' || payload.phase === 'cancel') && remoteDrag && remoteDrag.payload.drag_id === payload.drag_id) remoteDrag = null;
      inputRequest = null;
    }
    if (epoch === inputEpoch) inputDraining = false;
  }
  function inputReady() { return !!(active && initialized && !pendingSettings && frameID >= 0 && status && status.capturing && status.permission && status.capture_session && status.inputEnabled && failures === 0); }
  function controlling() { return inputReady() && !inputPaused; }
  function dragPoint(rect, x, y) {
    return normalizedPoint(rect, Math.max(rect.left, Math.min(rect.left + rect.width, x)), Math.max(rect.top, Math.min(rect.top + rect.height, y)));
  }
  function sameGeometry(rect) {
    var current = frame.getBoundingClientRect();
    return current.left === rect.left && current.top === rect.top && current.width === rect.width && current.height === rect.height;
  }
  function dragID() {
    if (root.crypto.randomUUID) return root.crypto.randomUUID();
    var bytes = root.crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    var hex = Array.from(bytes, function (value) { return value.toString(16).padStart(2, '0'); }).join('');
    return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
  }
  function dragInput(gesture, phase, point) {
    input({ type: 'drag', phase: phase, drag_id: gesture.dragID, x: point.x, y: point.y });
  }
  function finishDrag(phase) {
    clearTimeout(dragTimer); dragTimer = null;
    if (!touchGesture || !touchGesture.dragID) return;
    var gesture = touchGesture;
    if (controlling()) dragInput(gesture, phase, gesture.point);
    else if (remoteDrag) { var abandoned = remoteDrag; remoteDrag = null; cancelRemoteDrag(abandoned); }
    gesture.dragID = null;
  }
  function heartbeat(gesture) {
    dragTimer = setTimeout(function () {
      dragTimer = null;
      if (touchGesture !== gesture || !gesture.dragID || gesture.epoch !== inputEpoch) return;
      if (!controlling() || !sameGeometry(gesture.rect)) { cancelTouch(); return; }
      dragInput(gesture, 'move', gesture.point);
      if (touchGesture === gesture && gesture.dragID && gesture.epoch === inputEpoch) heartbeat(gesture);
    }, 500);
  }
  function cancelTouch() {
    finishDrag('cancel');
    clearTimeout(longPressTimer); longPressTimer = null;
    touchGesture = null; scrollGesture = null; lastTouchTap = null; pointersBlocked = pointers.size > 0;
    suppressTouchClick = true; ignoreClickUntil = inputTime() + 500;
  }
  function longPress(gesture) {
    longPressTimer = null;
    if (touchGesture !== gesture || gesture.kind === 'mouse' || gesture.longPressed || gesture.dragID || gesture.moved || !controlling() || gesture.epoch !== inputEpoch) return;
    if (!sameGeometry(gesture.rect)) { cancelTouch(); return; }
    var point = normalizedPoint(gesture.rect, gesture.x, gesture.y);
    if (!point) return;
    gesture.longPressed = true; lastTouchTap = null;
    input({ type: 'rightClick', x: point.x, y: point.y });
  }
  function centroid() {
    var values = Array.from(pointers.values());
    return { x: (values[0].x + values[1].x) / 2, y: (values[0].y + values[1].y) / 2 };
  }
  function moveTouch(event) {
    var pointer = pointers.get(event.pointerId);
    if (!pointer) return;
    pointer.x = event.clientX; pointer.y = event.clientY;
    if (pointersBlocked) return;
    var gesture = scrollGesture || touchGesture;
    if (!gesture) return;
    if (!controlling() || gesture.epoch !== inputEpoch || !sameGeometry(gesture.rect)) { cancelTouch(); return; }
    if (scrollGesture) {
      if (pointers.size !== 2) { cancelTouch(); return; }
      var center = centroid();
      if (!gesture.moved && Math.abs(center.y - gesture.y) > 8) gesture.moved = true;
      if (gesture.moved) {
        gesture.remainder += center.y - gesture.lastY; gesture.lastY = center.y;
        var delta = Math.trunc(gesture.remainder); gesture.remainder -= delta;
        if (delta) input({ type: 'scroll', deltaY: delta, x: gesture.point.x, y: gesture.point.y });
      }
    } else {
      if (gesture.id !== event.pointerId || gesture.longPressed) { event.preventDefault(); return; }
      if (Math.abs(event.clientX - gesture.x) > 8 || Math.abs(event.clientY - gesture.y) > 8) gesture.moved = true;
      if (gesture.moved) {
        clearTimeout(longPressTimer); longPressTimer = null; lastTouchTap = null;
        if (!gesture.dragID) {
          if (!root.crypto) { pauseInput('Drag is unavailable in this browser.'); return; }
          gesture.dragID = dragID();
          dragInput(gesture, 'start', gesture.point);
          if (touchGesture !== gesture || gesture.epoch !== inputEpoch) return;
          heartbeat(gesture);
        }
        gesture.point = dragPoint(gesture.rect, event.clientX, event.clientY);
        dragInput(gesture, 'move', gesture.point);
      }
    }
    event.preventDefault();
  }
  $('pairForm').addEventListener('submit', connect);
  $('disconnect').addEventListener('click', function () { stop(true); panel('pairPanel', 'pairButton', true); notice('Disconnected. Paste a session token to reconnect.'); });
  $('pairButton').addEventListener('click', function () { panel('pairPanel', 'pairButton', $('pairPanel').hidden); });
  $('settingsButton').addEventListener('click', function () { panel('settingsPanel', 'settingsButton', $('settingsPanel').hidden); });
  ['fps', 'grayscale', 'maxWidth'].forEach(function (id) { $(id).addEventListener('change', settings); });
  $('resumeInput').addEventListener('click', function () {
    if (!inputPaused || !inputReady()) return;
    clearInput(); inputPaused = false; inputMessage = ''; pausedCapture = '';
    updateControls(); notice(statusMessage(status));
  });
  $('scrollUp').addEventListener('click', function () { input({ type: 'scroll', deltaY: 300 }); });
  $('scrollDown').addEventListener('click', function () { input({ type: 'scroll', deltaY: -300 }); });
  $('viewport').addEventListener('click', function (event) {
    if (suppressTouchClick) { suppressTouchClick = false; return; }
    if (event.target !== frame || inputTime() < ignoreClickUntil) return;
    var point = normalizedPoint(frame.getBoundingClientRect(), event.clientX, event.clientY);
    if (point) input({ type: 'tap', x: point.x, y: point.y, clickCount: event.detail === 2 ? 2 : 1 });
  });
  $('viewport').addEventListener('wheel', function (event) {
    if (!controlling() || event.target !== frame) return;
    var rect = frame.getBoundingClientRect();
    var point = normalizedPoint(rect, event.clientX, event.clientY);
    if (!point) return;
    var scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? rect.height : 1;
    if (!Number.isFinite(event.deltaY)) return;
    if (!wheelPoint || wheelPoint.x !== point.x || wheelPoint.y !== point.y) wheelRemainder = 0;
    wheelPoint = point;
    wheelRemainder -= event.deltaY * scale;
    var delta = Math.trunc(wheelRemainder); wheelRemainder -= delta;
    if (delta) input({ type: 'scroll', deltaY: delta, x: point.x, y: point.y });
    event.preventDefault();
  }, { passive: false });
  $('viewport').addEventListener('pointerdown', function (event) {
    var kind = event.pointerType || 'mouse';
    lastPointerKind = kind;
    if (kind === 'mouse' && event.button != null && event.button !== 0) return;
    if (!controlling()) return;
    if (!pointers.size && (event.isPrimary === false || event.target !== frame)) return;
    var rect = frame.getBoundingClientRect();
    var point = normalizedPoint(rect, event.clientX, event.clientY);
    if (!point && !pointers.size) return;
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, kind: kind });
    if ($('viewport').setPointerCapture) $('viewport').setPointerCapture(event.pointerId);
    suppressTouchClick = true;
    if (pointersBlocked || !point || pointers.size > 2 || (pointers.size === 2 && Array.from(pointers.values()).some(function (pointer) { return pointer.kind !== 'touch'; }))) { cancelTouch(); event.preventDefault(); return; }
    if (pointers.size === 2) {
      finishDrag('cancel');
      if (pointers.size !== 2 || !controlling()) return;
      clearTimeout(longPressTimer); longPressTimer = null;
      touchGesture = null; lastTouchTap = null;
      var center = centroid();
      scrollGesture = { epoch: inputEpoch, rect: rect, y: center.y, lastY: center.y, point: normalizedPoint(rect, center.x, center.y), remainder: 0, moved: false };
      event.preventDefault(); return;
    }
    touchGesture = { id: event.pointerId, kind: kind, epoch: inputEpoch, rect: rect, x: event.clientX, y: event.clientY, point: point, downAt: inputTime(), dragID: null, moved: false, longPressed: false };
    if (kind !== 'mouse') { var gesture = touchGesture; longPressTimer = setTimeout(function () { longPress(gesture); }, 500); }
    event.preventDefault();
  });
  $('viewport').addEventListener('pointermove', moveTouch);
  $('viewport').addEventListener('pointerup', function (event) {
    moveTouch(event);
    pointers.delete(event.pointerId);
    if (scrollGesture) {
      if (scrollGesture.moved && Math.abs(scrollGesture.remainder) >= 0.5) input({ type: 'scroll', deltaY: Math.sign(scrollGesture.remainder), x: scrollGesture.point.x, y: scrollGesture.point.y });
      scrollGesture = null; lastTouchTap = null; pointersBlocked = pointers.size > 0;
      ignoreClickUntil = inputTime() + 500;
      return;
    }
    if (pointersBlocked) { if (!pointers.size) pointersBlocked = false; return; }
    var gesture = touchGesture;
    if (!gesture || gesture.id !== event.pointerId) return;
    clearTimeout(longPressTimer); longPressTimer = null;
    if (gesture.dragID) { finishDrag('end'); touchGesture = null; ignoreClickUntil = inputTime() + 500; return; }
    if (gesture.kind !== 'mouse' && inputTime() - gesture.downAt >= 500) longPress(gesture);
    touchGesture = null; ignoreClickUntil = inputTime() + 500;
    if (gesture.longPressed) return;
    var point = normalizedPoint(gesture.rect, event.clientX, event.clientY);
    if (!gesture.moved && point) {
      var quick = inputTime() - gesture.downAt < 500;
      var twice = quick && lastTouchTap && lastTouchTap.kind === gesture.kind && gesture.downAt - lastTouchTap.time <= (gesture.kind === 'mouse' ? 500 : 300)
        && Math.hypot(gesture.x - lastTouchTap.x, gesture.y - lastTouchTap.y) <= (gesture.kind === 'mouse' ? 5 : 30);
      if (twice) point = lastTouchTap.point;
      lastTouchTap = twice || !quick ? null : { kind: gesture.kind, time: inputTime(), x: event.clientX, y: event.clientY, point: point };
      input({ type: 'tap', x: point.x, y: point.y, clickCount: twice ? 2 : 1 });
    } else lastTouchTap = null;
  });
  $('viewport').addEventListener('pointercancel', function (event) { pointers.delete(event.pointerId); cancelTouch(); });
  $('viewport').addEventListener('lostpointercapture', function (event) { if (pointers.has(event.pointerId)) { pointers.delete(event.pointerId); cancelTouch(); } });
  $('viewport').addEventListener('contextmenu', function (event) {
    if (!controlling()) return;
    var point = normalizedPoint(frame.getBoundingClientRect(), event.clientX, event.clientY);
    if (!point) return;
    event.preventDefault();
    if ((event.pointerType || lastPointerKind) !== 'mouse') return;
    cancelTouch(); input({ type: 'rightClick', x: point.x, y: point.y });
  });
  $('reload').addEventListener('click', function () { clearInput(); frameRevision += 1; frameID = -1; updateControls(); notice('Requesting the latest frame. Use the BOOX system controls for a hardware screen refresh.'); });
  $('fit').addEventListener('click', function () { clearInput(); fit = !fit; $('viewport').classList.toggle('actual', !fit); $('fit').setAttribute('aria-pressed', String(fit)); $('fit').textContent = fit ? 'Fit screen' : 'Actual size'; });
  $('fullscreen').addEventListener('click', async function () { try { if (document.fullscreenElement) await document.exitFullscreen(); else if (document.documentElement.requestFullscreen) await document.documentElement.requestFullscreen(); else notice('Fullscreen is not supported by this browser.'); } catch (_) { notice('The browser could not enter fullscreen.'); } });
  document.addEventListener('fullscreenchange', function () { clearInput(); $('fullscreen').textContent = document.fullscreenElement ? 'Exit fullscreen' : 'Fullscreen'; });
  root.addEventListener('resize', clearInput);
  root.addEventListener('pagehide', function () { stop(false); });
  updateControls();
  var hashToken = tokenFromHash(root.location.hash);
  try { $('token').value = hashToken || sessionStorage.getItem('booxToken') || ''; } catch (_) { $('token').value = hashToken; }
  if (hashToken) { try { history.replaceState(null, '', root.location.pathname + root.location.search); } catch (_) {} }
})(typeof window !== 'undefined' ? window : globalThis);
