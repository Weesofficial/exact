// Failed loads leave the slot reusable; concurrent callers share the same promise.
export function loadOnce(cache, key, load, refused) {
  if (cache[key] != null) return cache[key];
  let loaded;
  try { loaded = load(); } catch (error) { loaded = Promise.reject(error); }
  const pending = Promise.resolve(loaded).catch(error => {
    if (cache[key] === pending) cache[key] = null;
    if (refused) return refused(error);
    throw error;
  });
  return cache[key] = pending;
}

// Short bounded backoff for transient network / 5xx errors while loading GPU modules and shaders.
export const RETRY_DELAYS = [250, 500, 1000];

export function markTransient(error) {
  if (error && typeof error === 'object') {
    if (error.transient === undefined) error.transient = true;
    return error;
  }
  return Object.assign(new Error(String(error)), { transient: true });
}

export function httpError(label, status) {
  return Object.assign(new Error(`${label}: HTTP ${status}`), { status });
}

export function isTransientLoadError(error) {
  if (!error || error.code === 'no-adapter' || error.transient === false) return false;
  if (typeof error.status === 'number') return error.status === 408 || error.status === 429 || error.status >= 500;
  return error.transient === true;
}

const MODULE_FETCH_ERROR = /failed to fetch dynamically imported module|error loading dynamically imported module|importing a module script failed|load failed|network|connection|fetch|module script/i;
export const isModuleFetchError = error => error instanceof TypeError && MODULE_FETCH_ERROR.test(error.message ?? '');

export async function classifyScriptError(url, error, signal, isLoadError = isModuleFetchError(error), probeTimeoutMs = 1500) {
  if (typeof error?.status === 'number' || error?.transient !== undefined) return error;
  if (!isLoadError) return error;
  if (typeof fetch !== 'function' || !/^https?:/i.test(String(url))) return markTransient(error);
  const ac = typeof AbortController === 'function' ? new AbortController() : null;
  const onAbort = () => ac?.abort(signal.reason);
  signal?.addEventListener('abort', onAbort, { once: true });
  const timer = ac && probeTimeoutMs > 0 ? setTimeout(() => ac.abort(), probeTimeoutMs) : null;
  try {
    const probeSignal = ac?.signal ?? signal;
    let res = await fetch(url, { method: 'HEAD', cache: 'no-store', signal: probeSignal });
    if (res.status === 405) {
      res = await fetch(url, { cache: 'no-store', signal: probeSignal });
      ac?.abort();
    }
    if (!res.ok) return httpError(String(url), res.status);
    return markTransient(error);
  } catch (probeErr) {
    if (signal?.aborted) throw signal.reason ?? probeErr;
    return markTransient(error);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  }
}

export const withTry = (url, attempt) => attempt > 0 ? `${url}${url.includes('?') ? '&' : '?'}try=${attempt}` : url;
export const nextTry = (url, counter, key) => withTry(url, counter[key] = (counter[key] ?? -1) + 1);

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason ?? new Error('aborted'));
    const onAbort = () => { clearTimeout(timer); reject(signal.reason ?? new Error('aborted')); };
    const timer = setTimeout(() => { signal?.removeEventListener('abort', onAbort); resolve(); }, ms);
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

export async function retryTransient(load, {
  delays = RETRY_DELAYS,
  shouldRetry = isTransientLoadError,
  wait = sleep,
  signal,
  canRetry,
} = {}) {
  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw signal.reason ?? new Error('aborted');
    try { return await load(attempt); }
    catch (error) {
      if (signal?.aborted || attempt >= delays.length || !shouldRetry(error) || (canRetry && !canRetry())) throw error;
      await wait(delays[attempt], signal);
      if (canRetry && !canRetry()) throw error;
    }
  }
}

export const fetchText = (url, label, options) => retryTransient(async () => {
  let response;
  try { response = await fetch(url, options?.signal ? { signal: options.signal } : undefined); }
  catch (error) { throw error instanceof TypeError ? markTransient(error) : error; }
  if (!response.ok) throw httpError(label, response.status);
  if (/\bhtml\b/i.test(response.headers.get('content-type') ?? '')) {
    throw markTransient(new Error(`${label}: unexpected HTML response`));
  }
  try { return await response.text(); }
  catch (error) { throw error instanceof TypeError ? markTransient(error) : error; }
}, options);

// Lazy `module_or_path` getter preserves zero-arg test stubs without issuing an extra fetch,
// while validating HTTP status and captive-portal HTML before handing the Response to wasm-bindgen
// so WebAssembly.instantiateStreaming runs on attempt 0.
export function initWasm(init, url, options) {
  return retryTransient(async () => {
    let fetched = false;
    const fetchWasm = async () => {
      fetched = true;
      let response;
      try { response = await fetch(url, options?.signal ? { signal: options.signal } : undefined); }
      catch (error) { throw error instanceof TypeError ? markTransient(error) : error; }
      if (!response.ok) throw httpError(url.pathname.split('/').pop() || 'wasm', response.status);
      if (/\bhtml\b/i.test(response.headers.get('content-type') ?? '')) {
        throw markTransient(new Error(`${url}: unexpected HTML response`));
      }
      return response;
    };
    try { return await init({ get module_or_path() { return fetchWasm(); } }); }
    catch (error) { throw fetched && error instanceof TypeError ? markTransient(error) : error; }
  }, options);
}

export function armOnline(slot, key, fn) {
  if (slot[key] || typeof addEventListener !== 'function') return;
  const listener = () => { slot[key] = null; fn(); };
  slot[key] = listener;
  addEventListener('online', listener, { once: true });
}

export function clearOnline(slot, key) {
  const listener = slot[key];
  if (!listener) return;
  slot[key] = null;
  if (typeof removeEventListener === 'function') removeEventListener('online', listener);
}

export function watchOnline() {
  let seen = false;
  const listener = () => { seen = true; };
  if (typeof addEventListener === 'function') addEventListener('online', listener, { once: true });
  return {
    seen: () => seen,
    stop() { if (typeof removeEventListener === 'function') removeEventListener('online', listener); },
  };
}
