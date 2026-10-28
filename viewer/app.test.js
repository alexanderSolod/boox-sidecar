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
      addEventListener(name, listener) { this.events[name] = listener; }, setAttribute() {}, removeAttribute() {},
      appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; },
      replaceWith(next) { elements.set(this.id, next); }, getBoundingClientRect() { return { left: 100, top: 0, width: 800, height: 600 }; }
    };
    elements.set(id, node); return node;
  }
  const document = { getElementById: element, createElement() { return {}; }, addEventListener() {} };
  const storage = new Map();
  const sessionStorage = { getItem: k => storage.get(k), setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) };
  const status = { protocol: 2, permission: true, capturing: true, inputEnabled: true, width: 1400, height: 900, fps: 60, maxWidth: 1240, grayscale: false, displayID: 1 };
  const window = { document, location: { hash: '', pathname: '/', search: '' }, addEventListener() {} };
  const fetch = async (path, options) => {
    calls.push({ path, options });
    if (intercept) { const response = await intercept(path, options, status); if (response !== undefined) return response; }
    if (path.startsWith('/api/frame')) return { ok: true, status: 200, blob: async () => 'jpeg', headers: { get: () => '42' } };
    return { ok: true, status: 200, json: async () => path === '/api/displays' ? { displays: [{ id: 1, name: 'Mac', width: 1400, height: 900 }] } : status };
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


test('connection requests full color at 60 FPS by default', async () => {
  const h = browserHarness();
  await h.connect();
  const settings = h.calls.find(call => call.path === '/api/settings');
  assert.deepEqual(JSON.parse(settings.options.body), { fps: 60, maxWidth: 1240, grayscale: false });
  assert.equal(h.element('fps').value, '60');
  assert.equal(h.element('grayscale').checked, false);
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
  });
  await h.connect(); h.images[0].onload(); await h.flush();
  changed = true;
  await h.tick();
  assert.equal(h.element('display').textContent, 'Display 2 · selected on Mac');
  h.element('disconnect').events.click();
  assert.equal(h.element('display').textContent, 'Waiting for Mac');
});
