// The three HTMLElement subclasses probe-shapes.js found on the window that this
// engine did not have. Unlike the rest of the F7 cut these are element
// interfaces, so the surface is not just the prototype: a tag name maps to each
// one, createElement() and the parser both have to answer it, and the members
// are mostly attribute reflection whose defaults and coercions are readable.
//
// The tag names are measured rather than guessed: every candidate goes through
// createElement() and through the parser, and whichever answers the interface
// rather than HTMLUnknownElement is the mapping.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s6-elements.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s6-elements.chrome.json.
(() => {
  const S = (fn) => {
    try {
      const v = fn();
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      return typeof v === 'object' ? Object.prototype.toString.call(v) : v;
    } catch (e) { return `${e.name}: ${e.message}`; }
  };

  const out = {};

  // Which tag builds which interface, both ways in.
  const TAGS = ['selectedcontent', 'selected-content', 'geolocation', 'usermedia',
    'user-media', 'userMedia', 'permission', 'location', 'media'];
  out.tags = {};
  for (const tag of TAGS) {
    out.tags[tag] = {
      created: S(() => document.createElement(tag).constructor.name),
      brand: S(() => Object.prototype.toString.call(document.createElement(tag))),
      localName: S(() => document.createElement(tag).localName),
      tagName: S(() => document.createElement(tag).tagName),
      parsed: S(() => {
        const host = document.createElement('div');
        host.innerHTML = `<${tag}></${tag}>`;
        return host.firstElementChild ? host.firstElementChild.constructor.name : 'no child';
      }),
      // A tag known to the parser closes an open one of itself; an unknown tag
      // nests. Cheap way to see whether the parser has a rule for it.
      nested: S(() => {
        const host = document.createElement('div');
        host.innerHTML = `<${tag}><${tag}></${tag}></${tag}>`;
        return host.querySelectorAll(tag).length + ':' +
          (host.firstElementChild ? host.firstElementChild.children.length : -1);
      }),
      // The uppercase spelling, which createElement lowercases for HTML.
      upper: S(() => document.createElement(tag.toUpperCase()).constructor.name),
      // And the same name in the SVG namespace, where no HTML mapping applies.
      svg: S(() => document.createElementNS('http://www.w3.org/2000/svg', tag).constructor.name),
    };
  }

  // Every member of each interface on a fresh element: what it answers before
  // anything is set, and whether it reflects a content attribute.
  const read = (el, stopAt) => {
    const values = {};
    let p = Object.getPrototypeOf(el);
    while (p && p.constructor.name !== stopAt) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (k === 'constructor') continue;
        values[k] = S(() => el[k]);
      }
      p = Object.getPrototypeOf(p);
    }
    return values;
  };
  const reflects = (tag, name, value) => S(() => {
    const el = document.createElement(tag);
    el[name] = value;
    return `attr=${el.getAttribute(name.toLowerCase())}|prop=${S(() => el[name])}`;
  });
  const fromAttr = (tag, name, attr, value) => S(() => {
    const el = document.createElement(tag);
    el.setAttribute(attr, value);
    return S(() => el[name]);
  });

  out.geolocation = {
    defaults: read(document.createElement('geolocation'), 'HTMLElement'),
    // The three lowercase members look like reflected attributes; the camelCase
    // ones look computed. This says which.
    accuracymode: reflects('geolocation', 'accuracymode', 'high'),
    accuracymodeBad: reflects('geolocation', 'accuracymode', 'nope'),
    accuracymodeAttr: fromAttr('geolocation', 'accuracymode', 'accuracymode', 'high'),
    autolocate: reflects('geolocation', 'autolocate', true),
    autolocateAttr: fromAttr('geolocation', 'autolocate', 'autolocate', ''),
    watch: reflects('geolocation', 'watch', true),
    watchAttr: fromAttr('geolocation', 'watch', 'watch', ''),
    isValidAfterAttrs: S(() => {
      const el = document.createElement('geolocation');
      el.setAttribute('autolocate', '');
      return `${el.isValid}|${el.invalidReason}`;
    }),
    inDocument: S(() => {
      const el = document.createElement('geolocation');
      document.body.appendChild(el);
      const answer = `${el.isValid}|${el.invalidReason}|${el.permissionStatus}|${el.initialPermissionStatus}`;
      el.remove();
      return answer;
    }),
    handlerSetter: S(() => {
      const el = document.createElement('geolocation');
      el.onlocation = () => {};
      return `${typeof el.onlocation}|attr=${el.getAttribute('onlocation')}`;
    }),
    handlerFromAttr: S(() => {
      const el = document.createElement('geolocation');
      el.setAttribute('onlocation', 'return 1');
      return typeof el.onlocation;
    }),
    handlerNonFunction: S(() => {
      const el = document.createElement('geolocation');
      el.onlocation = 5;
      return S(() => el.onlocation);
    }),
  };

  out.userMedia = {
    defaults: read(document.createElement('usermedia'), 'HTMLElement'),
    setConstraintsArity: S(() => HTMLUserMediaElement.prototype.setConstraints.length),
    setConstraintsBare: S(() => document.createElement('usermedia').setConstraints()),
    setConstraintsEmpty: S(() => document.createElement('usermedia').setConstraints({})),
    setConstraintsBad: S(() => document.createElement('usermedia').setConstraints(5)),
    setConstraintsThenStream: S(() => {
      const el = document.createElement('usermedia');
      el.setConstraints({ video: true });
      return `${S(() => el.stream)}|${S(() => el.error)}`;
    }),
    handlerSetter: S(() => {
      const el = document.createElement('usermedia');
      el.onstream = () => {};
      return typeof el.onstream;
    }),
  };

  out.selectedContent = {
    defaults: read(document.createElement('selectedcontent'), 'HTMLElement'),
    // It exists to be a slot inside a <select>'s button; whether it does
    // anything observable outside one is worth knowing.
    inSelect: S(() => {
      const select = document.createElement('select');
      select.innerHTML = '<button><selectedcontent></selectedcontent></button><option>a</option>';
      const sc = select.querySelector('selectedcontent');
      return sc ? `${sc.constructor.name}|${sc.innerHTML}` : 'no selectedcontent';
    }),
  };

  // setConstraints' dictionary, read off a Proxy: Chrome's binding touches
  // exactly the members it declares, in its own order.
  const spy = () => {
    const seen = [];
    return {
      seen,
      p: new Proxy({}, { get(_, k) { seen.push(String(k)); return undefined; }, has() { return true; } }),
    };
  };
  out.constraints = (() => {
    const el = document.createElement('usermedia');
    const outer = spy();
    const outcome = S(() => el.setConstraints(outer.p));
    const inner = spy();
    const nested = S(() => el.setConstraints({ video: inner.p }));
    return {
      members: outer.seen,
      outcome,
      nestedMembers: inner.seen,
      nested,
      emptyVideo: S(() => el.setConstraints({ video: {} })),
      emptyAudio: S(() => el.setConstraints({ audio: {} })),
      audioTrue: S(() => el.setConstraints({ audio: true })),
      videoNull: S(() => el.setConstraints({ video: null })),
      nullDict: S(() => el.setConstraints(null)),
      undefinedDict: S(() => el.setConstraints(undefined)),
      stringDict: S(() => el.setConstraints('x')),
      afterOk: S(() => { el.setConstraints({ video: {} }); return `${S(() => el.stream)}|${S(() => el.error)}`; }),
    };
  })();

  // Property descriptors, rendered the way tests/shape.js renders them so the
  // expected strings can be pasted straight across.
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;
  const shapeOf = (o) => {
    const list = [];
    for (const k of Object.getOwnPropertyNames(o)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (d.get || d.set) list.push(`${d.get ? (d.set ? 'accessor' : 'get') : 'set'} ${k}[${flags(d)}]`);
      else if (typeof d.value === 'function') list.push(`${k}/${d.value.length}[${flags(d)}]`);
      else list.push(`${k}=${String(d.value)}[${flags(d)}]`);
    }
    for (const s of Object.getOwnPropertySymbols(o)) {
      const v = o[s];
      list.push(`@@${String(s).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${typeof v === 'function' ? `fn:${v.name}` : String(v)}`);
    }
    return list.join(',');
  };
  out.shapes = Object.fromEntries(['HTMLSelectedContentElement', 'HTMLGeolocationElement',
    'HTMLUserMediaElement'].map((n) => [n, shapeOf(window[n].prototype)]));

  // Where the parser puts a <selectedcontent>, in and out of a <select>.
  out.selectedContentPlacement = {
    inDiv: S(() => {
      const host = document.createElement('div');
      host.innerHTML = '<button><selectedcontent></selectedcontent></button>';
      return host.innerHTML;
    }),
    inSelectHtml: S(() => {
      const select = document.createElement('select');
      select.innerHTML = '<button><selectedcontent></selectedcontent></button><option>a</option>';
      return select.innerHTML;
    }),
    appended: S(() => {
      const host = document.createElement('div');
      host.appendChild(document.createElement('selectedcontent'));
      return host.innerHTML;
    }),
  };

  // What a page sees before the interfaces exist at all: the same three tags in
  // an engine without them answer HTMLUnknownElement, so the mapping is the
  // whole difference.
  out.unknownControl = {
    definitelyUnknown: S(() => document.createElement('nosuchtag').constructor.name),
    hyphenated: S(() => document.createElement('a-b').constructor.name),
  };

  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
