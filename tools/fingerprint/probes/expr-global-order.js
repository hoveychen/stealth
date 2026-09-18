// The ordered list of the global's own property names.
//
// DataDome's device-check serialises exactly this -- order included -- into the
// payload it uploads, so the sequence is a measured surface. Read it on a real
// https page: on an insecure origin the engine deletes ~239 secure-context
// gated names (src/browser/js/secure_context.zig) and Chrome hides its own, so
// an about:blank reading scores a gap that is not there.
Object.getOwnPropertyNames(window)
