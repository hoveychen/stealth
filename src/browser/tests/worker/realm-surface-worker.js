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
    typeof_trustedTypes: typeof self.trustedTypes,
    holder_trustedTypes: holderOf('trustedTypes'),
    typeof_caches: typeof self.caches,
    holder_caches: holderOf('caches'),

    // Window-only names that were leaking in.
    typeof_CookieStore: typeof CookieStore,
    typeof_CookieChangeEvent: typeof CookieChangeEvent,
    has_cookieStore: 'cookieStore' in self,

    // console is own on self and nowhere else.
    holder_console: holderOf('console'),
    console_on_wgs_proto: Object.getOwnPropertyNames(WorkerGlobalScope.prototype).includes('console'),

    // The two deprecated quota constants stay on the interface prototype even
    // though DedicatedWorkerGlobalScope is [Global].
    dwgs_proto_own: Object.getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype).join(','),
  });
};
