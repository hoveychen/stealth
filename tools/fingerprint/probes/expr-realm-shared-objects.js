// Which objects reachable from the global are the *same object* in two realms.
//
// Chrome hands a same-origin iframe its own wrapper for every one of these,
// even where the state behind the wrapper is per-origin (`localStorage`) or
// per-page (`screen`). One shared object is a handle a page needs no cleverness
// to read: a patch applied in one realm shows up in the other, and for the
// EventTargets in the list a listener installed in one realm hears the other's
// events. Measured on the Cloudflare widget, which installs a recorder in ten
// realms and counted one `crypto.subtle.digest` call per realm because there was
// one `crypto.subtle`.
//
// `stable` guards the reading: a getter minting a fresh object per read would
// come back "distinct" across realms for a reason that is not per-realm identity
// at all, so a path is only trustworthy when it answers the same object twice
// within one realm.
//
// Needs a real origin, not the bare `about:blank` target: a child of an
// about:blank top level is cross-origin to it in this engine, and every read
// below comes back `SecurityError`. Serve an empty page over loopback and pass
// its url.
//
//   node tools/fingerprint/run-probe.mjs chrome     tools/fingerprint/probes/expr-realm-shared-objects.js http://127.0.0.1:9407/
//   node tools/fingerprint/run-probe.mjs lightpanda tools/fingerprint/probes/expr-realm-shared-objects.js http://127.0.0.1:9407/
(() => {
  const PATHS = [
    'screen',
    'screen.orientation',
    'visualViewport',
    'navigator',
    'navigator.connection',
    'navigator.storage',
    'navigator.permissions',
    'navigator.mediaDevices',
    'navigator.serviceWorker',
    'navigator.credentials',
    'navigator.geolocation',
    'navigator.clipboard',
    'navigator.locks',
    'navigator.plugins',
    'navigator.mimeTypes',
    'navigator.userAgentData',
    'crypto',
    'crypto.subtle',
    'localStorage',
    'sessionStorage',
    'indexedDB',
    'caches',
    'performance',
    'performance.timing',
    'performance.navigation',
    'history',
    'location',
    'navigation',
    'document',
    'document.documentElement',
    'customElements',
    'speechSynthesis',
    'styleMedia',
    'console',
  ];

  if (!document.documentElement) document.appendChild(document.createElement('html'));
  if (!document.body) document.documentElement.appendChild(document.createElement('body'));

  const f = document.createElement('iframe');
  document.body.appendChild(f);
  const w = f.contentWindow;

  const read = (root, path) => {
    try {
      let v = root;
      for (const key of path.split('.')) {
        if (v === null || v === undefined) return { kind: 'absent' };
        v = v[key];
      }
      if (v === null || v === undefined) return { kind: 'absent' };
      if (typeof v !== 'object' && typeof v !== 'function') return { kind: typeof v };
      return { kind: 'object', value: v };
    } catch (e) {
      return { kind: 'THREW ' + e.name };
    }
  };

  const out = {};
  let compared = 0;
  let shared = 0;
  let unstable = 0;
  let unreachable = 0;

  for (const path of PATHS) {
    const here = read(window, path);
    const there = read(w, path);
    if (here.kind !== 'object' || there.kind !== 'object') {
      out[path] = { status: 'unreachable', here: here.kind, there: there.kind };
      unreachable++;
      continue;
    }
    const stable = read(window, path).value === here.value;
    compared++;
    if (!stable) unstable++;
    const is_shared = here.value === there.value;
    if (is_shared) shared++;
    out[path] = {
      status: is_shared ? 'shared' : 'distinct',
      stable,
      tag: Object.prototype.toString.call(here.value),
    };
  }

  f.remove();
  return {
    summary: { paths: PATHS.length, compared, shared, unstable, unreachable },
    paths: out,
  };
})()
