// The window global surface as a function of the origin's trustworthiness, so
// the WebIDL [SecureContext] gate can be diffed by name rather than by count.
//
// Run it twice against origins that differ in nothing but whether the host is
// loopback, and diff the two `names` strings -- that difference IS the gated
// set. Anything else (https vs http, a different port, a different path) also
// changes the scheme or the origin, which is exactly the confound this probe
// exists to avoid:
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-secure-context.js \
//       http://localhost:8777/ --headed          # loopback     -> secure
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-secure-context.js \
//       http://<lan-ip>:8777/ --headed           # not loopback -> insecure
//
// Measured on a headed Chrome 151 that way: 1237 own names on
// http://localhost:8777 and 985 on http://192.168.68.78:8777, so Chrome keeps
// 252 names behind the gate. http://0.0.0.0:8777 answers the same 985 as the
// LAN address while still reaching a loopback-bound listener, which is what the
// Zig suite uses -- it has no second interface to bind.
//
// Note for readings taken against this engine: a document only gets its answer
// settled when it commits, so a frame that never navigates (the bare
// about:blank CDP target this runner opens when given no url) still reports the
// full surface. Pass a url.
(() => {
  const names = Object.getOwnPropertyNames(window).sort();
  return {
    href: location.href,
    origin: location.origin,
    isSecureContext: window.isSecureContext,
    count: names.length,
    names: names.join(' '),
  };
})();
