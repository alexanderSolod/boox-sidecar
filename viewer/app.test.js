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
  const window = { document, location: { hash: '', pathname: '/', search: '' }, addEventListener() {} };
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
  return { element, images, timers, calls, revoked, storage, flush, async tick(elapsed = 2500) { now += elapsed; const entry = [...timers.entries()].find(([, value]) => value.ms < 8000); assert.ok(entry, 'a poll is scheduled'); timers.delete(entry[0]); entry[1].callback(); await flush(); }, async connect() { await element('pairForm').events.submit({ preventDefault() {} }); await flush(); } };
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
  assert.equal(h.element('control').checked, false, 'host input opt-in alone must not enable viewer control');
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
  assert.equal(h.element('control').disabled, true);
  resolveDisplays(); await h.flush();
  assert.equal(h.element('display').textContent, 'Display 1 · selected on Mac');
});

test('a capture session change clears the displayed frame and requires fresh input opt-in', async () => {
  let switched = false;
  const h = browserHarness((path, options, status) => {
    if (path === '/api/status' && switched) status.capture_session = 'session-2';
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  h.element('control').checked = true;
  h.element('control').events.change();
  switched = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('frame').src, undefined);
  assert.ok(h.revoked.includes('blob:1'));
  assert.equal(h.element('control').checked, false);
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
  assert.equal(h.element('control').disabled, true);
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
  h.element('control').checked = true;
  h.element('control').events.change();
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
  h.element('control').checked = true;
  h.element('control').events.change();
  stopped = true;
  await h.tick();
  assert.equal(h.element('frame').hidden, true);
  assert.equal(h.element('frame').src, undefined);
  assert.ok(h.revoked.includes('blob:1'));
  assert.equal(h.element('control').disabled, true);
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
  assert.equal(h.element('control').disabled, true);
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
  assert.equal(h.element('control').disabled, true);
  assert.ok(h.revoked.includes('blob:1'));
});
