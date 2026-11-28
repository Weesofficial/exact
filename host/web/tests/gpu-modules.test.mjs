import { test } from 'bun:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { retryTransient, isTransientLoadError, classifyScriptError, httpError, nextTry, armOnline, clearOnline, watchOnline } from '../load-once.js';

test('the primary cannot shadow a module surface in development; production reports it', () => {
  const source = readFileSync(new URL('../gpu-glue.js', import.meta.url), 'utf8');
  const body = source.slice(source.indexOf('function checkSurfaceOwners('), source.indexOf('const publishers'));
  const errors = [], exact = { compat: { inputs: { gpuModules: { sky: ['sky'] } } } };
  const check = new Function('exact', 'stem', 'console', `${body}; return checkSurfaceOwners;`)(exact, 'gpu', { error: m => errors.push(m) });
  const module = { gpu_surfaces: () => '["clear","sky"]' };
  assert.throws(() => check(module), /primary and owned by module sky/);
  exact.compat.embedded = { trust: 'production' };
  check(module);
  assert.equal(errors.length, 1);
  module.gpu_surfaces = () => '["clear"]';
  check(module);
  assert.equal(errors.length, 1);
});

// The router (LLP 1009 D6) over recording stand-ins for gpu-glue.js
// instances: which artifact each call reaches, and what it joins.
async function fixture(pending = [], { loadImpl, registerOnLoad = true, retry = (fn, o) => retryTransient(fn, { ...o, delays: [0, 0, 0] }) } = {}) {
  const calls = [], frames = [], imported = [], errors = [];
  const devErrors = [];
  const exact = { compat: { inputs: { gpuModules: { world: ['world', 'arena'] } } }, generation: 0, pendingSurfaces: pending, devError: (msg, key) => devErrors.push([key, msg]) };
  const host = stem => ({
    surface(view, name, values) { calls.push([stem, 'surface', view, name, values]); },
    destroy(view) { calls.push([stem, 'destroy', view]); },
    settled: async (wakes = false) => [`${stem} pending:${wakes}`],
    wake() { calls.push([stem, 'wake']); },
    decorate(request, reply) { return { ...reply, world: [...(reply.world ?? []), stem] }; },
    clock: () => ({ pending: stem === 'gpu/world', settleAt: stem === 'gpu' ? 5 : 9, nextTickAt: stem === 'gpu' ? 3 : 2, reply: { world: [{ stem }] } }),
    deviceLost() { calls.push([stem, 'deviceLost']); },
    retier(tier) { calls.push([stem, 'retier', tier]); },
    syncPerformance() { calls.push([stem, 'syncPerformance']); },
    swap(version) { calls.push([stem, 'swap', version]); return { ms: 1, errors: [] }; },
    surfaceWork: async name => `${stem}:${name}`,
    handle: request => ({ stem, id: request.id }),
    wantsInput: () => true,
    placementHidden: () => stem === 'gpu/world',
  });
  const source = readFileSync(new URL('../gpu-modules.js', import.meta.url), 'utf8')
    .replace('import { retryTransient, isTransientLoadError, classifyScriptError, nextTry, armOnline, clearOnline, watchOnline } from "./load-once.js";', '')
    .replace('import(target)', 'load(stem)')
    .replaceAll('import.meta.url', '"file:///fixture/gpu-modules.js"');
  new Function('globalThis', 'requestAnimationFrame', 'load', 'console', 'retryTransient', 'isTransientLoadError', 'classifyScriptError', 'nextTry', 'armOnline', 'clearOnline', 'watchOnline', source)(
    { exact }, fn => frames.push(fn),
    async stem => { imported.push(stem); if (loadImpl) await loadImpl(stem); if (registerOnLoad) exact.gpu.register(stem, host(stem)); },
    { error: (...args) => errors.push(args) }, retry, isTransientLoadError, classifyScriptError, nextTry, armOnline, clearOnline, watchOnline);
  const paint = async () => { while (frames.length) frames.shift()(); await new Promise(r => setTimeout(r, 0)); };
  return { exact, gpu: exact.gpu, calls, imported, errors, devErrors, paint, frames };
}

test('each surface reaches the artifact that owns its name, loaded only when needed', async () => {
  const f = await fixture([{ id: 2, name: 'night', values: [true], generation: 0 }, { id: 3, name: 'stale', values: [], generation: 9 }]);
  await f.paint();
  assert.deepEqual(f.imported, ['gpu'], 'the queued canvases load their artifact at once; another generation is dropped');
  assert.deepEqual(f.calls, [['gpu', 'surface', 2, 'night', [true]]]);
  assert.deepEqual(f.exact.pendingSurfaces, []);
  f.gpu.surface(15, 'world', [7]);
  f.gpu.surface(15, 'world', [8]);
  assert.deepEqual(f.imported, ['gpu'], 'a module waits for a rendering opportunity');
  await f.paint();
  assert.deepEqual(f.imported, ['gpu', 'gpu/world']);
  assert.deepEqual(f.calls.at(-1), ['gpu/world', 'surface', 15, 'world', [8]], 'only the latest inputs replay');
  f.gpu.surface(15, 'night', [false]);
  assert.deepEqual(f.calls.slice(-2), [['gpu/world', 'destroy', 15], ['gpu', 'surface', 15, 'night', [false]]], 'a view that changes artifact leaves the old one');
  f.gpu.destroy(15);
  assert.deepEqual(f.calls.at(-1), ['gpu', 'destroy', 15]);
});

test('replies join across artifacts and process-wide signals reach every one', async () => {
  const f = await fixture();
  f.gpu.surface(2, 'night', []); f.gpu.surface(4, 'arena', []);
  await f.paint();
  assert.deepEqual(await f.gpu.settled(), ['gpu pending:false', 'gpu/world pending:false']);
  assert.deepEqual(await f.gpu.settled(true), ['gpu pending:true', 'gpu/world pending:true']);
  f.gpu.wake();
  assert.deepEqual(f.calls.filter(c => c[1] === 'wake').map(c => c[0]), ['gpu', 'gpu/world']);
  assert.deepEqual(f.gpu.decorate({ op: 'state' }, {}).world, ['gpu', 'gpu/world']);
  assert.deepEqual(f.gpu.clock(true), { pending: true, settleAt: 9, nextTickAt: 2, reply: { world: [{ stem: 'gpu' }, { stem: 'gpu/world' }] } });
  f.gpu.deviceLost();
  assert.deepEqual(f.calls.filter(c => c[1] === 'deviceLost').map(c => c[0]), ['gpu', 'gpu/world']);
  f.gpu.retier('low'); // LLP 1139.003 D2: `prefer gpu-tier` reaches every loaded artifact
  assert.deepEqual(f.calls.filter(c => c[1] === 'retier'), [['gpu', 'retier', 'low'], ['gpu/world', 'retier', 'low']]);
  f.gpu.syncPerformance();
  assert.deepEqual(f.calls.filter(c => c[1] === 'syncPerformance'), [['gpu', 'syncPerformance'], ['gpu/world', 'syncPerformance']]);
  f.gpu.swap(3, 'world'); f.gpu.swap(4);
  assert.deepEqual(f.calls.filter(c => c[1] === 'swap'), [['gpu/world', 'swap', 3], ['gpu', 'swap', 4]]);
  assert.deepEqual(f.gpu.handle({ id: 4 }), { stem: 'gpu/world', id: 4 });
  assert.equal(f.gpu.placementHidden({}), true);
  assert.equal(await f.gpu.surfaceWork('world', 'capture'), 'gpu/world:world');
  f.gpu.destroy(4);
  await assert.rejects(f.gpu.surfaceWork('world', 'capture'), /expected one live surface, found 0/);
  f.gpu.reset(true);
  assert.deepEqual(f.gpu.handle({ id: 2 }), { error: 'view 2 has no world' });
});

test('a transient artifact import failure retries and delivers queued surfaces; exhaustion stays retryable', async () => {
  let failWorld = 2;
  const f = await fixture([], {
    loadImpl: async stem => {
      if (stem === 'gpu/world' && failWorld-- > 0) throw new TypeError('Failed to fetch dynamically imported module');
    },
  });
  f.gpu.surface(4, 'world', [1]);
  await f.paint();
  await f.gpu.settled();
  assert.equal(f.imported.filter(s => s === 'gpu/world').length, 3);
  assert.deepEqual(f.calls, [['gpu/world', 'surface', 4, 'world', [1]]]);
  assert.equal(f.errors.length, 0);

  let failPrimary = 4;
  const g = await fixture([], {
    loadImpl: async stem => {
      if (stem === 'gpu' && failPrimary-- > 0) throw new TypeError('connection reset');
    },
  });
  g.gpu.surface(2, 'night', [7]);
  await g.paint();
  assert.deepEqual(await g.gpu.settled(), [{ name: 'GPU module night', canvas: 2 }], 'exhausted import reports queued canvas pending');
  assert.equal(g.imported.length, 4, 'initial attempt plus three retries');
  assert.equal(g.errors.length, 1);
  // A later surface retries cleanly instead of staying permanently wedged.
  g.gpu.surface(3, 'night', [8]);
  await g.paint();
  assert.deepEqual(await g.gpu.settled(), ['gpu pending:false']);
  assert.deepEqual(g.calls, [['gpu', 'surface', 2, 'night', [7]], ['gpu', 'surface', 3, 'night', [8]]]);
  assert.deepEqual(g.devErrors.at(-1), ['gpu', null], 'registration clears the per-artifact dev error');

  // Remounting in the microtask between empty-queue check and loading slot release must not strand the queue.
  const r = await fixture();
  r.gpu.surface(10, 'night', [1]);
  r.gpu.destroy(10);
  // Flush the two RAF callbacks synchronously, then queue a remount in the immediate microtask.
  r.frames.shift()();
  r.frames.shift()();
  Promise.resolve().then(() => r.gpu.surface(11, 'night', [2]));
  await new Promise(resolve => setTimeout(resolve, 20));
  await r.gpu.settled();
  assert.deepEqual(r.imported, ['gpu']);
  assert.deepEqual(r.calls, [['gpu', 'surface', 11, 'night', [2]]]);

  // Permanent failures (404 or evaluation TypeError) fail fast without retries, online re-arms, or wedged settled().
  const p = await fixture([], {
    loadImpl: async () => { throw new TypeError("Cannot read properties of undefined (reading 'x')"); },
  });
  p.gpu.surface(20, 'world', [1]);
  await p.paint();
  assert.deepEqual(await p.gpu.settled(), []);
  assert.equal(p.imported.length, 1, 'eval TypeError fails fast without retries');
  p.gpu.surface(21, 'world', [2]);
  await p.paint();
  assert.equal(p.imported.length, 1, 'permanent failure does not spin again on later mounts');
  assert.deepEqual(await p.gpu.settled(), []);

  const p404 = await fixture([], { loadImpl: async () => { throw httpError('gpu/world', 404); } });
  p404.gpu.surface(30, 'world', [1]);
  await p404.paint();
  assert.equal(p404.imported.length, 1, '404 fails fast without retries');
  assert.deepEqual(await p404.gpu.settled(), []);

  // A valid module that never calls register() fails permanently on attempt 0 instead of looping endlessly.
  const empty = await fixture([], { registerOnLoad: false });
  empty.gpu.surface(40, 'world', [1]);
  await empty.paint();
  assert.deepEqual(await empty.gpu.settled(), []);
  assert.equal(empty.imported.length, 1);

  // Reconnect firing during the final failing attempt replays once and delivers queued surfaces.
  const onlineListeners = [];
  const origAdd = globalThis.addEventListener, origRemove = globalThis.removeEventListener;
  globalThis.addEventListener = (type, fn) => { if (type === 'online') onlineListeners.push(fn); };
  globalThis.removeEventListener = (type, fn) => { const i = onlineListeners.indexOf(fn); if (i >= 0) onlineListeners.splice(i, 1); };
  try {
    let attempts = 0;
    const rc = await fixture([], {
      loadImpl: async () => {
        if (++attempts <= 4) {
          if (attempts === 4) for (const fn of onlineListeners.splice(0)) fn();
          throw new TypeError('connection reset');
        }
      },
    });
    rc.gpu.surface(50, 'night', [9]);
    await rc.paint();
    assert.deepEqual(await rc.gpu.settled(), ['gpu pending:false']);
    assert.equal(attempts, 5, 'reconnect during final attempt replays once and succeeds');
    assert.deepEqual(rc.calls, [['gpu', 'surface', 50, 'night', [9]]]);
    assert.equal(onlineListeners.length, 0);
  } finally {
    globalThis.addEventListener = origAdd;
    globalThis.removeEventListener = origRemove;
  }
});
