// Transient fetch failures while loading the GPU module, its glue, its wasm, or its shaders
// retry with short bounded backoff, report exhausted glue failures loudly, and fetch shaders in parallel.
import { test, expect } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { cdpBrowser } from '../../../scripts/agent-launch.mjs';
import { bundleHostModule } from '../../web-js/glue.mjs';
import { fixture } from './surface.mjs';
import { glueDeclarations } from './glue-fixture.mjs';

const ROOT = resolve(import.meta.dir, '../../..');
const WEB = resolve(import.meta.dir, '..');
const WEB_JS = resolve(import.meta.dir, '../../web-js');
const BUNDLED_GPU_GLUE = await bundleHostModule(ROOT, 'gpu-glue.js');
// Minimal valid WebAssembly module (magic + version header) that instantiates cleanly.
const TINY_WASM = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
const CORRUPT_WASM = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0xff, 0xff, 0xff, 0xff]);

// Mirrors pinned wasm-bindgen 0.2.130's __wbg_init_once: unwraps plain `{ module_or_path }`,
// awaits a Response (or fetches a URL), throws a plain Error on `!response.ok`, and instantiates.
function stubGpuModule(shaders = ['a', 'b', 'c'], useWasm = false) {
  return `
    const records = new Map();
    export default async function init(arg) {
      ${useWasm ? `
      let module_or_path = arg;
      if (module_or_path !== undefined && Object.getPrototypeOf(module_or_path) === Object.prototype) {
        ({ module_or_path } = module_or_path);
      }
      if (typeof module_or_path === 'string' || module_or_path instanceof URL) module_or_path = fetch(module_or_path);
      const res = await module_or_path;
      if (res instanceof Response) {
        if (!res.ok) throw new Error('failed to fetch Wasm: ' + res.status);
        const bytes = await res.arrayBuffer();
        await WebAssembly.instantiate(bytes);
      }` : ''}
      return {};
    }
    export function gpu_load() {} export function gpu_unload() {}
    export function gpu_child_view() {} export function gpu_seekable() {} export function gpu_reduced_motion() {} export function gpu_period() {}
    export function gpu_shader_names() { return ${JSON.stringify(JSON.stringify(shaders))}; }
    export function gpu_shaders_clear() { globalThis.registeredShaders = []; }
    export function gpu_shader(name, text) { (globalThis.registeredShaders ??= []).push([name, text]); return true; }
    export function gpu_create() { globalThis.createdSurfaces = (globalThis.createdSurfaces ?? 0) + 1; return globalThis.createdSurfaces; }
    export function gpu_bind_at() { return true; } export function gpu_wants_input() { return false; }
    export function gpu_dirty() { return false; }
    export function gpu_render(id) { globalThis.rendered = (globalThis.rendered ?? 0) + 1; records.set(id, '{"presented":true}'); return 0; }
    export function gpu_flush() { return true; }
    export function gpu_published(id) { const r = records.get(id); records.delete(id); return r; }
    export function gpu_messages() {} export function gpu_lifecycle() {}
    export function gpu_assets() { return '{"requests":[],"retired":[]}'; }
    export function gpu_agent() { return '{"world":{"tick":0}}'; } export function gpu_error() { return ''; }
  `;
}

function gpuPageHtml() {
  return `<!doctype html><div id="exact-root"><div id="host"><canvas data-surface></canvas></div></div><script type="module">
    Object.defineProperty(navigator, 'gpu', { configurable: true, value: { requestAdapter: async () => ({ info: {} }) } });
    const host = document.getElementById('host');
    globalThis.exact = {
      views: new Map([[1, host]]), root: document.getElementById('exact-root'),
      now: () => 0, devAssets: null, generation: 0, pendingSurfaces: [{ id: 1, name: 'world', values: [], generation: 0 }],
      wasm: { exact_surface_record() {} }, writeIn: t => t, send() {},
    };
    await import('/gpu-glue.js');
    globalThis.settledPending = await exact.gpu.settled();
    globalThis.ready = true;
  </script>`;
}

test('transient ConnectionReset on shipped gpu-glue.js, gpu.js, gpu_bg.wasm, or shaders retries and reveals canvas with zero static helper fetches', async () => {
  const targets = ['/gpu-glue.js', '/gpu.js', '/gpu_bg.wasm', '/shaders/b.wgsl'];
  for (const target of targets) {
    const failedOnce = new Set(), seenPaths = new Set();
    const html = `<!doctype html><div id="exact-root"><div id="host"><canvas data-surface></canvas></div></div><script type="module">
      Object.defineProperty(navigator, 'gpu', { configurable: true, value: { requestAdapter: async () => ({ info: {} }) } });
      const { retryTransient, classifyScriptError, withTry } = await import('/load-once.js');
      const host = document.getElementById('host');
      globalThis.exact = {
        views: new Map([[1, host]]), root: document.getElementById('exact-root'),
        now: () => 0, devAssets: null, generation: 0, pendingSurfaces: [{ id: 1, name: 'world', values: [], generation: 0 }],
        wasm: { exact_surface_record() {} }, writeIn: t => t, send() {},
      };
      await retryTransient(async attempt => {
        const url = new URL(withTry('/gpu-glue.js', attempt), location.href).href;
        try { return await import(url); }
        catch (err) { throw await classifyScriptError(url, err); }
      });
      await exact.gpu.settled();
      globalThis.ready = true;
    </script>`;
    const server = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
      const path = new URL(req.url).pathname;
      seenPaths.add(path);
      if (path === '/') return new Response(html, { headers: { 'content-type': 'text/html' } });
      if (path === '/gpu-glue.js') return new Response(BUNDLED_GPU_GLUE, { headers: { 'content-type': 'text/javascript' } });
      if (path === '/gpu.js') return new Response(stubGpuModule(['a', 'b', 'c'], true), { headers: { 'content-type': 'text/javascript' } });
      if (path === '/gpu_bg.wasm') return new Response(TINY_WASM, { headers: { 'content-type': 'application/wasm' } });
      if (path.startsWith('/shaders/')) return new Response(`// ${path}`, { headers: { 'content-type': 'text/plain' } });
      if (path === '/favicon.ico') return new Response('', { status: 404 });
      return new Response(readFileSync(resolve(WEB, path.slice(1))), { headers: { 'content-type': 'text/javascript' } });
    } });
    try {
      const suite = await cdpBrowser(), { cdp } = suite;
      let listener;
      try {
        const { sessionId } = await suite.page();
        const call = (method, params = {}) => cdp.send(method, params, sessionId);
        cdp.listeners.push(listener = msg => {
          if (msg.sessionId !== sessionId || msg.method !== 'Fetch.requestPaused') return;
          const path = new URL(msg.params.request.url).pathname;
          if (path === target && !failedOnce.has(target)) {
            failedOnce.add(target);
            call('Fetch.failRequest', { requestId: msg.params.requestId, errorReason: 'ConnectionReset' });
          } else {
            call('Fetch.continueRequest', { requestId: msg.params.requestId });
          }
        });
        await call('Fetch.enable', { patterns: [{ urlPattern: '*' }] });
        const evaluate = async expression => {
          const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
          if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
          return r.result.value;
        };
        await call('Page.navigate', { url: `http://127.0.0.1:${server.port}/` });
        const deadline = Date.now() + 30000;
        while (!await evaluate('globalThis.ready === true')) {
          if (Date.now() > deadline) throw new Error(`timed out recovering from ${target}`);
          await Bun.sleep(50);
        }
        const state = await evaluate('({ created: globalThis.createdSurfaces, rendered: globalThis.rendered, shaders: globalThis.registeredShaders, visibility: document.querySelector("canvas").style.visibility, recovery: exact.gpu.recovery ?? null })');
        expect(failedOnce.has(target)).toBe(true);
        expect(seenPaths.has('/pace.js'), 'shipped gpu-glue.js must not fetch static sub-imports').toBe(false);
        expect(state.created, target).toBe(1);
        expect(state.rendered, target).toBeGreaterThan(0);
        expect(state.visibility, target).not.toBe('hidden');
        expect(state.shaders, target).toEqual([['a', '// /shaders/a.wgsl'], ['b', '// /shaders/b.wgsl'], ['c', '// /shaders/c.wgsl']]);
        expect(state.recovery, target).toBeNull();
      } finally {
        if (listener) cdp.listeners.splice(cdp.listeners.indexOf(listener), 1);
        await suite.close();
      }
    } finally { server.stop(true); }
  }
}, 120000);

test('parallel shaders, 503/captive-portal HTML retries, text/plain wasm, fast-fail 404/corrupt wasm, and recovery triggers', async () => {
  const html = gpuPageHtml();
  // 1. Parallel shaders + wasm 503 + captive portal 200 HTML on shader + text/plain wasm accepted.
  let wasm503 = 1, shaderCaptive = 1, inFlight = 0, maxInFlight = 0;
  let releaseShaders;
  const allArrived = new Promise(r => { releaseShaders = r; });
  const arrived = new Set();
  const server = Bun.serve({ port: 0, hostname: '127.0.0.1', async fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/') return new Response(html, { headers: { 'content-type': 'text/html' } });
    if (path === '/gpu.js') return new Response(stubGpuModule(['s1', 's2', 's3', 's4'], true), { headers: { 'content-type': 'text/javascript' } });
    if (path === '/gpu_bg.wasm') {
      if (wasm503-- > 0) return new Response('<html>503</html>', { status: 503, headers: { 'content-type': 'text/html' } });
      // Valid wasm served with text/plain must still succeed (wasm-bindgen supports fallback instantiation).
      return new Response(TINY_WASM, { headers: { 'content-type': 'text/plain' } });
    }
    if (path.startsWith('/shaders/')) {
      if (path === '/shaders/s2.wgsl' && shaderCaptive-- > 0) return new Response('<html>captive portal</html>', { status: 200, headers: { 'content-type': 'text/html' } });
      arrived.add(path);
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      if (arrived.size === 3 && shaderCaptive <= 0) releaseShaders();
      if (arrived.size < 4) await Promise.race([allArrived, Bun.sleep(1500)]);
      inFlight--;
      return new Response(`// ${path}`, { headers: { 'content-type': 'text/plain' } });
    }
    if (path === '/favicon.ico') return new Response('', { status: 404 });
    return new Response(readFileSync(resolve(WEB, path.slice(1))), { headers: { 'content-type': 'text/javascript' } });
  } });
  const suite = await cdpBrowser();
  try {
    const { sessionId } = await suite.page();
    const call = (method, params = {}) => suite.cdp.send(method, params, sessionId);
    const evaluate = async expression => {
      const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Page.navigate', { url: `http://127.0.0.1:${server.port}/` });
    const deadline = Date.now() + 30000;
    while (!await evaluate('globalThis.ready === true')) {
      if (Date.now() > deadline) throw new Error('timed out waiting for parallel shaders + 503/captive retry');
      await Bun.sleep(50);
    }
    expect(maxInFlight).toBeGreaterThanOrEqual(3);
    expect(await evaluate('globalThis.registeredShaders.map(([n]) => n)')).toEqual(['s1', 's2', 's3', 's4']);
    expect(await evaluate('globalThis.createdSurfaces')).toBe(1);
  } finally {
    await suite.close();
    server.stop(true);
  }

  // 2. Permanent failures (404 shader, 404 gpu.js, eval TypeError in gpu.js, corrupt 200 wasm) fail fast in 1 attempt
  // and abort sibling shader retries without leaving settled() pending.
  for (const kind of ['404-shader', '404-gpu', 'eval-typeerror', 'corrupt-wasm']) {
    let primaryGets = 0, siblingHits = 0;
    const srv = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
      const path = new URL(req.url).pathname;
      if (path === '/') return new Response(html, { headers: { 'content-type': 'text/html' } });
      if (path === '/gpu-glue.js') return new Response(BUNDLED_GPU_GLUE, { headers: { 'content-type': 'text/javascript' } });
      if (path === '/gpu.js') {
        if (kind === '404-gpu') { if (req.method === 'GET') primaryGets++; return new Response('not found', { status: 404 }); }
        if (kind === 'eval-typeerror') { if (req.method === 'GET') primaryGets++; return new Response("const x = null; x.boom(); export default () => {};", { headers: { 'content-type': 'text/javascript' } }); }
        return new Response(stubGpuModule(kind === '404-shader' ? ['missing', 'flaky'] : [], kind === 'corrupt-wasm'), { headers: { 'content-type': 'text/javascript' } });
      }
      if (path === '/gpu_bg.wasm') { primaryGets++; return new Response(CORRUPT_WASM, { headers: { 'content-type': 'application/wasm' } }); }
      if (path === '/shaders/missing.wgsl') { primaryGets++; return new Response('not found', { status: 404 }); }
      if (path === '/shaders/flaky.wgsl') { siblingHits++; return new Response('busy', { status: 503 }); }
      if (path === '/favicon.ico') return new Response('', { status: 404 });
      return new Response(readFileSync(resolve(WEB, path.slice(1))), { headers: { 'content-type': 'text/javascript' } });
    } });
    const br = await cdpBrowser();
    try {
      const { sessionId } = await br.page();
      const call = (method, params = {}) => br.cdp.send(method, params, sessionId);
      const evaluate = async expression => {
        const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
        if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
        return r.result.value;
      };
      await call('Page.navigate', { url: `http://127.0.0.1:${srv.port}/` });
      const deadline = Date.now() + 15000;
      while (!await evaluate('globalThis.ready === true')) {
        if (Date.now() > deadline) throw new Error(`timed out on ${kind}`);
        await Bun.sleep(50);
      }
      await Bun.sleep(350);
      expect(primaryGets, kind).toBe(1);
      if (kind === '404-shader') expect(siblingHits).toBe(1);
      expect(await evaluate('exact.gpu.recovery.status'), kind).toBe('no device');
      expect(await evaluate('globalThis.settledPending'), kind).toEqual([]);
    } finally {
      await br.close();
      srv.stop(true);
    }
  }

  // 3. Exhausted shader 503: initial boot stops after 4 tries (no double-boot on drain), settled() reports pending,
  // and either an existing surface update or 'online' recovers cleanly while reusing the cached gpu.js module.
  let failShader = true, shaderHits = 0, glueHits = 0;
  const serverExhaust = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/') return new Response(html, { headers: { 'content-type': 'text/html' } });
    if (path === '/gpu.js') { glueHits++; return new Response(stubGpuModule(['s1'], false), { headers: { 'content-type': 'text/javascript' } }); }
    if (path === '/shaders/s1.wgsl') {
      shaderHits++;
      return failShader ? new Response('busy', { status: 503 }) : new Response('// ok', { headers: { 'content-type': 'text/plain' } });
    }
    if (path === '/favicon.ico') return new Response('', { status: 404 });
    return new Response(readFileSync(resolve(WEB, path.slice(1))), { headers: { 'content-type': 'text/javascript' } });
  } });
  const suiteExhaust = await cdpBrowser();
  try {
    const { sessionId } = await suiteExhaust.page();
    const call = (method, params = {}) => suiteExhaust.cdp.send(method, params, sessionId);
    const evaluate = async expression => {
      const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Page.navigate', { url: `http://127.0.0.1:${serverExhaust.port}/` });
    const deadline = Date.now() + 15000;
    while (!await evaluate('globalThis.ready === true')) {
      if (Date.now() > deadline) throw new Error('timed out on exhausted shader 503 test');
      await Bun.sleep(50);
    }
    expect(shaderHits).toBe(4);
    expect(glueHits).toBe(1);
    expect(await evaluate('exact.gpu.recovery.status')).toBe('failed');
    expect(await evaluate('globalThis.settledPending.length')).toBeGreaterThan(0);
    failShader = false;
    // Updating the existing surface after exhaustion triggers retryBoot and renders without re-importing gpu.js.
    await evaluate('exact.gpu.surface(1, "world", [1]); exact.gpu.settled()');
    const recovered = await evaluate('({ created: globalThis.createdSurfaces, rendered: globalThis.rendered, recovery: exact.gpu.recovery ?? null })');
    expect(glueHits).toBe(1);
    expect(recovered.created).toBe(1);
    expect(recovered.rendered).toBeGreaterThan(0);
    expect(recovered.recovery).toBeNull();
  } finally {
    await suiteExhaust.close();
    serverExhaust.stop(true);
  }

  // 4. JS target pieces.js: exhausted gpu-glue.js failure logs console.error and recovers on online.
  let failGlue = true;
  const piecesHtml = `<!doctype html><div id="exact-root"></div><script type="module">
    Object.defineProperty(navigator, 'gpu', { configurable: true, value: { requestAdapter: async () => ({ info: {} }) } });
    const rt = await import('/rt.js');
    const host = document.createElement('div');
    const canvas = document.createElement('canvas');
    canvas.dataset.surface = '';
    host.append(canvas);
    document.getElementById('exact-root').append(host);
    rt.scope(() => rt.gs(host, 'world', () => []));
    globalThis.rt = rt;
    globalThis.ready = true;
  </script>`;
  const serverPieces = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/') return new Response(piecesHtml, { headers: { 'content-type': 'text/html' } });
    if (path === '/names.js') return new Response('export default [[], [], []]; export const types = [[], [], []]; export const sourceTypes = {};', { headers: { 'content-type': 'text/javascript' } });
    if (path === '/gpu-glue.js' && failGlue) return new Response('unavailable', { status: 503 });
    if (path === '/gpu.js') return new Response(stubGpuModule([], false), { headers: { 'content-type': 'text/javascript' } });
    if (path === '/favicon.ico') return new Response('', { status: 404 });
    const file = path.startsWith('/web/') ? resolve(WEB, path.slice(5))
      : existsSync(resolve(WEB_JS, path.slice(1))) ? resolve(WEB_JS, path.slice(1))
      : resolve(WEB, path.slice(1));
    return new Response(readFileSync(file), { headers: { 'content-type': 'text/javascript' } });
  } });
  const suitePieces = await cdpBrowser();
  const consoleErrors = [];
  let pListener;
  try {
    const { sessionId } = await suitePieces.page();
    const call = (method, params = {}) => suitePieces.cdp.send(method, params, sessionId);
    suitePieces.cdp.listeners.push(pListener = msg => {
      if (msg.sessionId === sessionId && msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') {
        consoleErrors.push(msg.params.args.map(a => a.value ?? a.description).join(' '));
      }
    });
    await call('Runtime.enable');
    const evaluate = async expression => {
      const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Page.navigate', { url: `http://127.0.0.1:${serverPieces.port}/` });
    const deadline = Date.now() + 30000;
    while (!consoleErrors.some(line => line.includes('exact gpu:'))) {
      if (Date.now() > deadline) throw new Error('expected console.error after exhausted glue retries; saw: ' + consoleErrors.join('\n'));
      await Bun.sleep(50);
    }
    expect(await evaluate('rt.journal.some(l => l.includes("gpu:"))')).toBe(true);
    failGlue = false;
    await evaluate('window.dispatchEvent(new Event("online"))');
    const recoverDeadline = Date.now() + 15000;
    while (!await evaluate('globalThis.createdSurfaces === 1 && globalThis.rendered > 0')) {
      if (Date.now() > recoverDeadline) throw new Error('surface did not recover and present on online event');
      await Bun.sleep(50);
    }
  } finally {
    if (pListener) suitePieces.cdp.listeners.splice(suitePieces.cdp.listeners.indexOf(pListener), 1);
    await suitePieces.close();
    serverPieces.stop(true);
  }
}, 120000);

test('a failing retryBoot serialized with swap never unloads the committed swap module, and surface updates during swap never start retryBoot', async () => {
  let rejectRetry, retryStarted;
  const started = new Promise(resolve => { retryStarted = resolve; });
  let loads = 0;
  const f = await fixture({
    gpuLoad() {
      loads++;
      if (loads === 1) throw Object.assign(new Error('transient'), { transient: true });
      retryStarted();
      return new Promise((_, reject) => { rejectRetry = () => reject(Object.assign(new Error('retry failed'), { transient: true })); });
    },
  });
  f.create(1);
  // Creating view 1 after transient initial failure started retryBoot; swap must wait and then commit cleanly.
  await started;
  const swapPromise = f.exact.gpu.swap(1);
  rejectRetry();
  await swapPromise;
  expect(f.order).not.toContain('next unload');
  expect(f.exact.gpu.agent(1, { op: 'state' }).world.tick).toBe(0);

  // Reverse direction: while swap is loading its candidate after a transient initial failure,
  // mounting/updating a surface must not launch a concurrent retryBoot.
  let releaseSwap, swapEntered;
  const swapWaiting = new Promise(resolve => { swapEntered = resolve; });
  let bootCalls = 0;
  const g = await fixture({
    gpuLoad() { bootCalls++; throw Object.assign(new Error('transient'), { transient: true }); },
    nextGpu: {
      async gpu_load() { swapEntered(); await new Promise(resolve => { releaseSwap = resolve; }); },
    },
  });
  const pendingSwap = g.exact.gpu.swap(1);
  await swapWaiting;
  g.create(1);
  expect(bootCalls).toBe(1);
  releaseSwap();
  await pendingSwap;
  expect(bootCalls).toBe(1);
  expect(g.exact.gpu.agent(1, { op: 'state' }).world.tick).toBe(0);

  // Failed dev swap while 'online' fires: the reconnect event must still launch retryBoot after swap fails.
  let failSwapRelease, swapInFlight;
  const swapReady = new Promise(resolve => { swapInFlight = resolve; });
  let hBoots = 0;
  const onlineListeners = [];
  const origAdd = globalThis.addEventListener, origRemove = globalThis.removeEventListener;
  globalThis.addEventListener = (type, fn) => { if (type === 'online') onlineListeners.push(fn); };
  globalThis.removeEventListener = (type, fn) => { const i = onlineListeners.indexOf(fn); if (i >= 0) onlineListeners.splice(i, 1); };
  try {
    const hDevErrors = [];
    const h = await fixture({
      pendingCount: 1,
      gpuLoad() { if (++hBoots === 1) throw Object.assign(new Error('transient'), { transient: true }); },
      nextGpu: { async gpu_load() { swapInFlight(); await new Promise((_, reject) => { failSwapRelease = () => reject(new Error('swap failed')); }); } },
    });
    h.exact.devError = (msg, key) => hDevErrors.push([key, msg]);
    expect(hBoots).toBe(1);
    expect(onlineListeners.length).toBe(1);
    const failedSwap = h.exact.gpu.swap(1);
    await swapReady;
    // Fire the one-shot online listener during swap, then fail the swap.
    const listener = onlineListeners.shift();
    listener();
    failSwapRelease();
    await expect(failedSwap).rejects.toThrow('swap failed');
    await h.exact.gpu.settled();
    expect(hBoots).toBe(2);
    expect(h.exact.gpu.agent(1, { op: 'state' }).world.tick).toBe(0);
    expect(hDevErrors.at(-1)).toEqual(['gpu', null]);

    // Teardown race: destroying the last canvas while retryBoot is in-flight must not arm 'online' on rejection.
    let rejectInflight, inflightStarted;
    const inflightReady = new Promise(resolve => { inflightStarted = resolve; });
    let tBoots = 0;
    const t = await fixture({
      gpuLoad() {
        if (++tBoots === 1) throw Object.assign(new Error('transient 1'), { transient: true });
        inflightStarted();
        return new Promise((_, reject) => { rejectInflight = () => reject(Object.assign(new Error('transient 2'), { transient: true })); });
      },
    });
    t.create(1);
    await inflightReady;
    t.destroy(1);
    rejectInflight();
    await t.exact.gpu.settled();
    expect(onlineListeners.length).toBe(0);

    // Transient failure followed by permanent failure must report both diagnostics (not suppress the terminal one).
    let dBoots = 0;
    const d = await fixture({
      pendingCount: 1,
      gpuLoad() {
        if (++dBoots === 1) throw Object.assign(new Error('transient outage'), { transient: true });
        throw Object.assign(new Error('no webgpu adapter'), { code: 'no-adapter' });
      },
    });
    expect(d.diagnostics.some(m => m.includes('transient outage'))).toBe(true);
    const retryOnline = onlineListeners.shift();
    retryOnline();
    await d.exact.gpu.settled();
    expect(d.exact.gpu.recovery.status).toBe('no device');
    expect(d.diagnostics.some(m => m.includes('no webgpu adapter'))).toBe(true);

    // Reconnect firing during the final failing boot attempt replays once and recovers without waiting for another event.
    let rBoots = 0;
    const r = await fixture({
      pendingCount: 1,
      gpuLoad() {
        if (++rBoots === 1) {
          for (const fn of onlineListeners.splice(0)) fn();
          throw Object.assign(new Error('final attempt transient'), { transient: true });
        }
      },
    });
    expect(rBoots).toBe(2);
    expect(r.exact.gpu.recovery).toBeUndefined();
    expect(r.exact.gpu.agent(1, { op: 'state' }).world.tick).toBe(0);
    expect(onlineListeners.length).toBe(0);
  } finally {
    globalThis.addEventListener = origAdd;
    globalThis.removeEventListener = origRemove;
  }
});

test('load-once helpers retry stream body-read TypeErrors after headers and pieces.js stays retryable after pre-paint unmount', async () => {
  const { fetchText, initWasm, classifyScriptError, isTransientLoadError } = await import('../load-once.js');
  // Stalled HEAD probe respects its deadline and treats an inconclusive probe as transient (never hangs).
  const origFetch0 = globalThis.fetch;
  globalThis.fetch = (_url, init) => new Promise((_, reject) => {
    init.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
  });
  try {
    const classified = await classifyScriptError('http://example.test/gpu.js', new TypeError('Failed to fetch dynamically imported module: http://example.test/gpu.js'), undefined, true, 30);
    expect(isTransientLoadError(classified)).toBe(true);
  } finally { globalThis.fetch = origFetch0; }
  // Body-read TypeError after 200 OK headers retries in fetchText.
  let textReads = 0;
  const origFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true, status: 200, headers: new Headers({ 'content-type': 'text/plain' }),
    async text() { if (++textReads === 1) throw new TypeError('body stream reset'); return '// ok'; },
  });
  try {
    expect(await fetchText('http://example.test/s.wgsl', 's.wgsl', { delays: [0, 0] })).toBe('// ok');
    expect(textReads).toBe(2);
  } finally { globalThis.fetch = origFetch; }

  // Wasm stream-read TypeError after 200 OK headers retries in initWasm.
  let wasmReads = 0;
  globalThis.fetch = async () => ({
    ok: true, status: 200, headers: new Headers({ 'content-type': 'application/wasm' }),
    async arrayBuffer() { if (++wasmReads === 1) throw new TypeError('wasm stream reset'); return TINY_WASM.buffer; },
  });
  try {
    await initWasm(async arg => {
      const res = await arg.module_or_path;
      await WebAssembly.instantiate(await res.arrayBuffer());
    }, new URL('http://example.test/gpu_bg.wasm'), { delays: [0, 0] });
    expect(wasmReads).toBe(2);
  } finally { globalThis.fetch = origFetch; }

  // JS target pieces.js: unmounting the only canvas before first paint must not strand loads.Gpu for a later canvas.
  const html = `<!doctype html><div id="exact-root"></div><script type="module">
    Object.defineProperty(navigator, 'gpu', { configurable: true, value: { requestAdapter: async () => ({ info: {} }) } });
    const rt = await import('/rt.js');
    const root = document.getElementById('exact-root');
    const mount = () => {
      const host = document.createElement('div');
      const canvas = document.createElement('canvas');
      canvas.dataset.surface = '';
      host.append(canvas); root.append(host);
      return { host, own: rt.scope(() => rt.gs(host, 'world', () => [])) };
    };
    const first = mount();
    // Unmount immediately before the two-frame paint wait resolves, then remount in the immediate microtask after RAF 2.
    rt.end(first.own); first.host.remove();
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => {
      Promise.resolve().then(() => { mount(); r(); });
    })));
    const deadline = performance.now() + 10000;
    while ((!globalThis.createdSurfaces || !globalThis.rendered) && performance.now() < deadline) await new Promise(r => setTimeout(r, 25));
    await globalThis.exact?.gpu?.settled?.();
    globalThis.ready = true;
  </script>`;
  const server = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/') return new Response(html, { headers: { 'content-type': 'text/html' } });
    if (path === '/names.js') return new Response('export default [[], [], []]; export const types = [[], [], []]; export const sourceTypes = {};', { headers: { 'content-type': 'text/javascript' } });
    if (path === '/gpu-glue.js') return new Response(BUNDLED_GPU_GLUE, { headers: { 'content-type': 'text/javascript' } });
    if (path === '/gpu.js') return new Response(stubGpuModule([], false), { headers: { 'content-type': 'text/javascript' } });
    if (path === '/favicon.ico') return new Response('', { status: 404 });
    const file = path.startsWith('/web/') ? resolve(WEB, path.slice(5))
      : existsSync(resolve(WEB_JS, path.slice(1))) ? resolve(WEB_JS, path.slice(1))
      : resolve(WEB, path.slice(1));
    return new Response(readFileSync(file), { headers: { 'content-type': 'text/javascript' } });
  } });
  const suite = await cdpBrowser();
  try {
    const { sessionId } = await suite.page();
    const call = (method, params = {}) => suite.cdp.send(method, params, sessionId);
    const evaluate = async expression => {
      const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Page.navigate', { url: `http://127.0.0.1:${server.port}/` });
    const deadline = Date.now() + 20000;
    while (!await evaluate('globalThis.ready === true')) {
      if (Date.now() > deadline) throw new Error('timed out waiting for remount after pre-paint unmount');
      await Bun.sleep(50);
    }
    expect(await evaluate('globalThis.createdSurfaces')).toBe(1);
    expect(await evaluate('globalThis.rendered')).toBeGreaterThan(0);
  } finally {
    await suite.close();
    server.stop(true);
  }

  // Verify pieces() waits for an active cold loads.Gpu and that a valid non-registering gpu-glue.js fails permanently instead of looping.
  let emptyGlueHits = 0;
  const emptyHtml = `<!doctype html><div id="exact-root"></div><script type="module">
    const rt = await import('/rt.js');
    const host = document.createElement('div');
    const canvas = document.createElement('canvas'); canvas.dataset.surface = '';
    host.append(canvas); document.getElementById('exact-root').append(host);
    rt.scope(() => rt.gs(host, 'world', () => []));
    await rt.pieces();
    globalThis.done = { permanent: !!globalThis.exact?.gpuFailedPermanent, gpu: !!globalThis.exact?.gpu };
  </script>`;
  const emptyServer = Bun.serve({ port: 0, hostname: '127.0.0.1', fetch(req) {
    const path = new URL(req.url).pathname;
    if (path === '/') return new Response(emptyHtml, { headers: { 'content-type': 'text/html' } });
    if (path === '/names.js') return new Response('export default [[], [], []]; export const types = [[], [], []]; export const sourceTypes = {};', { headers: { 'content-type': 'text/javascript' } });
    if (path === '/gpu-glue.js') { emptyGlueHits++; return new Response('export const noop = true;', { headers: { 'content-type': 'text/javascript' } }); }
    if (path === '/favicon.ico') return new Response('', { status: 404 });
    const file = path.startsWith('/web/') ? resolve(WEB, path.slice(5))
      : existsSync(resolve(WEB_JS, path.slice(1))) ? resolve(WEB_JS, path.slice(1))
      : resolve(WEB, path.slice(1));
    return new Response(readFileSync(file), { headers: { 'content-type': 'text/javascript' } });
  } });
  const emptySuite = await cdpBrowser();
  try {
    const { sessionId } = await emptySuite.page();
    const call = (method, params = {}) => emptySuite.cdp.send(method, params, sessionId);
    const evaluate = async expression => {
      const r = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };
    await call('Page.navigate', { url: `http://127.0.0.1:${emptyServer.port}/` });
    const deadline = Date.now() + 15000;
    while (!await evaluate('!!globalThis.done')) {
      if (Date.now() > deadline) throw new Error('timed out waiting for non-registering gpu-glue.js');
      await Bun.sleep(50);
    }
    await Bun.sleep(200);
    expect(emptyGlueHits).toBe(1);
    expect(await evaluate('globalThis.done')).toEqual({ permanent: true, gpu: false });
  } finally {
    await emptySuite.close();
    emptyServer.stop(true);
  }

  // Top-level wasm and JS agents report queued surfaces pending after transient exhaustion, and empty on permanent failure.
  const wasmSettle = (hostState) => new Function('globalThis', 'host', 'loadGpuIfNeeded',
    `${glueDeclarations(readFileSync(resolve(WEB, 'wasm/agent.js'), 'utf8'), ['settleGpu'])}; return settleGpu;`)(
    { exact: { generation: 0, pendingSurfaces: [{ id: 5, name: 'arena', generation: 0 }, { id: 6, name: 'old', generation: 1 }] } },
    hostState,
    () => {},
  );
  expect(await wasmSettle({ gpuLoading: Promise.resolve() })()).toEqual([{ name: 'GPU module arena', canvas: 5 }]);
  expect(await wasmSettle({ gpuLoading: Promise.resolve(), gpuFailedPermanent: true })()).toEqual([]);

  const jsAgentSrc = readFileSync(resolve(WEB_JS, 'agent.js'), 'utf8');
  const jsLine = jsAgentSrc.slice(jsAgentSrc.indexOf('const settleGpu ='), jsAgentSrc.indexOf('const gpuPendingReply ='));
  const jsSettle = (exactState) => new Function('exact', `${jsLine}; return settleGpu;`)(exactState);
  expect(await jsSettle({ generation: 0, pendingSurfaces: [{ id: 7, name: 'world', generation: 0 }] })()).toEqual([{ name: 'GPU module world', canvas: 7 }]);
  expect(await jsSettle({ generation: 0, gpuFailedPermanent: true, pendingSurfaces: [{ id: 7, name: 'world', generation: 0 }] })()).toEqual([]);
}, 60000);
