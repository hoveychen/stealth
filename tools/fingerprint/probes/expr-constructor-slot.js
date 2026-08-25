// Where `constructor` sits in Object.getOwnPropertyNames(X.prototype), for
// every interface object the realm carries -- not just the handful
// expr-constructor-position.js names.
//
// V8 appends `constructor` to a prototype object after the template's own
// members, so a template-built prototype always reports it last. Blink does
// not: the members Chrome installs per-context (secure-context and
// runtime-flag gated ones) go on *after* V8's append, so `constructor` lands
// in the middle. The index is stable, cheap to read, and differs on every
// interface that has such a member -- so the useful reading is the name of the
// member `constructor` follows, which survives a count mismatch.
(() => {
  const out = {};
  for (const key of Object.getOwnPropertyNames(self)) {
    let ctor;
    try { ctor = self[key]; } catch (e) { continue; }
    if (typeof ctor !== 'function') continue;
    let proto;
    try { proto = ctor.prototype; } catch (e) { continue; }
    if (!proto || typeof proto !== 'object') continue;
    // Only the interface's own prototype, not an alias (webkitURL === URL).
    if (ctor.name !== key) continue;
    let names;
    try { names = Object.getOwnPropertyNames(proto); } catch (e) { continue; }
    const at = names.indexOf('constructor');
    if (at < 0) continue;
    out[key] = names.join(',');
  }
  return JSON.stringify(out);
})()
