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
  var frame = $('frame');
  function notice(message, error) { $('notice').textContent = message; $('notice').classList.toggle('error', !!error); }
  function panel(id, button, visible) { $(id).hidden = !visible; $(button).setAttribute('aria-expanded', String(visible)); }
  function updateControls() {
    var allowed = active && initialized && !pendingSettings && status && status.capturing && status.permission && status.capture_session && status.inputEnabled && failures === 0;
    $('control').disabled = !allowed;
    if (!allowed) $('control').checked = false;
    var control = allowed && $('control').checked;
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
    frameRevision += 1; frameID = -1;
    if (cancelDecode) { var cancel = cancelDecode; cancelDecode = null; cancel(); }
    frame.hidden = true; frame.removeAttribute('src'); $('placeholder').hidden = false;
    if (currentURL) URL.revokeObjectURL(currentURL);
    currentURL = null; $('control').checked = false;
  }
  function applyStatus(next) {
    if (!next.capturing || !next.permission || (status && (next.displayID !== status.displayID || next.capture_session !== status.capture_session)) || (Number.isFinite(next.frameID) && next.frameID < frameID)) clearFrame();
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
    notice(statusMessage(next));
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
  async function request(path, options, run) {
    var controller = new AbortController();
    var parent = session.signal;
    var abort = function () { controller.abort(); };
    parent.addEventListener('abort', abort);
    if (parent.aborted) controller.abort();
    var timeout = setTimeout(abort, 8000);
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
    } finally { clearTimeout(timeout); parent.removeEventListener('abort', abort); }
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
  async function input(payload) {
    if (!active || !status || !status.inputEnabled || !$('control').checked || $('control').disabled) return;
    var run = generation;
    payload = Object.assign({}, payload, { capture_session: status.capture_session });
    try { await request('/api/input', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }, run); }
    catch (error) { if (run !== generation) return; $('control').checked = false; updateControls(); if (error.status === 401) handleError(error, run); else notice('Mac control is unavailable: ' + error.message + '. Enable input and Accessibility permission on the Mac.', true); }
  }
  $('pairForm').addEventListener('submit', connect);
  $('disconnect').addEventListener('click', function () { stop(true); panel('pairPanel', 'pairButton', true); notice('Disconnected. Paste a session token to reconnect.'); });
  $('pairButton').addEventListener('click', function () { panel('pairPanel', 'pairButton', $('pairPanel').hidden); });
  $('settingsButton').addEventListener('click', function () { panel('settingsPanel', 'settingsButton', $('settingsPanel').hidden); });
  ['fps', 'grayscale', 'maxWidth'].forEach(function (id) { $(id).addEventListener('change', settings); });
  $('control').addEventListener('change', updateControls);
  $('scrollUp').addEventListener('click', function () { input({ type: 'scroll', deltaY: 300 }); });
  $('scrollDown').addEventListener('click', function () { input({ type: 'scroll', deltaY: -300 }); });
  $('viewport').addEventListener('click', function (event) { if (event.target !== frame) return; var point = normalizedPoint(frame.getBoundingClientRect(), event.clientX, event.clientY); if (point) input({ type: 'tap', x: point.x, y: point.y }); });
  $('reload').addEventListener('click', function () { frameRevision += 1; frameID = -1; notice('Requesting the latest frame. Use the BOOX system controls for a hardware screen refresh.'); });
  $('fit').addEventListener('click', function () { fit = !fit; $('viewport').classList.toggle('actual', !fit); $('fit').setAttribute('aria-pressed', String(fit)); $('fit').textContent = fit ? 'Fit screen' : 'Actual size'; });
  $('fullscreen').addEventListener('click', async function () { try { if (document.fullscreenElement) await document.exitFullscreen(); else if (document.documentElement.requestFullscreen) await document.documentElement.requestFullscreen(); else notice('Fullscreen is not supported by this browser.'); } catch (_) { notice('The browser could not enter fullscreen.'); } });
  document.addEventListener('fullscreenchange', function () { $('fullscreen').textContent = document.fullscreenElement ? 'Exit fullscreen' : 'Fullscreen'; });
  root.addEventListener('pagehide', function () { stop(false); });
  updateControls();
  var hashToken = tokenFromHash(root.location.hash);
  try { $('token').value = hashToken || sessionStorage.getItem('booxToken') || ''; } catch (_) { $('token').value = hashToken; }
  if (hashToken) { try { history.replaceState(null, '', root.location.pathname + root.location.search); } catch (_) {} }
})(typeof window !== 'undefined' ? window : globalThis);
