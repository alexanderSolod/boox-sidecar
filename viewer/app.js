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
    inputEpoch += 1; inputQueue = []; inputDraining = false;
    clearTimeout(longPressTimer); longPressTimer = null;
    if (touchGesture) suppressTouchClick = true;
    touchGesture = null; lastTouchTap = null; wheelRemainder = 0;
    if (inputRequest) inputRequest.abort();
    inputRequest = null;
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
    if (payload.type === 'scroll' && tail && tail.payload.type === 'scroll' && Math.sign(tail.payload.deltaY) === Math.sign(payload.deltaY)) {
      tail.payload.deltaY += payload.deltaY;
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
      inputRequest = new AbortController();
      try { await request('/api/input', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }, run, inputRequest.signal); }
      catch (error) {
        if (run !== generation || epoch !== inputEpoch) return;
        pauseInput('Input delivery could not be confirmed.');
        if (error.status === 401) handleError(error, run);
        return;
      }
      if (run !== generation || epoch !== inputEpoch) return;
      inputRequest = null;
    }
    if (epoch === inputEpoch) inputDraining = false;
  }
  function inputReady() { return !!(active && initialized && !pendingSettings && frameID >= 0 && status && status.capturing && status.permission && status.capture_session && status.inputEnabled && failures === 0); }
  function controlling() { return inputReady() && !inputPaused; }
  function cancelTouch() { clearTimeout(longPressTimer); longPressTimer = null; touchGesture = null; lastTouchTap = null; suppressTouchClick = true; ignoreClickUntil = inputTime() + 500; }
  function longPress(gesture) {
    longPressTimer = null;
    if (touchGesture !== gesture || gesture.kind === 'mouse' || gesture.longPressed || gesture.scrolling || gesture.moved || !controlling() || gesture.epoch !== inputEpoch) return;
    var rect = frame.getBoundingClientRect();
    if (rect.left !== gesture.rect.left || rect.top !== gesture.rect.top || rect.width !== gesture.rect.width || rect.height !== gesture.rect.height) { cancelTouch(); return; }
    var point = normalizedPoint(rect, gesture.x, gesture.y);
    if (!point) return;
    gesture.longPressed = true; lastTouchTap = null;
    input({ type: 'rightClick', x: point.x, y: point.y });
  }
  function moveTouch(event) {
    var gesture = touchGesture;
    if (!gesture || gesture.id !== event.pointerId) return;
    var rect = frame.getBoundingClientRect();
    if (!controlling() || gesture.epoch !== inputEpoch || rect.left !== gesture.rect.left || rect.top !== gesture.rect.top || rect.width !== gesture.rect.width || rect.height !== gesture.rect.height) { cancelTouch(); return; }
    if (gesture.longPressed) { event.preventDefault(); return; }
    if (Math.abs(event.clientX - gesture.x) > 8) { gesture.moved = true; lastTouchTap = null; }
    if (Math.abs(event.clientY - gesture.y) > 8) {
      if (gesture.kind === 'mouse') gesture.moved = true;
      else gesture.scrolling = true;
      lastTouchTap = null;
    }
    if (gesture.scrolling || gesture.moved) { clearTimeout(longPressTimer); longPressTimer = null; }
    if (gesture.scrolling) {
      gesture.remainder += event.clientY - gesture.lastY;
      gesture.lastY = event.clientY;
      var delta = Math.trunc(gesture.remainder); gesture.remainder -= delta;
      if (delta) input({ type: 'scroll', deltaY: delta });
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
    if (!normalizedPoint(rect, event.clientX, event.clientY)) return;
    var scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? rect.height : 1;
    if (!Number.isFinite(event.deltaY)) return;
    wheelRemainder -= event.deltaY * scale;
    var delta = Math.trunc(wheelRemainder); wheelRemainder -= delta;
    if (delta) input({ type: 'scroll', deltaY: delta });
    event.preventDefault();
  }, { passive: false });
  $('viewport').addEventListener('pointerdown', function (event) {
    var kind = event.pointerType || 'mouse';
    lastPointerKind = kind;
    if (kind === 'mouse' && event.button != null && event.button !== 0) return;
    if (event.isPrimary === false || touchGesture) { cancelTouch(); return; }
    if (!controlling() || event.target !== frame) return;
    var rect = frame.getBoundingClientRect();
    if (!normalizedPoint(rect, event.clientX, event.clientY)) return;
    suppressTouchClick = true;
    touchGesture = { id: event.pointerId, kind: kind, epoch: inputEpoch, rect: rect, x: event.clientX, y: event.clientY, lastY: event.clientY, downAt: inputTime(), remainder: 0, scrolling: false, moved: false, longPressed: false };
    if (kind !== 'mouse') { var gesture = touchGesture; longPressTimer = setTimeout(function () { longPress(gesture); }, 500); }
    if ($('viewport').setPointerCapture) $('viewport').setPointerCapture(event.pointerId);
    event.preventDefault();
  });
  $('viewport').addEventListener('pointermove', moveTouch);
  $('viewport').addEventListener('pointerup', function (event) {
    moveTouch(event);
    var gesture = touchGesture;
    if (!gesture || gesture.id !== event.pointerId) return;
    clearTimeout(longPressTimer); longPressTimer = null;
    if (gesture.kind !== 'mouse' && inputTime() - gesture.downAt >= 500) longPress(gesture);
    touchGesture = null; ignoreClickUntil = inputTime() + 500;
    if (gesture.longPressed) return;
    var point = normalizedPoint(gesture.rect, event.clientX, event.clientY);
    if (gesture.scrolling && Math.abs(gesture.remainder) >= 0.5) input({ type: 'scroll', deltaY: Math.sign(gesture.remainder) });
    if (!gesture.scrolling && !gesture.moved && point) {
      var quick = inputTime() - gesture.downAt < 500;
      var twice = quick && lastTouchTap && lastTouchTap.kind === gesture.kind && gesture.downAt - lastTouchTap.time <= (gesture.kind === 'mouse' ? 500 : 300)
        && Math.hypot(gesture.x - lastTouchTap.x, gesture.y - lastTouchTap.y) <= (gesture.kind === 'mouse' ? 5 : 30);
      if (twice) point = lastTouchTap.point;
      lastTouchTap = twice || !quick ? null : { kind: gesture.kind, time: inputTime(), x: event.clientX, y: event.clientY, point: point };
      input({ type: 'tap', x: point.x, y: point.y, clickCount: twice ? 2 : 1 });
    } else lastTouchTap = null;
  });
  $('viewport').addEventListener('pointercancel', cancelTouch);
  $('viewport').addEventListener('lostpointercapture', function () { if (touchGesture) cancelTouch(); });
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
