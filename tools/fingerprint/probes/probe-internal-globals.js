// The five interface objects this engine names on `window` and no Chrome does,
// read for what Chrome puts in their place -- because hiding the global is only
// half the fix. Marking a type `no_interface_object` takes the name off the
// window and leaves its `Symbol.toStringTag`, and every one of these five has a
// *different* tag in Chrome than the global name we expose. Converting them
// without checking would trade a global-name tell for a toStringTag tell.
//
// Measured on headed Chrome 150 / this engine, same page, same port:
//
//   ours (global + tag)              Chrome global   Chrome tag
//   WEBGL_debug_renderer_info        undefined       [object WebGLDebugRendererInfo]
//   WEBGL_lose_context               undefined       [object WebGLLoseContext]
//   SVGGenericElement                undefined       [object SVGElement]      <- and the prototype is SVGElement
//   ReadableStreamAsyncIterator      undefined       [object ReadableStream AsyncIterator]   <- note the space
//   CrossOriginWindow                undefined       [object Window]
//
// Two more findings fell out of it: Chrome's extension prototypes have no
// `constructor` own property (there is no interface object to point at) and ours
// do, and `getExtension('WEBGL_debug_shaders')` answers an object in Chrome and
// `undefined` here -- a missing extension no globals diff could show, because
// Chrome does not name it on the window either.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-internal-globals.js \
//       http://localhost:8777/ --headed
//
// Reading in results/probes/probe-internal-globals.{chrome,lightpanda}.json.
(() => {
  const tag = (v) => { try { return Object.prototype.toString.call(v); } catch (e) { return 'THREW ' + e.message; } };
  const proto = (v) => { try { return Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto'; } catch (e) { return 'THREW'; } };
  const out = {};
  const gl = document.createElement('canvas').getContext('webgl');
  for (const name of ['WEBGL_debug_renderer_info', 'WEBGL_lose_context', 'WEBGL_debug_shaders']) {
    const ext = gl.getExtension(name);
    out['getExtension(' + name + ')'] = {
      global: typeof window[name],
      tag: tag(ext),
      ctor: proto(ext),
      own_proto_names: ext ? Object.getOwnPropertyNames(Object.getPrototypeOf(ext)).join(' ') : null,
    };
  }
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'notarealtag');
  out['unknown svg element'] = { tag: tag(svg), ctor: proto(svg), global_SVGGenericElement: typeof window.SVGGenericElement };
  const rs = new ReadableStream({ start(c) { c.close(); } });
  const it = rs[Symbol.asyncIterator] ? rs[Symbol.asyncIterator]() : null;
  out['ReadableStream async iterator'] = {
    has_symbol: !!rs[Symbol.asyncIterator],
    tag: tag(it),
    ctor: proto(it),
    global: typeof window.ReadableStreamAsyncIterator,
    proto_names: it ? Object.getOwnPropertyNames(Object.getPrototypeOf(it)).join(' ') : null,
  };
  // A cross-origin window reference: the opener-less way is an iframe to another
  // origin, whose contentWindow is the cross-origin proxy.
  const f = document.createElement('iframe');
  f.src = 'https://example.com/';
  document.body.appendChild(f);
  out['cross-origin contentWindow'] = {
    tag: tag(f.contentWindow),
    global_CrossOriginWindow: typeof window.CrossOriginWindow,
    same_origin_tag: tag(window),
  };
  return { out };
})()
