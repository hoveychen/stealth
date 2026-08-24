// Reports the worker realm's own surface: which interface `navigator` is, what
// the global carries that a Window does not, and what a Window carries that a
// worker must not. Every expectation in realm_surface.html was read off a
// headless Chrome 151 blob worker (probes/expr-worker-surface.js).
//
// Every read goes through `ask`, because a missing global here is the thing
// under test: an unguarded `WorkerNavigator.prototype` would throw before the
// message is posted and the failure would arrive as a timeout instead of as an
// assertion.
self.onmessage = () => {
  const ask = (fn) => { try { return fn(); } catch (e) { return 'threw: ' + e.name; } };

  const holderOf = (name) => {
    if (Object.prototype.hasOwnProperty.call(self, name)) return 'self';
    for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
      if (Object.prototype.hasOwnProperty.call(o, name)) {
        const d = Object.getOwnPropertyDescriptor(o, 'constructor');
        return (d && typeof d.value === 'function' ? d.value.name : '<anonymous>') + '.prototype';
      }
    }
    return null;
  };
  const kindOf = (o, n) => {
    const d = Object.getOwnPropertyDescriptor(o, n);
    if (!d) return 'missing';
    const k = d.get || d.set
      ? 'accessor' + (d.get ? '/get' : '') + (d.set ? '/set' : '')
      : typeof d.value;
    return k + (d.enumerable ? ' e' : '') + (d.configurable ? ' c' : '');
  };

  postMessage({
    // navigator is a WorkerNavigator, not a Navigator.
    navigator_brand: Object.prototype.toString.call(navigator),
    navigator_ctor_name: ask(() => navigator.constructor.name),
    navigator_proto_is_wn: ask(() => Object.getPrototypeOf(navigator) === WorkerNavigator.prototype),
    typeof_WorkerNavigator: typeof WorkerNavigator,
    typeof_Navigator: typeof Navigator,
    wn_proto_own: ask(() => Object.getOwnPropertyNames(WorkerNavigator.prototype).sort().join(',')),
    // The window-only members a WorkerNavigator must not carry. `webdriver` is
    // the one that matters: answering `false` is answering a question that is
    // never asked here.
    window_only_in_navigator: ['webdriver', 'vendor', 'vendorSub', 'productSub',
      'doNotTrack', 'cookieEnabled', 'pdfViewerEnabled', 'javaEnabled',
      'maxTouchPoints'].filter((n) => n in navigator).join(','),

    // Members of the global this realm was missing entirely.
    self_name: self.name,
    holder_name: holderOf('name'),
    kind_origin: kindOf(WorkerGlobalScope.prototype, 'origin'),
    holder_origin: holderOf('origin'),
    origin: self.origin,
    holder_crossOriginIsolated: holderOf('crossOriginIsolated'),
    typeof_crossOriginIsolated: typeof self.crossOriginIsolated,
    // Window-only names that were leaking in.
    typeof_CookieStore: typeof CookieStore,
    typeof_CookieChangeEvent: typeof CookieChangeEvent,
    has_cookieStore: 'cookieStore' in self,
    // Window-only interface objects that reached this realm by riding along
    // with a type list rather than through an [Exposed] decision of their own:
    // the two legacy navigation-timing interfaces travel with Performance, and
    // the two legacy vendor-prefixed constructor names travel with DOMMatrix
    // and URL.
    window_only_interfaces: ['PerformanceNavigation', 'PerformanceTiming',
      'WebKitCSSMatrix', 'webkitURL'].filter((n) => n in self).join(','),
    // One name out of each family this realm was missing entirely.
    missing_families: ['VideoDecoder', 'AudioData', 'EncodedVideoChunk',
      'ImageDecoder', 'ImageBitmap', 'ImageBitmapRenderingContext', 'Scheduler',
      'TaskController', 'CacheStorage', 'NetworkInformation',
      'PerformanceResourceTiming', 'PerformanceServerTiming', 'USB', 'USBDevice',
      'HID', 'HIDDevice', 'Serial', 'SerialPort', 'ServiceWorkerRegistration',
      'PushManager', 'Lock', 'LockManager', 'MediaCapabilities',
      'UserActivation', 'WGSLLanguageFeatures',
    ].filter((n) => typeof self[n] !== 'function').join(','),
    // The families that have to stay out: a member of each wants the owner's
    // Frame -- most of them take one outright, StorageBucket.indexedDB reaches
    // for it through the Execution -- and a worker realm cannot be handed one.
    // Chrome's worker has all of these, so this is a measured shortfall rather
    // than a match: closing it needs worker-owned state, not another name in a
    // list.
    frame_bound: ['GPU', 'StorageBucket', 'FontFace',
      'MediaSource', 'CSSSkewX', 'Worker'].filter((n) => n in self).join(','),

    // Trusted Types, which is the one the station reads: its trampoline
    // worker's first statement is `if (self.trustedTypes)`. The whole round
    // trip, not just the name -- createPolicy in a worker used to be the
    // engine's ceiling, because every member of the factory wanted the owner's
    // Frame.
    tt_holder: holderOf('trustedTypes'),
    tt_brand: ask(() => Object.prototype.toString.call(self.trustedTypes)),
    tt_interfaces: ['TrustedHTML', 'TrustedScript', 'TrustedScriptURL',
      'TrustedTypePolicy', 'TrustedTypePolicyFactory']
      .filter((n) => typeof self[n] !== 'function').join(','),
    tt_policy_name: ask(() => self.trustedTypes
      .createPolicy('Kssz2', { createScript: (s) => s + '/ok' }).name),
    tt_created: ask(() => String(self.trustedTypes
      .createPolicy('Kssz3', { createScript: (s) => s + '/ok' }).createScript('x'))),
    tt_created_brand: ask(() => Object.prototype.toString.call(self.trustedTypes
      .createPolicy('Kssz4', { createScript: (s) => s }).createScript('x'))),
    tt_empty_identity: ask(() =>
      self.trustedTypes.emptyScript === self.trustedTypes.emptyScript),
    tt_default_policy: ask(() => self.trustedTypes.defaultPolicy),

    // console is own on self and nowhere else.
    holder_console: holderOf('console'),
    console_on_wgs_proto: Object.getOwnPropertyNames(WorkerGlobalScope.prototype).includes('console'),

    // The two deprecated quota constants stay on the interface prototype even
    // though DedicatedWorkerGlobalScope is [Global].
    dwgs_proto_own: Object.getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype).join(','),
  });
};
