// What Chrome's *setters* do on the properties this engine exposes read-only.
//
// probe-descriptor-kind.js says which properties are accessors in Chrome and a
// different kind here; it cannot say what the setter Chrome installs actually
// does. Some are `[LegacyLenientSetter]` (a no-op that swallows the assignment),
// some are `[PutForwards=value]` (the assignment lands on `.value` of the object
// the getter returns), and some are genuinely read-write. Adding a setter that
// throws where Chrome silently ignores -- or ignores where Chrome throws -- swaps
// one measurable difference for another.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-setter-semantics.js \
//       http://localhost:8777/ --headed
//
// Reading in results/probes/probe-setter-semantics.chrome.json.
(async () => {
  // What happened when `fn` ran: the value that came back out, or the error.
  const attempt = (fn) => {
    try {
      return { ok: true, after: fn() };
    } catch (e) {
      return { ok: false, error: e.constructor.name + ': ' + e.message };
    }
  };
  const show = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    if (typeof v === 'object') return Object.prototype.toString.call(v) + (v.value !== undefined ? ' value=' + JSON.stringify(v.value) : '');
    return typeof v + ' ' + JSON.stringify(v);
  };
  const out = {};
  const set = (label, target, key, value) => {
    out[label] = attempt(() => {
      target[key] = value;
      return show(target[key]);
    });
  };

  // [LegacyLenientSetter] in the Fullscreen spec: a setter that exists and does
  // nothing, so `document.fullscreen = 1` neither throws nor sticks.
  set('document.fullscreen = 1', document, 'fullscreen', 1);
  set('document.fullscreenEnabled = 0', document, 'fullscreenEnabled', 0);
  set('document.fullscreenElement = null', document, 'fullscreenElement', null);

  // [PutForwards=value]: the assignment is forwarded to the DOMTokenList's
  // `value`, so the attribute itself changes.
  const iframe = document.createElement('iframe');
  out['iframe.sandbox = "allow-scripts"'] = attempt(() => {
    iframe.sandbox = 'allow-scripts';
    return {
      kind: Object.prototype.toString.call(iframe.sandbox),
      value: iframe.sandbox.value,
      attribute: iframe.getAttribute('sandbox'),
      same_object: iframe.sandbox === iframe.sandbox,
    };
  });
  const anchor = document.createElement('a');
  out['a.relList = "nofollow"'] = attempt(() => {
    anchor.relList = 'nofollow';
    return { value: anchor.relList.value, rel: anchor.rel, attribute: anchor.getAttribute('rel') };
  });
  const output = document.createElement('output');
  out['output.htmlFor = "x y"'] = attempt(() => {
    output.htmlFor = 'x y';
    return { value: output.htmlFor.value, attribute: output.getAttribute('for') };
  });

  // Genuinely read-write, and each with its own failure shape.
  const file_input = document.createElement('input');
  file_input.type = 'file';
  out['input[file].files = null'] = attempt(() => {
    file_input.files = null;
    return show(file_input.files);
  });
  out['input[file].files = "x"'] = attempt(() => {
    file_input.files = 'x';
    return show(file_input.files);
  });
  const dt = new DataTransfer();
  dt.items.add(new File(['hi'], 'a.txt'));
  out['input[file].files = <FileList len 1>'] = attempt(() => {
    file_input.files = dt.files;
    return { length: file_input.files.length, name: file_input.files[0] && file_input.files[0].name, identity: file_input.files === dt.files };
  });
  const text_input = document.createElement('input');
  out['input[text].files = <FileList>'] = attempt(() => {
    text_input.files = dt.files;
    return show(text_input.files);
  });
  const email_input = document.createElement('input');
  email_input.type = 'email';
  out['input[email].selectionDirection read'] = attempt(() => show(email_input.selectionDirection));
  out['input[email].selectionDirection = "forward"'] = attempt(() => {
    email_input.selectionDirection = 'forward';
    return show(email_input.selectionDirection);
  });
  out['input[text].selectionDirection = "backward"'] = attempt(() => {
    text_input.selectionDirection = 'backward';
    return show(text_input.selectionDirection);
  });
  out['input[text].selectionDirection = "garbage"'] = attempt(() => {
    text_input.selectionDirection = 'garbage';
    return show(text_input.selectionDirection);
  });
  out['input[text].selectionDirection = null'] = attempt(() => {
    text_input.selectionDirection = null;
    return show(text_input.selectionDirection);
  });

  // WebIDL enum attributes: an out-of-range string is meant to be ignored for a
  // plain `attribute DOMString`, and a TypeError for an `attribute enum`.
  const gl = document.createElement('canvas').getContext('webgl');
  out['gl.drawingBufferColorSpace = "display-p3"'] = attempt(() => {
    gl.drawingBufferColorSpace = 'display-p3';
    return show(gl.drawingBufferColorSpace);
  });
  out['gl.drawingBufferColorSpace = "garbage"'] = attempt(() => {
    gl.drawingBufferColorSpace = 'garbage';
    return show(gl.drawingBufferColorSpace);
  });
  out['gl.unpackColorSpace = "display-p3"'] = attempt(() => {
    gl.unpackColorSpace = 'display-p3';
    return show(gl.unpackColorSpace);
  });
  out['gl.drawingBufferFormat = 0'] = attempt(() => {
    gl.drawingBufferFormat = 0;
    return show(gl.drawingBufferFormat);
  });

  // FontFace's descriptors are `attribute CSSOMString`, parsed on assignment.
  const ff = new FontFace('Test', 'local(Arial)');
  out['fontFace.family = "Other"'] = attempt(() => {
    ff.family = 'Other';
    return show(ff.family);
  });
  out['fontFace.style = "italic"'] = attempt(() => {
    ff.style = 'italic';
    return show(ff.style);
  });
  out['fontFace.style = "garbage"'] = attempt(() => {
    ff.style = 'garbage';
    return show(ff.style);
  });
  out['fontFace.weight = "700"'] = attempt(() => {
    ff.weight = '700';
    return show(ff.weight);
  });
  out['fontFace.unicodeRange = "U+0-FF"'] = attempt(() => {
    ff.unicodeRange = 'U+0-FF';
    return show(ff.unicodeRange);
  });
  out['fontFace.variant = "small-caps"'] = attempt(() => {
    ff.variant = 'small-caps';
    return show(ff.variant);
  });
  out['fontFace.featureSettings = "\\"liga\\" 0"'] = attempt(() => {
    ff.featureSettings = '"liga" 0';
    return show(ff.featureSettings);
  });
  out['fontFace.display = "swap"'] = attempt(() => {
    ff.display = 'swap';
    return show(ff.display);
  });
  out['fontFace.stretch = "condensed"'] = attempt(() => {
    ff.stretch = 'condensed';
    return show(ff.stretch);
  });
  out['fontFace.status = "loading"'] = attempt(() => {
    ff.status = 'loading';
    return show(ff.status);
  });
  out['fontFace defaults'] = attempt(() => {
    const f = new FontFace('D', 'local(Arial)');
    return ['style', 'weight', 'stretch', 'unicodeRange', 'variant', 'featureSettings', 'display', 'status']
      .map((k) => k + '=' + JSON.stringify(f[k])).join(' ');
  });
  out['fontFaceSet.size = 9'] = attempt(() => {
    document.fonts.size = 9;
    return show(document.fonts.size);
  });
  out['fontFaceSet.status = "loading"'] = attempt(() => {
    document.fonts.status = 'loading';
    return show(document.fonts.status);
  });

  // IDBObjectStore.name is settable, but only inside a versionchange
  // transaction -- which is the only place a rename can be recorded.
  out['idb'] = await new Promise((resolve) => {
    const results = {};
    const req = indexedDB.open('probe-setter-semantics-' + Math.random().toString(36).slice(2), 1);
    req.onupgradeneeded = (e) => {
      const db = e.target.result;
      const store = db.createObjectStore('original');
      results['in versionchange: rename'] = attempt(() => {
        store.name = 'renamed';
        return { name: store.name, storeNames: Array.from(db.objectStoreNames) };
      });
      results['in versionchange: rename to existing'] = attempt(() => {
        db.createObjectStore('other');
        store.name = 'other';
        return store.name;
      });
    };
    req.onsuccess = (e) => {
      const db = e.target.result;
      const tx = db.transaction(Array.from(db.objectStoreNames)[0], 'readwrite');
      const store = tx.objectStore(Array.from(db.objectStoreNames)[0]);
      results['in readwrite: rename'] = attempt(() => {
        store.name = 'nope';
        return store.name;
      });
      tx.oncomplete = () => {
        results['after commit: rename'] = attempt(() => {
          store.name = 'nope2';
          return store.name;
        });
        db.close();
        resolve(results);
      };
      tx.onerror = () => resolve(results);
    };
    req.onerror = () => resolve({ error: 'open failed' });
  });

  // MouseEvent.offsetX/offsetY, WebSocket.extensions, VisualViewport, the
  // ScreenOrientation pair and IdleDeadline.didTimeout are all readonly in
  // Chrome -- `get` with no setter -- so the only thing to record is that
  // assigning to them is silently dropped in sloppy mode.
  const ev = new MouseEvent('click');
  out['readonly (get, no setter)'] = attempt(() => {
    const before = ev.offsetX;
    ev.offsetX = 99;
    return 'offsetX ' + before + ' -> ' + ev.offsetX +
      ', descriptor set=' + typeof Object.getOwnPropertyDescriptor(MouseEvent.prototype, 'offsetX').set;
  });

  return { href: location.href, out };
})()
