// Every own property of the platform's prototypes, reduced to *what kind* of
// property it is: `get`, `set`, `accessor`, `method` or `value`.
//
// Why this and not the value: `Object.getOwnPropertyDescriptor(P, 'x').get.call(o)`
// is how a detector reads a property it does not trust the instance to answer
// honestly, and it is also how Cloudflare's Turnstile fails on this engine --
// "TypeError: Cannot read properties of undefined (reading 'call')" is what that
// expression throws when `x` is a *data* property here and an accessor in Chrome,
// because then `desc.get` is undefined. A property that exists with the right
// value and the wrong kind is invisible to every value-comparing probe in this
// directory and fatal to that one line.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-descriptor-kind.js \
//       http://localhost:8777/ --headed
//   node tools/fingerprint/run-probe.mjs lightpanda probes/probe-descriptor-kind.js \
//       http://localhost:8777/
//
// Readings in results/probes/probe-descriptor-kind.{chrome,lightpanda}.json.
(() => {
  const kind = (d) => {
    if (d.get && d.set) return 'accessor';
    if (d.get) return 'get';
    if (d.set) return 'set';
    if (typeof d.value === 'function') return 'method';
    return 'value';
  };

  // The prototypes a bot check walks. Named rather than enumerated off the
  // window so the two engines report the same list in the same order even where
  // one of them is missing an interface entirely.
  const NAMES = [
    'Window', 'Navigator', 'Document', 'Element', 'HTMLElement', 'Node', 'EventTarget',
    'HTMLIFrameElement', 'HTMLCanvasElement', 'HTMLScriptElement', 'HTMLInputElement',
    'HTMLFormElement', 'HTMLImageElement', 'HTMLDivElement', 'HTMLAnchorElement',
    'Screen', 'Performance', 'Location', 'History', 'Storage', 'CSSStyleDeclaration',
    'DOMRect', 'DOMRectReadOnly', 'Event', 'MouseEvent', 'PointerEvent', 'KeyboardEvent',
    'UIEvent', 'MessageEvent', 'ErrorEvent', 'CustomEvent', 'DataTransfer',
    'MediaQueryList', 'IntersectionObserver', 'MutationObserver', 'ResizeObserver',
    'PerformanceEntry', 'PerformanceNavigationTiming', 'PerformanceResourceTiming',
    'CanvasRenderingContext2D', 'WebGLRenderingContext', 'XMLHttpRequest',
    'ShadowRoot', 'DocumentFragment', 'Range', 'Selection', 'NodeList',
    'HTMLCollection', 'DOMTokenList', 'NamedNodeMap', 'Attr', 'CharacterData', 'Text',
    'AbortSignal', 'AbortController', 'URL', 'URLSearchParams', 'Headers', 'Request',
    'Response', 'Blob', 'File', 'FileReader', 'FormData', 'Crypto', 'SubtleCrypto',
    'WorkerNavigator', 'Worker', 'MessagePort', 'BroadcastChannel', 'WebSocket',
    'NetworkInformation', 'BatteryManager', 'Permissions', 'PermissionStatus',
    'MediaDevices', 'MediaStream', 'MediaStreamTrack', 'Gamepad', 'Keyboard',
    'VisualViewport', 'ScreenOrientation', 'Notification', 'PushManager',
    'ServiceWorkerContainer', 'ServiceWorker', 'CacheStorage', 'Cache',
    'IDBFactory', 'IDBDatabase', 'IDBObjectStore', 'IDBRequest', 'IDBTransaction',
    'CSSStyleSheet', 'StyleSheet', 'CSSRule', 'CSSStyleRule', 'FontFace', 'FontFaceSet',
    'SpeechSynthesis', 'SpeechSynthesisVoice', 'AudioContext', 'BaseAudioContext',
    'AnalyserNode', 'AudioBuffer', 'OscillatorNode', 'GainNode',
    'RTCPeerConnection', 'RTCDataChannel', 'PluginArray', 'Plugin', 'MimeTypeArray',
    'MimeType', 'NavigatorUAData', 'Clipboard', 'ClipboardItem', 'Sanitizer',
    'TrustedTypePolicyFactory', 'CustomElementRegistry', 'ElementInternals',
    'IdleDeadline', 'Scheduler', 'TaskController', 'TaskSignal', 'Animation',
    'AnimationEffect', 'KeyframeEffect', 'AnimationTimeline', 'DocumentTimeline',
    'ScrollTimeline', 'ViewTimeline', 'ReportingObserver', 'Report', 'ReportBody',
  ];

  // The globals themselves, whose descriptors on `window` are read the same way.
  const GLOBAL_PROPS = [
    'navigator', 'document', 'location', 'screen', 'performance', 'history',
    'localStorage', 'sessionStorage', 'indexedDB', 'crypto', 'caches',
    'innerWidth', 'innerHeight', 'outerWidth', 'outerHeight', 'devicePixelRatio',
    'screenX', 'screenY', 'scrollX', 'scrollY', 'origin', 'isSecureContext',
    'crossOriginIsolated', 'top', 'parent', 'self', 'window', 'frames', 'length',
    'closed', 'opener', 'name', 'status', 'chrome', 'speechSynthesis', 'visualViewport',
  ];

  const out = { protos: {}, globals: {}, missing: [] };
  for (const name of NAMES) {
    const ctor = window[name];
    if (typeof ctor !== 'function' || !ctor.prototype) {
      out.missing.push(name);
      continue;
    }
    const per = {};
    for (const key of Object.getOwnPropertyNames(ctor.prototype)) {
      if (key === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(ctor.prototype, key);
      per[key] = kind(d);
    }
    out.protos[name] = per;
  }
  for (const key of GLOBAL_PROPS) {
    const d = Object.getOwnPropertyDescriptor(window, key);
    out.globals[key] = d ? kind(d) : 'absent';
  }
  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
