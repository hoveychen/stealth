// Exactly what the cf-scrapingcourse challenge was measured reading.
//
// The list is not a guess. `report-reads` (cf-knobs.mjs) puts a pass-through
// accessor on every candidate global and on every own property of
// Navigator/Screen/NavigatorUAData/VisualViewport/MediaQueryList and reports
// which names the challenge actually reached for. Two documents do the reading
// and they read different things:
//
//   * the challenge page reads twelve names;
//   * the Turnstile widget, cross-origin on challenges.cloudflare.com, reads
//     ninety -- and it is the widget that builds the ~90KB payload the two arms
//     disagree on. That document was invisible until the knob harness attached
//     at the browser level, so nothing measured before it had ever been inside
//     the collector.
//
// Both lists came back identical across runs. This probe reads their union so
// the values can be diffed between arms.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-cf-read-set.js --url https://example.com --headed-ua
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-cf-read-set.js --url https://example.com
//
// --url matters: about:blank is not a secure context and hides two dozen of
// these in Chrome only, which manufactures differences that are the harness's.
(() => {
  const out = {};
  const safe = (label, fn) => {
    try { out[label] = fn(); }
    catch (e) { out[label] = 'threw:' + (e && e.name) + ':' + (e && e.message); }
  };

  // A function is described by the three things a guard can cheaply read off
  // one: its name, its declared arity, and whether its source says native.
  const fnShape = (f) => typeof f !== 'function'
    ? 'not-a-function:' + typeof f
    : [f.name, f.length, /\[native code\]/.test(Function.prototype.toString.call(f)) ? 'native' : 'js'].join('/');

  // And an object by its brand plus how many names hang off it and its
  // prototype, because that is what a collector walks.
  const objShape = (o) => o === null ? 'null' : typeof o !== 'object'
    ? 'not-an-object:' + typeof o
    : [Object.prototype.toString.call(o),
      Object.getOwnPropertyNames(o).length,
      (() => { const p = Object.getPrototypeOf(o); return p ? Object.getOwnPropertyNames(p).length : 'no-proto'; })()].join('/');

  // The first thing a capability list records is whether the name is there at
  // all, so absence is reported before shape and never confused with it.
  const any = (v) => v === undefined ? 'absent'
    : v === null ? 'null'
      : typeof v === 'function' ? 'fn:' + fnShape(v)
        : typeof v === 'object' ? 'obj:' + objShape(v)
          : typeof v + ':' + String(v);

  // --- what the widget reads off window ------------------------------------
  const WIN = ['trustedTypes', 'crypto', 'performance', 'PerformanceObserver', 'localStorage',
    'speechSynthesis', 'ReadableStream', 'RTCPeerConnection', 'BroadcastChannel',
    'name', 'navigation', 'opener', 'origin', 'external', 'screen',
    'innerWidth', 'innerHeight', 'scrollX', 'scrollY', 'visualViewport',
    'screenX', 'screenY', 'outerWidth', 'outerHeight', 'devicePixelRatio',
    'styleMedia', 'onbeforeinstallprompt', 'isSecureContext', 'crossOriginIsolated',
    'scheduler', 'indexedDB', 'sessionStorage', 'cancelIdleCallback', 'matchMedia',
    'queueMicrotask', 'reportError', 'requestIdleCallback', 'structuredClone',
    'cookieStore', 'ondevicemotion', 'ondeviceorientation', 'caches',
    'documentPictureInPicture', 'sharedStorage', 'showDirectoryPicker',
    'showOpenFilePicker', 'launchQueue', 'Atomics', 'FinalizationRegistry', 'WeakRef',
    'webkitRTCPeerConnection', 'TransformStream', 'ResizeObserver', 'ReportingObserver',
    'OfflineAudioContext', 'MutationObserver', 'MediaSource', 'MediaRecorder',
    'IntersectionObserver', 'DecompressionStream', 'CompressionStream', 'AudioContext',
    'offscreenBuffering', 'AudioDecoder', 'DeviceMotionEvent', 'DeviceOrientationEvent',
    'GPU', 'ImageDecoder', 'VideoDecoder', 'PaymentRequest', 'Notification',
    'RTCDataChannel', 'SpeechSynthesisUtterance', 'SharedArrayBuffer',
    // read only by the challenge page, kept so one probe covers both documents
    'IntersectionObserver', 'frameElement'];
  for (const n of WIN) safe('win.' + n, () => any(window[n]));

  // --- and off navigator ---------------------------------------------------
  for (const n of ['maxTouchPoints', 'gpu', 'getGamepads', 'permissions', 'getBattery',
    'storage', 'connection', 'plugins', 'mediaCapabilities', 'onLine', 'language',
    'languages', 'userAgentData', 'sendBeacon', 'keyboard',
    'cookieEnabled', 'product', 'userAgent']) {
    safe('nav.' + n, () => any(navigator[n]));
  }
  safe('nav.languages.value', () => JSON.stringify(navigator.languages));
  safe('nav.plugins.length', () => navigator.plugins && navigator.plugins.length);

  // --- NavigatorUAData, which it reads twice -------------------------------
  safe('nk.getHighEntropyValues', () => any(navigator.userAgentData &&
    navigator.userAgentData.getHighEntropyValues));
  safe('nk.toJSON', () => any(navigator.userAgentData && navigator.userAgentData.toJSON));
  safe('nk.toJSON.value', () => navigator.userAgentData === undefined ? 'absent'
    : JSON.stringify(navigator.userAgentData.toJSON()));

  // --- performance.memory, the one Performance member the widget reads -----
  safe('perf.memory', () => any(performance.memory));
  safe('perf.memory.keys', () => performance.memory === undefined ? 'absent'
    : Object.getOwnPropertyNames(Object.getPrototypeOf(performance.memory) || {}).join(','));

  // --- screen, read as an object then walked -------------------------------
  safe('scr.width', () => screen.width);
  safe('scr.height', () => screen.height);
  safe('scr.own', () => Object.getOwnPropertyNames(Object.getPrototypeOf(screen) || {}).join(','));

  // --- the one MediaQueryList member it reads ------------------------------
  const mq = {};
  for (const q of ['(prefers-reduced-motion: reduce)', '(prefers-color-scheme: dark)',
    '(pointer: coarse)', '(pointer: fine)', '(hover: hover)', '(any-pointer: coarse)',
    '(display-mode: browser)', '(display-mode: standalone)', '(forced-colors: active)',
    '(prefers-contrast: more)', '(min-resolution: 2dppx)', '(orientation: landscape)',
    '(color-gamut: srgb)', '(color-gamut: p3)', '(dynamic-range: high)',
    '(scripting: enabled)', '(update: fast)', '(inverted-colors: inverted)']) {
    try { mq[q] = matchMedia(q).matches; } catch (e) { mq[q] = 'threw:' + e.name; }
  }
  out['mql.matches'] = mq;

  return out;
})()
