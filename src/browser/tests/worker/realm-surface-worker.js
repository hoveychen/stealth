// Reports the worker realm's own surface: which interface `navigator` is, what
// the global carries that a Window does not, and what a Window carries that a
// worker must not. Every expectation in realm_surface.html was read off a
// headless Chrome 151 blob worker (probes/expr-worker-surface.js).
//
// Every read goes through `ask`, because a missing global here is the thing
// under test: an unguarded `WorkerNavigator.prototype` would throw before the
// message is posted and the failure would arrive as a timeout instead of as an
// assertion.
self.onmessage = async () => {
  const ask = (fn) => { try { return fn(); } catch (e) { return 'threw: ' + e.name; } };

  // The one reading here that needs a turn of the microtask queue: a bucket
  // arrives through a promise, and `bucket.indexedDB` is the member that used
  // to assume the global was a Frame.
  let bucket = null;
  try {
    bucket = await navigator.storageBuckets.open('kssz-bucket');
  } catch { /* left null, and reported as such */ }

  // The sandboxed filesystem answers through callbacks, so it needs a turn too.
  // Two requests for the same quota type hand back the same object, and the
  // name it reports is built from this realm's origin.
  let fs_name = 'threw';
  let fs_identity = 'threw';
  let fs_resolved = 'threw';
  try {
    const ask1 = new Promise((ok, no) => self.webkitRequestFileSystem(0, 0, ok, no));
    const ask2 = new Promise((ok, no) => self.webkitRequestFileSystem(0, 0, ok, no));
    const [fs1, fs2] = await Promise.all([ask1, ask2]);
    fs_name = fs1.name;
    fs_identity = fs1 === fs2;
    const entry = await new Promise((ok, no) =>
      self.webkitResolveLocalFileSystemURL(fs1.root.toURL(), ok, no));
    fs_resolved = entry.fullPath + ':' + entry.isDirectory;
  } catch (e) { fs_name = 'threw: ' + e.name; }

  // Same, for the two font promises. `fonts.load` is the member that dispatches
  // into this realm's listener list rather than the owner's.
  let fonts_loaded = 'threw';
  try {
    self.fonts.addEventListener('loading', () => { fonts_loaded += ':loading'; });
    await self.fonts.load('12px Kssz');
    await self.fonts.ready;
    fonts_loaded = 'ok' + fonts_loaded.slice('threw'.length);
  } catch (e) { fonts_loaded = 'threw: ' + e.name; }

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
    // Unsorted, because declaration order is itself a reading a collector can
    // take, and Chrome's is not alphabetical.
    // `constructor` is left out: the bridge installs it after the declared
    // members, Chrome installs it in the middle (right after `connection` here),
    // and that placement is the same for every interface this engine builds --
    // not something this surface can fix on its own.
    wn_proto_order: ask(() => Object.getOwnPropertyNames(WorkerNavigator.prototype)
      .filter((n) => n !== 'constructor').join(',')),
    // The services a Chrome worker reaches through its navigator. The Akamai
    // collector on macys.com asks this realm for `connection` twice per worker
    // (measured with the engine's own unknown_prop log), so its absence was
    // visible from inside the guard.
    wn_services: ask(() => ['connection', 'hid', 'mediaCapabilities', 'serial', 'usb', 'locks']
      .map((n) => `${n}=${navigator[n] === undefined ? 'absent' : Object.prototype.toString.call(navigator[n])}`)
      .join(' ')),
    wn_connection: ask(() => [navigator.connection.effectiveType, navigator.connection.rtt,
      navigator.connection.downlink, navigator.connection.saveData].join('/')),
    wn_connection_stable: ask(() => navigator.connection === navigator.connection),
    wn_connection_is_event_target: ask(() => navigator.connection instanceof EventTarget),
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
    // The two that stay out, and for two different reasons. `Worker` is
    // genuinely frame-scoped -- spawning one goes through the frame's loader and
    // worker registry. `CSSSkewX` is not, but Chrome exposes it and CSSSkewY
    // without their prototype chain, so matching it is more than the mechanical
    // conversion the rest of this file's families got. Both are a measured
    // shortfall against Chrome's worker, not a match.
    //
    // Adding `Worker` to the dedicated-worker list was tried, and the name on
    // its own is WORSE than the shortfall: with it exposed, a worker that calls
    // `new Worker(...)` hangs this engine -- the driving Runtime.evaluate never
    // returns -- where Chrome nests happily (measured on the same page: the
    // inner worker echoes, `typeof Worker` is "function"). An absent name is a
    // clean ReferenceError; a present one that wedges the engine is a louder
    // tell and a worse bug. So this stays out until the spawn path can reach a
    // worker realm's frame.
    //
    // While measuring that: Chrome does NOT carry `Worker` in a SHARED worker,
    // despite the IDL's [Exposed=(Window,DedicatedWorker,SharedWorker)] --
    // `typeof Worker` is "undefined" there. If it is ever added, it belongs in
    // dedicated_worker_only_apis, not worker_common_apis.
    frame_bound: ['CSSSkewX', 'Worker'].filter((n) => n in self).join(','),

    // The sandboxed filesystem. Chrome's worker carries the two async
    // operations as own enumerable functions of the global and names none of
    // the entry interfaces -- neither realm does, there or here. `forKind` kept
    // its two filesystems on `exec.js.global.frame.window`, which is the reach
    // that had to go.
    webkit_fs: ['webkitRequestFileSystem', 'webkitResolveLocalFileSystemURL']
      .map((n) => kindOf(self, n)).join(' '),
    webkit_fs_arity: ask(() => ['webkitRequestFileSystem', 'webkitResolveLocalFileSystemURL']
      .map((n) => self[n].length).join(',')),
    webkit_fs_name: fs_name,
    webkit_fs_identity: fs_identity,
    webkit_fs_resolved: fs_resolved,

    // The font families. What they wanted the Frame for was an arena, the
    // factory and -- in `FontFaceSet.load` -- somewhere to dispatch two events;
    // an Execution has the first two and `GlobalScope.eventManagerBase()` is
    // the listener list of whichever realm is asking. `self.fonts` is a
    // WorkerGlobalScope.prototype member on Chrome.
    font_family: ['FontFace', 'FontFaceSet']
      .filter((n) => typeof self[n] !== 'function').join(','),
    // FontFaceSetLoadEvent is Window-only: it must not travel with them.
    typeof_FontFaceSetLoadEvent: typeof FontFaceSetLoadEvent,
    fonts_holder: holderOf('fonts'),
    fonts_brand: ask(() => Object.prototype.toString.call(self.fonts)),
    fonts_identity: ask(() => self.fonts === self.fonts),
    fonts_status: ask(() => self.fonts.status),
    fonts_size: ask(() => self.fonts.size),
    // The load path, which is the one that reaches for a listener list.
    fonts_loaded: fonts_loaded,
    font_face_family: ask(() => new FontFace('Kssz', 'local(Arial)').family),
    font_face_style: ask(() => new FontFace('Kssz', 'local(Arial)').style),

    // Storage buckets. Only one member of the family reached for the owner --
    // `StorageBucket.indexedDB`, through `exec.js.global.frame.window` on the
    // stated assumption that the global is always a Frame. Both globals answer
    // `getIndexedDB`, so the assumption was the bug: a bucket in a worker
    // shares the worker's factory, which is what `self.indexedDB` is.
    bucket_family: ['StorageBucket', 'StorageBucketManager']
      .filter((n) => typeof self[n] !== 'function').join(','),
    bucket_manager_brand: ask(() =>
      Object.prototype.toString.call(navigator.storageBuckets)),
    bucket_brand: bucket === null ? 'null' : Object.prototype.toString.call(bucket),
    bucket_name: ask(() => bucket.name),
    bucket_idb_brand: ask(() => Object.prototype.toString.call(bucket.indexedDB)),
    bucket_idb_is_realms: ask(() => bucket.indexedDB === self.indexedDB),

    // Media Source Extensions. Its accessors wanted a `*Page` rather than a
    // `*Frame`, which a worker realm can be handed -- but the page's factory is
    // the page's, and an object branded there and handed back here would be the
    // cross-realm bug the Frame rule exists to prevent. Through the Execution
    // the source buffer list is this realm's own. `MediaSource
    // .canConstructInDedicatedWorker` is the static that says so.
    mse_family: ['MediaSource', 'MediaSourceHandle', 'SourceBuffer',
      'SourceBufferList'].filter((n) => typeof self[n] !== 'function').join(','),
    mse_can_construct: ask(() => MediaSource.canConstructInDedicatedWorker),
    mse_buffers_brand: ask(() =>
      Object.prototype.toString.call(new MediaSource().sourceBuffers)),
    mse_buffers_identity: ask(() => {
      const ms = new MediaSource();
      return ms.sourceBuffers === ms.sourceBuffers
        && ms.sourceBuffers !== ms.activeSourceBuffers;
    }),
    mse_buffers_length: ask(() => new MediaSource().sourceBuffers.length),

    // WebGPU, all 40 interface objects Chrome's worker carries. The family used
    // to be Frame-bound off a single member -- GPU.wgslLanguageFeatures created
    // through `frame._factory` -- and a worker realm cannot be handed a Frame.
    // The factory it wanted is on the Execution, which Env builds per context,
    // so the whole family travels once that one signature changes.
    gpu_family: ['GPU', 'GPUAdapter', 'GPUAdapterInfo', 'GPUBindGroup',
      'GPUBindGroupLayout', 'GPUBuffer', 'GPUBufferUsage', 'GPUCanvasContext',
      'GPUColorWrite', 'GPUCommandBuffer', 'GPUCommandEncoder',
      'GPUCompilationInfo', 'GPUCompilationMessage', 'GPUComputePassEncoder',
      'GPUComputePipeline', 'GPUDevice', 'GPUDeviceLostInfo', 'GPUError',
      'GPUExternalTexture', 'GPUInternalError', 'GPUMapMode',
      'GPUOutOfMemoryError', 'GPUPipelineError', 'GPUPipelineLayout',
      'GPUQuerySet', 'GPUQueue', 'GPURenderBundle', 'GPURenderBundleEncoder',
      'GPURenderPassEncoder', 'GPURenderPipeline', 'GPUSampler',
      'GPUShaderModule', 'GPUShaderStage', 'GPUSupportedFeatures',
      'GPUSupportedLimits', 'GPUTexture', 'GPUTextureUsage', 'GPUTextureView',
      'GPUUncapturedErrorEvent', 'GPUValidationError',
    ].filter((n) => !(n in self)).join(','),
    // Five of the 40 are namespace objects holding the bitflag constants rather
    // than interface objects, on Chrome as much as here.
    gpu_namespaces: ['GPUBufferUsage', 'GPUColorWrite', 'GPUMapMode',
      'GPUShaderStage', 'GPUTextureUsage'].map((n) => typeof self[n]).join(','),
    gpu_interfaces: ['GPU', 'GPUAdapter', 'GPUDevice', 'GPUQueue', 'GPUBuffer',
      'GPUTexture', 'GPUCommandEncoder', 'GPUShaderModule', 'GPUValidationError',
    ].filter((n) => typeof self[n] !== 'function').join(','),
    // And the round trip that proves the factory is the worker's own: reading
    // `navigator.gpu` creates a GPU here, and reading its wgslLanguageFeatures
    // creates a branded set that keeps its identity across reads.
    nav_gpu_brand: ask(() => Object.prototype.toString.call(navigator.gpu)),
    gpu_canvas_format: ask(() => navigator.gpu.getPreferredCanvasFormat()),
    wgsl_brand: ask(() =>
      Object.prototype.toString.call(navigator.gpu.wgslLanguageFeatures)),
    wgsl_identity: ask(() =>
      navigator.gpu.wgslLanguageFeatures === navigator.gpu.wgslLanguageFeatures),
    wgsl_has_f16: ask(() => navigator.gpu.wgslLanguageFeatures.has('readonly_and_readwrite_storage_textures')),

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
