'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizedPoint, frameDelay, tokenFromHash, statusMessage } = require('./app.js');

test('tap coordinates use the displayed image bounds, excluding letterbox', () => {
  const rect = { left: 120, top: 80, width: 800, height: 600 };
  assert.deepEqual(normalizedPoint(rect, 520, 380), { x: 0.5, y: 0.5 });
  assert.deepEqual(normalizedPoint(rect, 120, 80), { x: 0, y: 0 });
  assert.deepEqual(normalizedPoint(rect, 920, 680), { x: 1, y: 1 });
  assert.equal(normalizedPoint(rect, 119, 380), null);
  assert.equal(normalizedPoint(rect, 520, 681), null);
  assert.equal(normalizedPoint(rect, NaN, 380), null);
  assert.equal(normalizedPoint({ left: 0, top: 0, width: 0, height: 0 }, 0, 0), null);
});
test('poll pacing accounts for elapsed work and bounds frequency', () => {
  assert.equal(frameDelay(2, 100), 400);
  assert.equal(frameDelay(2, 900), 0);
  assert.equal(frameDelay(-10, 100), 900);
  assert.equal(frameDelay(100, 0), 1000 / 60);
  assert.equal(frameDelay(undefined, 0), 1000 / 60);
});
test('pairing reads only a named fragment token', () => {
  assert.equal(tokenFromHash('#token=abc%2B123'), 'abc+123');
  assert.equal(tokenFromHash('#other=hello&token=secret'), 'secret');
  assert.equal(tokenFromHash('#unrelated'), '');
});
test('status explains missing Mac permission and capture separately', () => {
  assert.match(statusMessage({ permission: false, capturing: false }), /Screen Recording/);
  assert.match(statusMessage({ permission: true, capturing: false }), /Start capture/);
  assert.equal(statusMessage({ permission: true, capturing: true, message: 'Waiting for a frame' }), 'Waiting for a frame');
});

const vm = require('node:vm');
const fs = require('node:fs');
function browserHarness(intercept) {
  const elements = new Map(), images = [], revoked = [], timers = new Map(), calls = [];
  let timerID = 0, urlID = 0, now = 10000;
  function element(id) {
    if (elements.has(id)) return elements.get(id);
    const node = { id, value: '', checked: false, hidden: false, disabled: false, events: {}, children: [], textContent: '', classList: { toggle() {} },
      addEventListener(name, listener) { this.events[name] = listener; }, setAttribute() {}, removeAttribute(name) { delete this[name]; },
      appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; },
      replaceWith(next) { elements.set(this.id, next); }, getBoundingClientRect() { return { left: 100, top: 0, width: 800, height: 600 }; }
    };
    elements.set(id, node); return node;
  }
  const document = { getElementById: element, createElement() { return {}; }, addEventListener() {} };
  const storage = new Map();
  const sessionStorage = { getItem: k => storage.get(k), setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) };
  const status = { protocol: 2, permission: true, capturing: true, inputEnabled: true, width: 1400, height: 900, fps: 60, maxWidth: 1240, grayscale: false, displayID: 1, capture_session: 'session-1' };
  const window = { document, crypto: require('node:crypto').webcrypto, location: { hash: '', pathname: '/', search: '' }, events: {}, addEventListener(name, callback) { this.events[name] = callback; } };
  const fetch = async (path, options) => {
    calls.push({ path, options });
    if (intercept) { const response = await intercept(path, options, status); if (response !== undefined) return response; }
    if (path.startsWith('/api/frame')) return { ok: true, status: 200, blob: async () => 'jpeg', headers: { get: key => key === 'X-Frame-ID' ? '42' : key === 'X-Capture-Session' ? status.capture_session : null } };
    return { ok: true, status: 200, json: async () => path === '/api/displays' ? { displays: [{ id: 1, name: 'Mac', width: 1400, height: 900 }] } : { ...status } };
  };
  function Image() { Object.assign(this, element('image-' + images.length)); images.push(this); }
  const context = { window, document, sessionStorage, history: { replaceState() {} }, URLSearchParams, Number, Date: { now: () => now }, AbortController, Image, fetch,
    URL: { createObjectURL: () => 'blob:' + (++urlID), revokeObjectURL: url => revoked.push(url) },
    setTimeout: (callback, ms) => { timers.set(++timerID, { callback, ms }); return timerID; }, clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(fs.readFileSync(require.resolve('./app.js'), 'utf8'), context);
  element('token').value = 'abc'; element('fps').value = '60'; element('maxWidth').value = '1240'; element('grayscale').checked = false;
  const flush = () => new Promise(resolve => setImmediate(resolve));
  return { element, images, timers, calls, revoked, storage, flush, window, advance(ms) { now += ms; }, async tick(elapsed = 2500) { now += elapsed; const entry = [...timers.entries()].find(([, value]) => value.ms < 8000); assert.ok(entry, 'a poll is scheduled'); timers.delete(entry[0]); entry[1].callback(); await flush(); }, async connect() { await element('pairForm').events.submit({ preventDefault() {} }); await flush(); } };
}

test('only one frame is requested while decoding, and disconnect invalidates pending decode', async () => {
  const h = browserHarness();
  await h.connect();
  assert.equal(h.calls.filter(c => c.path.startsWith('/api/frame')).length, 1);
  assert.equal(h.images.length, 1);
  assert.equal([...h.timers.values()].filter(t => t.ms < 1000).length, 0, 'next frame must wait for decode');
  const lateLoad = h.images[0].onload;
  h.element('disconnect').events.click();
  lateLoad();
  await h.flush();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.storage.has('booxToken'), false);
  assert.deepEqual(h.revoked, ['blob:1']);
  assert.equal(h.timers.size, 0);
});

test('a settings change invalidates an older pending decoded frame', async () => {
  const h = browserHarness();
  await h.connect();
  await h.element('grayscale').events.change({ target: { id: 'grayscale', checked: false } });
  h.images[0].onload();
  await h.flush();
  assert.equal(h.element('frame').hidden, true, 'obsolete image must not replace the current frame');
  assert.deepEqual(h.revoked, ['blob:1']);
  assert.equal([...h.timers.values()].filter(t => t.ms < 1000).length, 1, 'polling resumes after discarded decode');
});

test('a decoded current frame renders and API token stays out of URLs', async () => {
  const h = browserHarness();
  await h.connect();
  h.images[0].onload();
  await h.flush();
  assert.equal(h.element('frame'), h.images[0]);
  assert.equal(h.element('placeholder').hidden, true);
  assert.ok(h.calls.every(c => c.options.headers.Authorization === 'Bearer abc'));
  assert.ok(h.calls.every(c => !c.path.includes('abc')));
  assert.equal(h.element('scrollUp').disabled, false, 'Mac approval enables input once a current frame renders');
});

test('a failed initial connection retries setup and shows the locally selected display', async () => {
  let first = true;
  const h = browserHarness(path => {
    if (path === '/api/status' && first) { first = false; throw new Error('USB not yet ready'); }
  });
  await h.connect();
  assert.equal(h.element('connection').textContent, 'Connection interrupted');
  assert.equal(h.calls.filter(c => c.path === '/api/displays').length, 0);
  await h.tick();
  assert.equal(h.calls.filter(c => c.path === '/api/displays').length, 1);
  assert.equal(h.element('display').textContent, 'Mac · 1400 × 900');
  assert.equal(h.element('display').events.change, undefined);
  assert.equal(h.element('maxWidth').value, '1240');
  assert.equal(h.element('pairPanel').hidden, true);
  assert.equal(h.images.length, 1);
});

test('protocol is checked after a failed first connection and unsupported hosts stop', async () => {
  let first = true;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status') {
      if (first) { first = false; throw new Error('not ready'); }
      return { ok: true, status: 200, json: async () => ({ ...status, protocol: 99 }) };
    }
  });
  await h.connect(); await h.tick();
  assert.match(h.element('notice').textContent, /unsupported protocol/);
  assert.equal(h.element('connect').disabled, false);
  assert.equal(h.images.length, 0);
  assert.equal(h.timers.size, 0);
});

test('a status response begun before settings cannot revert settings or dimensions', async () => {
  let deferStatus = false, resolveStatus;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && deferStatus) {
      const snapshot = { ...status };
      return new Promise(resolve => { resolveStatus = () => resolve({ ok: true, status: 200, json: async () => snapshot }); });
    }
    if (path === '/api/settings') Object.assign(status, JSON.parse(options.body));
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  deferStatus = true; await h.tick();
  assert.equal(typeof resolveStatus, 'function');
  await h.element('fps').events.change({ target: { id: 'fps', value: '8' } });
  assert.equal(h.element('fps').value, '8');
  resolveStatus(); await h.flush();
  assert.equal(h.element('fps').value, '8', 'late status must not restore the old FPS');
});


test('connection adopts Sharp text host settings without posting browser defaults', async () => {
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status') Object.assign(status, { fps: 8, maxWidth: 2480, grayscale: true, jpegQuality: 0.88 });
  });
  assert.equal(h.element('fps').disabled, true);
  await h.connect();
  assert.equal(h.calls.filter(call => call.path === '/api/settings').length, 0);
  assert.equal(h.element('fps').value, '8');
  assert.equal(h.element('maxWidth').value, '2480');
  assert.equal(h.element('grayscale').checked, true);
  assert.equal(h.element('fps').disabled, false);
  await h.element('fps').events.change({ target: { id: 'fps', value: '15' } });
  const settings = h.calls.filter(call => call.path === '/api/settings');
  assert.equal(settings.length, 1);
  assert.deepEqual(JSON.parse(settings[0].options.body), { fps: 15 });
  h.element('disconnect').events.click();
  assert.equal(h.element('fps').disabled, true);
  h.element('token').value = 'abc';
  await h.connect();
  assert.equal(h.calls.filter(call => call.path === '/api/settings').length, 1, 'reconnect must not post settings');
});


test('display selection is read-only and never sent in remote settings', async () => {
  const h = browserHarness();
  await h.connect();
  assert.equal(h.element('display').textContent, 'Mac · 1400 × 900');
  assert.equal(h.element('display').events.change, undefined);
  const count = h.calls.length;
  await h.element('fps').events.change({ target: { id: 'display', value: '2' } });
  assert.equal(h.calls.length, count, 'unsupported settings events must not send requests');
  await h.element('fps').events.change({ target: { id: 'fps', value: '15' } });
  assert.ok(h.calls.filter(call => call.path === '/api/settings').every(call => !Object.hasOwn(JSON.parse(call.options.body), 'displayID')));
  const html = fs.readFileSync(require.resolve('./index.html'), 'utf8');
  assert.match(html, /<output id="display">/);
  assert.doesNotMatch(html, /<select[^>]+id="display"/);
});

test('local source changes update the read-only display label', async () => {
  let changed = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && changed) status.displayID = 2;
    if (path === '/api/displays' && changed) return { ok: true, status: 200, json: async () => ({ displays: [{ id: 2, name: 'New display', width: 2480, height: 1860 }] }) };
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  changed = true;
  await h.tick();
  assert.equal(h.element('display').textContent, 'New display · 2480 × 1860');
  h.element('disconnect').events.click();
  assert.equal(h.element('display').textContent, 'Waiting for Mac');
});

test('late display metadata cannot restore a disconnected display label', async () => {
  let deferDisplays = false, resolveDisplays;
  const h = browserHarness(path => {
    if (path === '/api/displays' && deferDisplays) return new Promise(resolve => {
      resolveDisplays = () => resolve({ ok: true, status: 200, json: async () => ({ displays: [{ id: 1, name: 'Late display', width: 1, height: 1 }] }) });
    });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  deferDisplays = true;
  await h.tick();
  h.element('disconnect').events.click();
  resolveDisplays(); await h.flush();
  assert.equal(h.element('display').textContent, 'Waiting for Mac');
  assert.equal(h.element('frame').hidden, true);
});

test('capture stop clears content before a delayed display refresh completes', async () => {
  let stopped = false, resolveDisplays;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && stopped) { status.capturing = false; status.capture_session = ''; }
    if (path === '/api/displays' && stopped) return new Promise(resolve => {
      resolveDisplays = () => resolve({ ok: true, status: 200, json: async () => ({ displays: [] }) });
    });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  stopped = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('scrollUp').disabled, true);
  resolveDisplays(); await h.flush();
  assert.equal(h.element('display').textContent, 'Display 1 · selected on Mac');
});

test('a capture session change waits for its own frame before enabling approved input', async () => {
  let switched = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && switched) status.capture_session = 'session-2';
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  switched = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('frame').src, undefined);
  assert.ok(h.revoked.includes('blob:1'));
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.images.length, 2, 'a frame from the new capture may decode');
  h.images[1].onload(); await h.flush();
  assert.equal(h.element('frame'), h.images[1]);
});

test('frames from a different capture session never enter decoding', async () => {
  const h = browserHarness(path => {
    if (path.startsWith('/api/frame')) return {
      ok: true, status: 200, blob: async () => 'old-jpeg',
      headers: { get: key => key === 'X-Frame-ID' ? '42' : key === 'X-Capture-Session' ? 'obsolete-session' : null }
    };
  });
  await h.connect();
  assert.equal(h.images.length, 0);
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.element('placeholder').hidden, false);
});

test('a pending settings change after a capture session mismatch is not a connection failure', async () => {
  let release;
  const h = browserHarness(path => {
    if (path.startsWith('/api/frame')) return {
      ok: true, status: 200, blob: async () => 'old-jpeg',
      headers: { get: key => key === 'X-Frame-ID' ? '42' : key === 'X-Capture-Session' ? 'obsolete-session' : null }
    };
    if (path === '/api/settings') return new Promise(resolve => { release = resolve; });
  });
  await h.connect();
  const change = h.element('fps').events.change({ target: { id: 'fps', value: '15' } });
  await h.tick();
  assert.equal(h.element('connection').textContent, 'Connected · live');
  assert.equal([...h.timers.values()].some(t => t.ms >= 1000 && t.ms < 8000), false, 'no failure backoff is scheduled');
  release(undefined); await change;
});

test('a session change cancels an in-progress decode and rejects its late callback', async () => {
  let switched = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/settings' && switched) status.capture_session = 'session-2';
  });
  await h.connect();
  const lateLoad = h.images[0].onload;
  switched = true;
  await h.element('fps').events.change({ target: { id: 'fps', value: '15' } });
  lateLoad(); await h.flush();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.images[0].src, undefined);
  assert.deepEqual(h.revoked, ['blob:1']);
  assert.equal(h.element('connection').textContent, 'Connected · live', 'obsolete decoding is not a transport error');
});

test('input carries the capture session that authorized the displayed source', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollDown').events.click(); await h.flush();
  const call = h.calls.find(call => call.path === '/api/input');
  assert.deepEqual(JSON.parse(call.options.body), { type: 'scroll', deltaY: -300, capture_session: 'session-1' });
});

test('observed capture stop clears the last frame and disables input', async () => {
  let stopped = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && stopped) { status.capturing = false; status.capture_session = ''; }
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  stopped = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('frame').src, undefined);
  assert.ok(h.revoked.includes('blob:1'));
  assert.equal(h.element('scrollUp').disabled, true);
  const before = h.calls.length;
  h.element('scrollDown').events.click(); await h.flush();
  assert.equal(h.calls.length, before, 'stopped capture must not send input');
});

test('connection loss clears the displayed frame before retrying', async () => {
  let failed = false;
  const h = browserHarness(path => {
    if (path === '/api/status' && failed) throw new Error('connection lost');
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  failed = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('frame').src, undefined);
  assert.ok(h.revoked.includes('blob:1'));
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.element('connection').textContent, 'Connection interrupted');
});

test('permission loss clears frames and prevents input even if capture still reports active', async () => {
  let denied = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && denied) status.permission = false;
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  denied = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('scrollUp').disabled, true);
  assert.ok(h.revoked.includes('blob:1'));
});

test('input stays ordered and responsive while frame decoding is stalled', async () => {
  let finishInput;
  const h = browserHarness(path => {
    if (path === '/api/input' && !finishInput) return new Promise(resolve => { finishInput = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  await h.tick(10);
  assert.equal(h.images.length, 2);
  const tap = x => h.element('viewport').events.click({ target: h.element('frame'), clientX: x, clientY: 100 });
  tap(200); tap(300); tap(400);
  await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
  finishInput({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.x), [0.125, 0.25, 0.375]);
  assert.equal(typeof h.images[1].onload, 'function');
});

test('scroll accumulation preserves distance, direction changes, and tap barriers', async () => {
  let finishInput;
  const h = browserHarness(path => {
    if (path === '/api/input' && !finishInput) return new Promise(resolve => { finishInput = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollUp').events.click();
  for (let i = 0; i < 5; i++) h.element('scrollUp').events.click();
  h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 100 });
  h.element('scrollDown').events.click(); h.element('scrollUp').events.click();
  finishInput({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.type === 'tap' ? 'tap' : event.deltaY), [300, 1000, 500, 'tap', -300, 300]);
});

test('Mac input revocation aborts pending input and drops queued clicks without replay', async () => {
  let finishInput, denied = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/input') return new Promise(resolve => { finishInput = resolve; });
    if (path === '/api/status' && denied) status.inputEnabled = false;
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollUp').events.click(); h.element('scrollDown').events.click();
  const call = h.calls.find(call => call.path === '/api/input');
  denied = true; await h.tick();
  assert.equal(call.options.signal.aborted, true);
  finishInput({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
});

test('input overload and expiry visibly pause control', async () => {
  for (const overload of [true, false]) {
    let finishInput;
    const h = browserHarness(path => {
      if (path === '/api/input') return new Promise(resolve => { finishInput = resolve; });
    });
    await h.connect(); h.images[0].onload(); await h.flush();
    const tap = () => h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 100 });
    tap();
    if (overload) { for (let i = 0; i < 65; i++) tap(); }
    else { tap(); h.advance(2000); finishInput({ ok: true, json: async () => ({ ok: true }) }); await h.flush(); }
    assert.equal(h.element('scrollUp').disabled, true);
    assert.match(h.element('notice').textContent, /Remote input paused/);
    assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
  }
});

test('uncertain input delivery pauses without retrying the click', async () => {
  const h = browserHarness(path => { if (path === '/api/input') throw new Error('Lost reply'); });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollUp').events.click(); h.element('scrollDown').events.click(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, true);
  assert.match(h.element('notice').textContent, /could not be confirmed/);
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
});

test('double click sends two ordered click pairs with explicit counts', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  for (const detail of [1, 2]) h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 100, detail });
  await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.clickCount), [1, 2]);
  assert.equal(h.element('viewport').events.dblclick, undefined);
});

function pointer(h, name, x, y, extra = {}) {
  h.element('viewport').events[name]({ target: h.element('frame'), pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y, preventDefault() {}, ...extra });
}

test('two-finger scroll sends anchored movement before release without a compatibility click', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointerdown', 240, 100, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointermove', 200, 120);
  pointer(h, 'pointermove', 240, 120, { pointerId: 2, isPrimary: false }); await h.flush();
  let sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.equal(sent.reduce((sum, event) => sum + event.deltaY, 0), 20);
  pointer(h, 'pointermove', 200, 126);
  pointer(h, 'pointermove', 240, 126, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointerup', 200, 126);
  pointer(h, 'pointerup', 240, 126, { pointerId: 2, isPrimary: false });
  h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 126 });
  await h.flush();
  sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.ok(sent.every(event => event.type === 'scroll'));
  assert.ok(sent.every(event => event.x === 0.15 && event.y === 1 / 6));
  assert.equal(sent.reduce((sum, event) => sum + event.deltaY, 0), 26);
});

test('touch double tap is immediate and does not duplicate synthesized clicks', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100); pointer(h, 'pointerup', 200, 100); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
  h.advance(100);
  pointer(h, 'pointerdown', 201, 101); pointer(h, 'pointerup', 201, 101);
  h.element('viewport').events.click({ target: h.element('frame'), clientX: 201, clientY: 101 }); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.clickCount), [1, 2]);
});

test('wheel scroll preserves fractional deltas and ignores letterboxes', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  const wheel = (x, delta, mode = 0) => h.element('viewport').events.wheel({ target: h.element('frame'), clientX: x, clientY: 100, deltaY: delta, deltaMode: mode, preventDefault() {} });
  wheel(50, 100); wheel(200, 0.5); wheel(200, 0.5); wheel(200, 2, 1); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.equal(sent.reduce((sum, event) => sum + event.deltaY, 0), -33);
});

test('resize and multitouch cancel touch input and double-tap ownership', async () => {
  for (const cancel of ['resize', 'multitouch']) {
    const h = browserHarness();
    await h.connect(); h.images[0].onload(); await h.flush();
      pointer(h, 'pointerdown', 200, 100);
    if (cancel === 'resize') h.window.events.resize();
    else pointer(h, 'pointerdown', 250, 100, { pointerId: 2, isPrimary: false });
    h.advance(1000);
    pointer(h, 'pointerup', 200, 100);
    if (cancel === 'multitouch') pointer(h, 'pointerup', 250, 100, { pointerId: 2, isPrimary: false });
    h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 100 }); await h.flush();
    assert.equal(h.calls.filter(call => call.path === '/api/input').length, 0);
    pointer(h, 'pointerdown', 200, 100); pointer(h, 'pointerup', 200, 100); await h.flush();
    const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
    assert.deepEqual(sent.map(event => event.clickCount), [1]);
  }
});

test('mouse clicks and double clicks survive frame element replacement', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  const captures = [];
  h.element('viewport').setPointerCapture = id => captures.push(id);
  pointer(h, 'pointerdown', 200, 100, { pointerType: 'mouse', button: 0 });
  await h.tick(10); h.images[1].onload(); await h.flush();
  pointer(h, 'pointerup', 200, 100, { pointerType: 'mouse', target: h.element('viewport') });
  h.element('viewport').events.click({ target: h.element('viewport'), clientX: 200, clientY: 100, detail: 1 });
  await h.flush();
  await h.tick(10); h.images[2].onload(); await h.flush();
  pointer(h, 'pointerdown', 201, 101, { pointerType: 'mouse', button: 0 });
  pointer(h, 'pointerup', 201, 101, { pointerType: 'mouse', target: h.element('viewport') });
  h.element('viewport').events.click({ target: h.element('viewport'), clientX: 201, clientY: 101, detail: 1 });
  await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(captures, [1, 1]);
  assert.deepEqual(sent.map(event => event.clickCount), [1, 2]);
});

test('Mac approval is the only input opt-in and resume cannot bypass it', async () => {
  let enabled = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status') status.inputEnabled = enabled;
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.element('inputStatus').textContent, 'Enable remote input on the Mac');
  assert.equal(h.element('resumeInput').hidden, true);
  h.element('resumeInput').events.click();
  h.element('scrollUp').events.click(); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 0);
  enabled = true; await h.tick(); h.images[1].onload(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, false);
  h.element('scrollUp').events.click(); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
  const html = fs.readFileSync(require.resolve('./index.html'), 'utf8');
  assert.doesNotMatch(html, /id="control"/);
  assert.match(html, /<output id="inputStatus">/);
});

test('uncertain input stays paused across status refresh until explicit resume', async () => {
  let fail = true;
  const h = browserHarness(path => {
    if (path === '/api/input' && fail) { fail = false; throw new Error('Lost reply'); }
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollUp').events.click(); await h.flush();
  assert.equal(h.element('resumeInput').hidden, false);
  await h.tick(); h.images[1].onload(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.element('resumeInput').disabled, false);
  h.element('resumeInput').events.click();
  assert.equal(h.element('resumeInput').hidden, true);
  h.element('scrollDown').events.click(); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.deltaY), [300, -300]);
});

test('safety pause follows a capture across reconnect and clears for a new capture', async () => {
  let capture = 'session-1';
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status') status.capture_session = capture;
    if (path === '/api/input') throw new Error('Lost reply');
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('scrollUp').events.click(); await h.flush();
  h.element('disconnect').events.click(); h.element('token').value = 'abc';
  await h.connect(); h.images[1].onload(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, true);
  assert.equal(h.element('resumeInput').hidden, false);
  capture = 'session-2';
  await h.tick();
  assert.equal(h.element('scrollUp').disabled, true, 'new capture still needs its own rendered frame');
  h.images[2].onload(); await h.flush();
  assert.equal(h.element('scrollUp').disabled, false);
  assert.equal(h.element('resumeInput').hidden, true);
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1, 'no failed event is replayed');
});

test('touch long press sends one right click while held without a left click or context-menu duplicate', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  const [id, timer] = [...h.timers.entries()].find(([, entry]) => entry.ms === 500);
  h.advance(500); h.timers.delete(id); timer.callback(); await h.flush();
  let sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent, [{ type: 'rightClick', x: 0.125, y: 1 / 6, capture_session: 'session-1' }]);
  pointer(h, 'pointerup', 200, 100);
  h.element('viewport').events.contextmenu({ clientX: 200, clientY: 100, preventDefault() {} });
  h.element('viewport').events.click({ target: h.element('frame'), clientX: 200, clientY: 100 });
  await h.flush();
  sent = h.calls.filter(call => call.path === '/api/input');
  assert.equal(sent.length, 1);
});

test('long press release fallback works when its timer is delayed', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  h.advance(600);
  pointer(h, 'pointerup', 200, 100); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.type), ['rightClick']);
});

test('movement, geometry changes, and Mac revocation cancel a pending long press', async () => {
  for (const reason of ['move', 'resize', 'revoked']) {
    let denied = false;
    const h = browserHarness((path, options, status) => {
      if (path === '/api/status' && denied) status.inputEnabled = false;
    });
    await h.connect(); h.images[0].onload(); await h.flush();
    pointer(h, 'pointerdown', 200, 100);
    const [, timer] = [...h.timers.entries()].find(([, entry]) => entry.ms === 500);
    if (reason === 'move') pointer(h, 'pointermove', 220, 100);
    if (reason === 'resize') h.window.events.resize();
    if (reason === 'revoked') { denied = true; await h.tick(); }
    h.advance(600); timer.callback();
    pointer(h, 'pointerup', 200, 100); await h.flush();
    const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
    assert.ok(sent.every(event => event.type !== 'rightClick' && event.type !== 'tap'));
  }
});

test('mouse context menu sends a right click only inside the shared image', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  const menu = x => h.element('viewport').events.contextmenu({ pointerType: 'mouse', clientX: x, clientY: 100, preventDefault() {} });
  menu(50); menu(200); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent, [{ type: 'rightClick', x: 0.125, y: 1 / 6, capture_session: 'session-1' }]);
});

test('recognized touch and mouse double clicks reuse the first click location', async () => {
  for (const kind of ['touch', 'mouse']) {
    const h = browserHarness();
    await h.connect(); h.images[0].onload(); await h.flush();
    pointer(h, 'pointerdown', 200, 100, { pointerType: kind });
    pointer(h, 'pointerup', 200, 100, { pointerType: kind }); await h.flush();
    h.advance(100);
    const shift = kind === 'touch' ? 20 : 3;
    pointer(h, 'pointerdown', 200 + shift, 100 + shift, { pointerType: kind });
    pointer(h, 'pointerup', 200 + shift, 100 + shift, { pointerType: kind }); await h.flush();
    let sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
    assert.deepEqual(sent.map(event => event.clickCount), [1, 2]);
    assert.deepEqual(sent.map(event => [event.x, event.y]), [[0.125, 1 / 6], [0.125, 1 / 6]]);
    h.advance(100);
    pointer(h, 'pointerdown', 200, 100, { pointerType: kind });
    pointer(h, 'pointerup', 200, 100, { pointerType: kind }); await h.flush();
    h.advance(100);
    pointer(h, 'pointerdown', 250, 150, { pointerType: kind });
    pointer(h, 'pointerup', 250, 150, { pointerType: kind }); await h.flush();
    sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
    assert.deepEqual(sent.map(event => event.clickCount), [1, 2, 1, 1]);
    assert.deepEqual([sent[3].x, sent[3].y], [0.1875, 0.25]);
  }
});

test('one-finger and mouse drags preserve boundaries and coalesce only pending moves', async () => {
  for (const kind of ['touch', 'mouse']) {
    let finishStart;
    const h = browserHarness((path, options) => {
      if (path === '/api/input' && JSON.parse(options.body).phase === 'start') return new Promise(resolve => { finishStart = resolve; });
    });
    await h.connect(); h.images[0].onload(); await h.flush();
    pointer(h, 'pointerdown', 200, 100, { pointerType: kind });
    pointer(h, 'pointermove', 220, 120, { pointerType: kind });
    pointer(h, 'pointermove', 300, 180, { pointerType: kind });
    pointer(h, 'pointermove', 400, 240, { pointerType: kind });
    pointer(h, 'pointerup', 400, 240, { pointerType: kind });
    h.element('viewport').events.click({ target: h.element('frame'), clientX: 400, clientY: 240 });
    await h.flush();
    assert.equal(h.calls.filter(call => call.path === '/api/input').length, 1);
    finishStart({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
    const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
    assert.deepEqual(sent.map(event => event.phase), ['start', 'move', 'end']);
    assert.ok(sent.every(event => event.type === 'drag' && event.capture_session === 'session-1' && event.drag_id === sent[0].drag_id));
    assert.match(sent[0].drag_id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
    assert.deepEqual(sent.map(event => [event.x, event.y]), [[0.125, 1 / 6], [0.375, 0.4], [0.375, 0.4]]);
  }
});

test('a second finger cancels drag before centroid-anchored scrolling', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 200, 140); await h.flush();
  pointer(h, 'pointerdown', 240, 140, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointermove', 200, 180);
  pointer(h, 'pointermove', 240, 180, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointerup', 200, 180);
  pointer(h, 'pointermove', 240, 220, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointerup', 240, 220, { pointerId: 2, isPrimary: false });
  await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.filter(event => event.type === 'drag').map(event => event.phase), ['start', 'move', 'cancel']);
  assert.ok(sent.findIndex(event => event.phase === 'cancel') < sent.findIndex(event => event.type === 'scroll'));
  const scrolling = sent.filter(event => event.type === 'scroll');
  assert.equal(scrolling.reduce((sum, event) => sum + event.deltaY, 0), 40);
  assert.ok(scrolling.every(event => event.x === 0.15 && event.y === 140 / 600));
  assert.ok(sent.every(event => event.type !== 'tap' && event.type !== 'rightClick'));
});

test('stationary drags renew their lease and stop heartbeats on release', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 220, 100); await h.flush();
  const [id, timer] = [...h.timers.entries()].find(([, value]) => value.ms === 500);
  h.timers.delete(id); h.advance(500); timer.callback(); await h.flush();
  let sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.phase), ['start', 'move', 'move']);
  assert.deepEqual([sent[1].x, sent[1].y], [sent[2].x, sent[2].y]);
  pointer(h, 'pointerup', 220, 100); await h.flush();
  assert.equal([...h.timers.values()].filter(value => value.ms === 500).length, 0);
  sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.equal(sent.at(-1).phase, 'end');
});

test('source change cancels dispatched drag with original authority and never replays pending moves', async () => {
  let finishStart, capture = 'session-1';
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status') status.capture_session = capture;
    if (path === '/api/input' && JSON.parse(options.body).phase === 'start') return new Promise(resolve => { finishStart = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 220, 100);
  pointer(h, 'pointermove', 240, 100);
  const start = h.calls.find(call => call.path === '/api/input');
  capture = 'session-2'; await h.tick();
  assert.equal(start.options.signal.aborted, true);
  finishStart({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  pointer(h, 'pointerup', 240, 100); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.phase), ['start', 'cancel']);
  assert.ok(sent.every(event => event.capture_session === 'session-1'));
  assert.equal(sent[1].drag_id, sent[0].drag_id);
});

test('drag queue expiry retains move age and sends cancellation instead of stale movement', async () => {
  let finishStart;
  const h = browserHarness((path, options) => {
    if (path === '/api/input' && JSON.parse(options.body).phase === 'start') return new Promise(resolve => { finishStart = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 220, 100);
  h.advance(1900);
  pointer(h, 'pointermove', 240, 100);
  h.advance(100);
  finishStart({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.phase), ['start', 'cancel']);
  assert.equal(h.element('resumeInput').hidden, false);
  assert.match(h.element('notice').textContent, /waited too long/);
});

test('wheel events at different targets never coalesce their anchors', async () => {
  let finishFirst;
  const h = browserHarness(path => {
    if (path === '/api/input' && !finishFirst) return new Promise(resolve => { finishFirst = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  const wheel = x => h.element('viewport').events.wheel({ target: h.element('frame'), clientX: x, clientY: 100, deltaY: 30, deltaMode: 0, preventDefault() {} });
  wheel(200); wheel(200); wheel(300);
  finishFirst({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => [event.x, event.y, event.deltaY]), [[0.125, 1 / 6, -30], [0.125, 1 / 6, -30], [0.25, 1 / 6, -30]]);
});

test('drag coordinates clamp to the image and letterbox starts stay ignored', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 50, 100);
  pointer(h, 'pointermove', 200, 100); pointer(h, 'pointerup', 200, 100); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, 0);
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 950, 650);
  pointer(h, 'pointerup', 950, 650); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.phase), ['start', 'move', 'end']);
  assert.deepEqual([sent.at(-1).x, sent.at(-1).y], [1, 1]);
});

test('drag overload pauses input and attempts cancellation without replaying discrete events', async () => {
  let finishStart;
  const h = browserHarness((path, options) => {
    if (path === '/api/input' && JSON.parse(options.body).phase === 'start') return new Promise(resolve => { finishStart = resolve; });
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointermove', 220, 100);
  for (let index = 0; index < 70; index++) h.element(index % 2 ? 'scrollUp' : 'scrollDown').events.click();
  await h.flush();
  assert.equal(h.element('resumeInput').hidden, false);
  finishStart({ ok: true, json: async () => ({ ok: true }) }); await h.flush();
  pointer(h, 'pointerup', 220, 100); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.deepEqual(sent.map(event => event.phase), ['start', 'cancel']);
});

test('a third touch stops scrolling and cannot turn remaining touches into taps or drags', async () => {
  const h = browserHarness();
  await h.connect(); h.images[0].onload(); await h.flush();
  pointer(h, 'pointerdown', 200, 100);
  pointer(h, 'pointerdown', 240, 100, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointermove', 200, 140); await h.flush();
  const before = h.calls.filter(call => call.path === '/api/input').length;
  pointer(h, 'pointerdown', 280, 100, { pointerId: 3, isPrimary: false });
  pointer(h, 'pointermove', 200, 180);
  pointer(h, 'pointerup', 200, 180);
  pointer(h, 'pointerup', 240, 100, { pointerId: 2, isPrimary: false });
  pointer(h, 'pointerup', 280, 100, { pointerId: 3, isPrimary: false }); await h.flush();
  assert.equal(h.calls.filter(call => call.path === '/api/input').length, before);
  pointer(h, 'pointerdown', 200, 100); pointer(h, 'pointerup', 200, 100); await h.flush();
  const sent = h.calls.filter(call => call.path === '/api/input').map(call => JSON.parse(call.options.body));
  assert.equal(sent.at(-1).type, 'tap');
  assert.equal(sent.at(-1).clickCount, 1);
});
