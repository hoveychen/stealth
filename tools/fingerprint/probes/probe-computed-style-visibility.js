// The six properties Turnstile reads off `getComputedStyle` to decide whether
// its own widget is on screen. `api.js`'s La() builds
//
//   style: { contentVisibility: a.contentVisibility, display: a.display,
//            opacity: a.opacity, position: a.position,
//            transform: Ma(a.transform), visibility: a.visibility }
//
// and Ma(e) is `return e.length <= t ? e : ...`, so a single undefined among
// them -- `transform` -- turns a visibility report into
// `TypeError: Cannot read properties of undefined (reading 'length')`.
//
// Read on a *connected* element: Chrome answers "" for most properties of a
// detached one, which would hide the difference being measured.
(async () => {
  const d = document.createElement('div');
  d.style.position = 'absolute';
  document.body.appendChild(d);
  const cs = window.getComputedStyle(d);
  const keys = ['contentVisibility', 'display', 'opacity', 'position', 'transform', 'visibility'];
  const out = { computed: {}, inline: {}, byName: {} };
  for (const k of keys) {
    out.computed[k] = typeof cs[k] === 'undefined' ? 'UNDEFINED' : String(cs[k]);
    out.inline[k] = typeof d.style[k] === 'undefined' ? 'UNDEFINED' : String(d.style[k]);
    const dashed = k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());
    out.byName[dashed] = String(cs.getPropertyValue(dashed));
  }
  out.tag = Object.prototype.toString.call(cs);
  out.length = cs.length;
  out.inProto = keys.filter((k) => k in Object.getPrototypeOf(cs));
  out.inObject = keys.filter((k) => k in cs);

  // The other half of Turnstile's pair: Na() is the branch taken when the
  // element is *not* connected, and it reads the same six names off a
  // declaration for a detached element.
  const det = document.createElement('div');
  const dcs = window.getComputedStyle(det);
  out.detached = {};
  for (const k of keys) {
    out.detached[k] = typeof dcs[k] === 'undefined' ? 'UNDEFINED' : JSON.stringify(String(dcs[k]));
  }
  out.detachedLength = dcs.length;
  // And the shape Ma() actually depends on.
  out.detachedTransformType = typeof dcs.transform;
  out.connectedTransformType = typeof cs.transform;
  return out;
})()
