// Batch 20 / P1 discovery: G17's last fifteen window keys.
//
// Eight webkit-legacy names and seven miscellaneous ones. Some are interfaces,
// some are plain window functions, and at least three are old enough that they
// may be gone from Chrome 150 -- which is itself the answer, since shipping a
// global the reference browser does not have is as loud as missing one. Run
// against Chrome first to set scope, then against lightpanda to diff.
(async () => {
  const err = (e) => {
    try {
      if (e === undefined) return 'REJECTED-WITH undefined';
      if (e === null) return 'REJECTED-WITH null';
      if (typeof e === 'object' && 'name' in e && 'message' in e) return `${e.name}: ${e.message}`;
      return `REJECTED-WITH ${Object.prototype.toString.call(e)} ${String(e)}`;
    } catch { return 'REJECTED-WITH <unstringifiable>'; }
  };
  const s = (f) => { try { const v = f(); return v === undefined ? 'undefined' : String(v); } catch (e) { return err(e); } };
  const settle = (thunk, ok) => {
    let p;
    try { p = thunk(); } catch (e) { return Promise.resolve(`SYNC ${err(e)}`); }
    if (!p || typeof p.then !== 'function') return Promise.resolve(`NOT-A-PROMISE ${String(p)}`);
    return p.then((v) => { try { return `OK ${ok ? ok(v) : String(v)}`; } catch (e) { return `OK <describe threw ${err(e)}>`; } }, (e) => err(e));
  };
  const sect = async (fn) => { try { return await fn(); } catch (e) { return `SECTION THREW ${err(e)}`; } };
  const out = {};

  const NAMES = [
    // webkit legacy: the two filesystem entry points and the WebSQL opener are
    // plain window functions, not interfaces.
    'openDatabase', 'webkitRequestFileSystem', 'webkitResolveLocalFileSystemURL',
    'webkitSpeechGrammar', 'webkitSpeechGrammarList', 'webkitSpeechRecognition',
    'webkitSpeechRecognitionError', 'webkitSpeechRecognitionEvent',
    // misc
    'ElementInternals', 'HTMLFrameElement', 'HTMLMenuElement',
    'ImageBitmapRenderingContext', 'MutationEvent', 'WebKitCSSMatrix',
    'WebKitMutationObserver',
    // Neighbours worth knowing about: the unprefixed spellings, the rest of
    // the filesystem family, and what WebKitCSSMatrix/WebKitMutationObserver
    // alias to.
    'SpeechRecognition', 'SpeechGrammar', 'SpeechGrammarList',
    'SpeechRecognitionEvent', 'SpeechRecognitionErrorEvent', 'SpeechRecognitionAlternative',
    'SpeechRecognitionResult', 'SpeechRecognitionResultList', 'SpeechRecognitionPhrase',
    'FileSystem', 'FileSystemDirectoryEntry', 'FileSystemDirectoryReader',
    'FileSystemEntry', 'FileSystemFileEntry',
    'DOMMatrix', 'MutationObserver', 'MutationRecord', 'Database', 'SQLResultSet',
  ];

  const shape = (name) => {
    const C = globalThis[name];
    if (typeof C === 'undefined') return 'ABSENT';
    const r = {};
    r.typeof = typeof C;
    r.arity = s(() => C.length);
    r.name = s(() => C.name);
    r.windowFlags = s(() => {
      const d = Object.getOwnPropertyDescriptor(window, name);
      return `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${d.writable ? 'w' : '-'}`;
    });
    if (typeof C !== 'function') { r.value = s(() => String(C)); return r; }
    r.statics = s(() => Object.getOwnPropertyNames(C).filter((k) => !['length', 'name', 'prototype'].includes(k)).join(' '));
    r.ctorProtoOf = s(() => Object.getPrototypeOf(C).name || String(Object.getPrototypeOf(C)));
    const P = C.prototype;
    if (!P) { r.prototype = 'none'; return r; }
    r.protoOf = s(() => {
      const pp = Object.getPrototypeOf(P);
      return pp === null ? 'null' : (pp === Object.prototype ? 'Object.prototype' : Object.prototype.toString.call(pp));
    });
    r.brand = s(() => String(P[Symbol.toStringTag]));
    r.protoOwn = s(() => Object.getOwnPropertyNames(P).join(' '));
    r.protoSymbols = s(() => Object.getOwnPropertySymbols(P).map(String).join(' '));
    r.desc = {};
    for (const k of Object.getOwnPropertyNames(P)) {
      const d = Object.getOwnPropertyDescriptor(P, k);
      if (d.get || d.set) r.desc[k] = `accessor g=${!!d.get} s=${!!d.set} e=${d.enumerable} c=${d.configurable}`;
      else r.desc[k] = `value ${typeof d.value}${typeof d.value === 'function' ? '/' + d.value.length : ''} w=${d.writable} e=${d.enumerable} c=${d.configurable}`;
    }
    r.newNoArgs = s(() => { const o = new C(); return Object.prototype.toString.call(o); });
    return r;
  };

  out.shapes = {};
  for (const n of NAMES) out.shapes[n] = shape(n);

  // Which of the aliases are the *same* object rather than a lookalike.
  out.aliases = {
    speechRecognition: s(() => window.webkitSpeechRecognition === window.SpeechRecognition),
    speechGrammar: s(() => window.webkitSpeechGrammar === window.SpeechGrammar),
    speechGrammarList: s(() => window.webkitSpeechGrammarList === window.SpeechGrammarList),
    speechRecognitionEvent: s(() => window.webkitSpeechRecognitionEvent === window.SpeechRecognitionEvent),
    speechRecognitionError: s(() => window.webkitSpeechRecognitionError === window.SpeechRecognitionErrorEvent),
    webkitCSSMatrix: s(() => window.WebKitCSSMatrix === window.DOMMatrix),
    webkitMutationObserver: s(() => window.WebKitMutationObserver === window.MutationObserver),
  };

  // ---- Speech Recognition ------------------------------------------------
  out.speech = await sect(async () => {
    const r = {};
    if (typeof webkitSpeechRecognition === 'undefined') return 'ABSENT';
    const rec = new webkitSpeechRecognition();
    r.brand = s(() => Object.prototype.toString.call(rec));
    // Every own value a fresh recogniser reports, in prototype order.
    r.defaults = s(() => Object.getOwnPropertyNames(Object.getPrototypeOf(rec))
      .filter((k) => k !== 'constructor')
      .map((k) => { try { const v = rec[k]; return `${k}=${typeof v === 'function' ? 'fn' : String(v)}`; } catch (e) { return `${k}=<${e.name}>`; } })
      .join(' '));
    r.setLang = s(() => { rec.lang = 'en-GB'; return rec.lang; });
    r.setContinuous = s(() => { rec.continuous = true; return rec.continuous; });
    r.setMaxAlternatives = s(() => { rec.maxAlternatives = 5; return rec.maxAlternatives; });
    r.setInterim = s(() => { rec.interimResults = true; return rec.interimResults; });
    // start() needs a mic; with none, what comes back and how.
    r.startReturn = s(() => String(rec.start()));
    r.startTwice = s(() => { try { rec.start(); return 'no throw'; } catch (e) { return err(e); } });
    r.stopReturn = s(() => String(rec.stop()));
    r.abortReturn = s(() => String(rec.abort()));
    // Does an error event arrive, and what is on it?
    r.errorEvent = await new Promise((res) => {
      const t = setTimeout(() => res('TIMEOUT'), 1500);
      const fresh = new webkitSpeechRecognition();
      fresh.onerror = (e) => { clearTimeout(t); res(`${e.type}|error=${e.error}|message="${e.message}"|brand=${Object.prototype.toString.call(e)}`); };
      fresh.onend = () => {};
      try { fresh.start(); } catch (e) { clearTimeout(t); res(`START ${err(e)}`); }
    });

    if (typeof webkitSpeechGrammarList !== 'undefined') {
      const list = new webkitSpeechGrammarList();
      r.grammarListBrand = s(() => Object.prototype.toString.call(list));
      r.grammarListLength = s(() => list.length);
      r.grammarListIndexed = s(() => String(list[0]));
      r.addFromString = s(() => { list.addFromString('#JSGF V1.0; grammar t; public <t> = a | b ;', 1); return `${list.length}|${Object.prototype.toString.call(list[0])}|src=${list[0].src}|w=${list[0].weight}`; });
      r.addFromUri = s(() => { list.addFromURI('http://x/y.gram', 0.5); return `${list.length}|src=${list[1].src}|w=${list[1].weight}`; });
      r.addNoArgs = s(() => list.addFromString());
      r.itemOob = s(() => String(list.item(99)));
      r.grammarNew = s(() => { const g = new webkitSpeechGrammar(); return `${Object.prototype.toString.call(g)}|src="${g.src}"|w=${g.weight}`; });
      r.recGrammars = s(() => Object.prototype.toString.call(rec.grammars));
      r.recGrammarsSettable = s(() => { rec.grammars = list; return rec.grammars === list; });
    }

    // The two event interfaces: constructible from a page?
    r.eventNew = s(() => new webkitSpeechRecognitionEvent('result'));
    r.errorNew = s(() => new webkitSpeechRecognitionError('error'));
    return r;
  });

  // ---- filesystem / WebSQL -----------------------------------------------
  out.filesystem = await sect(async () => {
    const r = {};
    r.requestFileSystemArity = s(() => webkitRequestFileSystem.length);
    r.resolveArity = s(() => webkitResolveLocalFileSystemURL.length);
    r.openDatabaseArity = s(() => openDatabase.length);
    r.constants = s(() => `TEMPORARY=${window.TEMPORARY} PERSISTENT=${window.PERSISTENT}`);

    r.requestNoArgs = s(() => webkitRequestFileSystem());
    r.request = await new Promise((res) => {
      const t = setTimeout(() => res('TIMEOUT'), 1500);
      try {
        webkitRequestFileSystem(window.TEMPORARY, 1024,
          (fs) => { clearTimeout(t); res(`OK ${Object.prototype.toString.call(fs)}|name=${fs.name}|root=${Object.prototype.toString.call(fs.root)}|fullPath=${fs.root.fullPath}|isDir=${fs.root.isDirectory}`); },
          (e) => { clearTimeout(t); res(`ERR ${err(e)}`); });
      } catch (e) { clearTimeout(t); res(`SYNC ${err(e)}`); }
    });
    r.resolve = await new Promise((res) => {
      const t = setTimeout(() => res('TIMEOUT'), 1500);
      try {
        webkitResolveLocalFileSystemURL('filesystem:' + location.origin + '/temporary/',
          (entry) => { clearTimeout(t); res(`OK ${Object.prototype.toString.call(entry)}`); },
          (e) => { clearTimeout(t); res(`ERR ${err(e)}`); });
      } catch (e) { clearTimeout(t); res(`SYNC ${err(e)}`); }
    });
    r.openDatabase = s(() => { const db = openDatabase('t', '1.0', 'test', 1024); return `${Object.prototype.toString.call(db)}|version=${db.version}`; });
    r.openDatabaseNoArgs = s(() => openDatabase());
    return r;
  });

  // ---- misc seven ---------------------------------------------------------
  out.misc = await sect(async () => {
    const r = {};
    // ElementInternals only exists via attachInternals() on a custom element.
    r.internals = s(() => {
      class Thing extends HTMLElement { constructor() { super(); this._i = this.attachInternals(); } }
      customElements.define('probe-thing-' + Math.floor(performance.now()), Thing);
      const el = new Thing();
      return `${Object.prototype.toString.call(el._i)}|shadowRoot=${String(el._i.shadowRoot)}|form=${String(el._i.form)}|willValidate=${el._i.willValidate}`;
    });
    r.attachInternalsOnPlain = s(() => document.createElement('div').attachInternals());
    r.attachInternalsExists = s(() => typeof HTMLElement.prototype.attachInternals);

    // Which tag each of the two HTML element interfaces is behind.
    r.frameTag = s(() => Object.prototype.toString.call(document.createElement('frame')));
    r.menuTag = s(() => Object.prototype.toString.call(document.createElement('menu')));
    r.dirTag = s(() => Object.prototype.toString.call(document.createElement('dir')));

    // ImageBitmapRenderingContext comes off a canvas.
    r.bitmaprenderer = s(() => {
      const c = document.createElement('canvas');
      const ctx = c.getContext('bitmaprenderer');
      return `${Object.prototype.toString.call(ctx)}|canvas=${ctx.canvas === c}`;
    });
    r.transferFromImageBitmap = await sect(async () => {
      const c = Object.assign(document.createElement('canvas'), { width: 4, height: 4 });
      const ctx = c.getContext('bitmaprenderer');
      const src = Object.assign(document.createElement('canvas'), { width: 8, height: 8 });
      const bmp = await createImageBitmap(src);
      return s(() => `${String(ctx.transferFromImageBitmap(bmp))}|after ${c.width}x${c.height}|bmp ${bmp.width}x${bmp.height}`);
    });
    r.transferNull = s(() => {
      const ctx = document.createElement('canvas').getContext('bitmaprenderer');
      return String(ctx.transferFromImageBitmap(null));
    });

    // MutationEvent: deprecated, but is it still constructible / dispatchable?
    r.mutationEventNew = s(() => {
      const e = new MutationEvent('DOMSubtreeModified');
      return `${e.type}|rel=${String(e.relatedNode)}|prev="${e.prevValue}"|new="${e.newValue}"|attr="${e.attrName}"|change=${e.attrChange}`;
    });
    r.mutationEventCreate = s(() => Object.prototype.toString.call(document.createEvent('MutationEvent')));
    r.mutationEventInit = s(() => {
      const e = document.createEvent('MutationEvent');
      e.initMutationEvent('DOMSubtreeModified', true, false, null, 'p', 'n', 'a', 1);
      return `${e.type}|${e.bubbles}|prev=${e.prevValue}|change=${e.attrChange}`;
    });
    r.mutationEventConstants = s(() => `MODIFICATION=${MutationEvent.MODIFICATION} ADDITION=${MutationEvent.ADDITION} REMOVAL=${MutationEvent.REMOVAL}`);

    // WebKitCSSMatrix: same object as DOMMatrix, or its own?
    r.matrixNew = s(() => { const m = new WebKitCSSMatrix(); return `${Object.prototype.toString.call(m)}|a=${m.a}|is2D=${m.is2D}`; });
    r.matrixFromString = s(() => { const m = new WebKitCSSMatrix('matrix(1, 0, 0, 1, 10, 20)'); return `${m.e},${m.f}|is2D=${m.is2D}`; });
    r.matrixBad = s(() => new WebKitCSSMatrix('nope'));
    r.mutationObserverNew = s(() => Object.prototype.toString.call(new WebKitMutationObserver(() => {})));
    return r;
  });

  out.secureContext = String(window.isSecureContext);
  out.origin = String(location.origin);
  return out;
})()
