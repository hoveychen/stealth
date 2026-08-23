// What a stack string looks like here against Chrome. Nothing in fo-reads can
// see one -- a stack is read off an Error object, not through an accessor the
// tracer wraps -- so it is one of the channels still unaccounted for in the
// widget's round-1 payload.
//
//   node tools/fingerprint/run-expr.mjs chrome     tools/fingerprint/probes/expr-error-stack-shape.js
//   node tools/fingerprint/run-expr.mjs lightpanda tools/fingerprint/probes/expr-error-stack-shape.js
(() => {
  const out = {};
  const shape = (s) => (typeof s === 'string'
    ? { len: s.length, lines: s.split('\n').length, head: s.split('\n')[0], text: s.slice(0, 300) }
    : { len: -1, type: typeof s });

  out.bare = shape(new Error().stack);
  out.withMessage = shape(new Error('boom').stack);
  out.nested = shape((function a() { return (function b() { return new Error('x').stack; })(); })());
  out.thrownNative = shape((() => { try { null.x; } catch (e) { return e.stack; } })());
  out.typeErrorMessage = (() => { try { null.x; } catch (e) { return e.message; } })();
  out.stackTraceLimit = Error.stackTraceLimit;
  out.captureStackTrace = typeof Error.captureStackTrace;
  out.prepare = typeof Error.prepareStackTrace;
  out.toStringTag = Object.prototype.toString.call(new Error());
  return JSON.stringify(out);
})()
