// Ordering, which decides what the implementation has to do first.
//
// Three questions the earlier probes left open:
//   - Which member does a dictionary with two bad ones report? (WebIDL says
//     members are read in alphabetical order; this checks Blink agrees.)
//   - Does the dictionary conversion run before or after the context type is
//     dispatched? OffscreenCanvas refuses an unknown type with its own
//     TypeError, so the two refusals are distinguishable.
//   - Does it run before or after the cached-context check?
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `${e.name}: ${e.message}`; } };
  const el = () => document.createElement('canvas');
  const off = () => new OffscreenCanvas(2, 2);

  // Only the offending member's name is interesting, so trim the rest.
  const which = (msg) => {
    const m = /read the '(\w+)' property/.exec(msg);
    return m ? m[1] : msg;
  };

  return {
    memberOrder: {
      'colorType+colorSpace': which(ask(() => String(
        el().getContext('2d', { colorType: 'bad', colorSpace: 'bad' }),
      ))),
      'colorSpace+colorType (reversed literal)': which(ask(() => String(
        el().getContext('2d', { colorSpace: 'bad', colorType: 'bad' }),
      ))),
      'willReadFrequently+colorSpace': which(ask(() => String(
        el().getContext('2d', { willReadFrequently: 'bad', colorSpace: 'bad' }),
      ))),
      'powerPreference+colorSpace': which(ask(() => String(
        el().getContext('2d', { powerPreference: 'bad', colorSpace: 'bad' }),
      ))),
      // A throwing getter against a bad enum: whichever runs first wins.
      'throwing alpha getter + bad colorSpace': ask(() => String(el().getContext('2d', {
        get alpha() { throw new TypeError('alpha-getter'); },
        colorSpace: 'bad',
      }))),
      'throwing xrCompatible getter + bad colorSpace': ask(() => String(el().getContext('2d', {
        get xrCompatible() { throw new TypeError('xr-getter'); },
        colorSpace: 'bad',
      }))),
    },
    dispatchOrder: {
      'offscreen bad type + bad colorSpace': ask(() => String(
        off().getContext('nonesuch', { colorSpace: 'bad' }),
      )),
      'offscreen bad type + good settings': ask(() => String(
        off().getContext('nonesuch', { colorSpace: 'srgb' }),
      )),
      'element bad type + bad colorSpace': ask(() => String(
        el().getContext('nonesuch', { colorSpace: 'bad' }),
      )),
      'element bad type + good settings': ask(() => String(
        el().getContext('nonesuch', { colorSpace: 'srgb' }),
      )),
      // A bad enum through a *cached* context: does the cache short-circuit it?
      'element cached 2d + bad colorSpace': ask(() => {
        const c = el();
        c.getContext('2d');
        return String(c.getContext('2d', { colorSpace: 'bad' }));
      }),
      'offscreen cached 2d + bad colorSpace': ask(() => {
        const c = off();
        c.getContext('2d');
        return String(c.getContext('2d', { colorSpace: 'bad' }));
      }),
      // A mismatched-but-valid request against a cached context still answers
      // null rather than throwing.
      'element cached 2d then webgl': ask(() => String(
        (() => { const c = el(); c.getContext('2d'); return c.getContext('webgl', { alpha: false }); })(),
      )),
    },
  };
})()
