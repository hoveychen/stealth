(async () => {
  // Batch 17 sweep: the WebCodecs family. Same shape dump as probe-win37.js for
  // the 12 globals, plus what each one is actually reachable *for* -- these are
  // all constructible from script, unlike most of WebGPU, so the constructors,
  // their statics (isConfigSupported / isTypeSupported) and the values a built
  // instance reports are the ground truth this batch needs.
  const NAMES = ['AudioData', 'AudioDecoder', 'AudioEncoder', 'EncodedAudioChunk', 'EncodedVideoChunk', 'ImageDecoder', 'ImageTrack', 'ImageTrackList', 'VideoColorSpace', 'VideoDecoder', 'VideoEncoder', 'VideoFrame'];

  const kind = (d) => (d.get ? (d.set ? 'accessor' : 'get') : (d.set ? 'set' : (typeof d.value === 'function' ? 'method' : 'value')));
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;
  const member = (o, k) => {
    const d = Object.getOwnPropertyDescriptor(o, k);
    const t = kind(d);
    if (t === 'method') return `${k}/${d.value.length}[${flags(d)}]`;
    if (t === 'value') return `${k}=${String(d.value)}[${flags(d)}]`;
    return `${t} ${k}[${flags(d)}]`;
  };
  const members = (o) => {
    const out = Object.getOwnPropertyNames(o).filter((k) => k !== 'constructor').map((k) => member(o, k));
    for (const s of Object.getOwnPropertySymbols(o)) {
      let v;
      try { v = String(o[s]); } catch (e) { v = `ERR ${e.name}`; }
      out.push(`@@${String(s).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${v}`);
    }
    return out.join(',');
  };
  const chain = (o) => {
    const names = [];
    for (let p = Object.getPrototypeOf(o); p; p = Object.getPrototypeOf(p)) {
      let n = '?';
      try { n = (p.constructor && p.constructor.name) || '(anon)'; } catch (e) { n = `ERR ${e.name}`; }
      names.push(n);
      if (names.length > 8) break;
    }
    return names.join('>');
  };
  const brand = (v) => { try { return Object.prototype.toString.call(v); } catch (e) { return `ERR ${e.name}`; } };
  const sync = (fn) => { try { const v = fn(); return v === undefined ? 'undefined' : brand(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  // Reads every own getter on the whole prototype chain, so the record is the
  // observable surface rather than a list I guessed.
  const dump = (o) => {
    if (o === null || o === undefined || typeof o !== 'object') return { primitive: String(o) };
    const r = { brand: brand(o), own: Object.getOwnPropertyNames(o).join(',') };
    for (let p = Object.getPrototypeOf(o); p && p !== Object.prototype; p = Object.getPrototypeOf(p)) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (k === 'constructor') continue;
        const d = Object.getOwnPropertyDescriptor(p, k);
        if (!d.get) continue;
        try { const v = o[k]; r[k] = (v && typeof v === 'object') ? brand(v) : v; } catch (e) { r[k] = `ERR ${e.name}: ${e.message}`; }
      }
    }
    return r;
  };

  const shapes = {};
  for (const name of NAMES) {
    const has = Object.prototype.hasOwnProperty.call(window, name);
    const v = window[name];
    if (typeof v === 'undefined') { shapes[name] = has ? 'OWN-BUT-UNDEFINED' : 'MISSING'; continue; }
    const wd = Object.getOwnPropertyDescriptor(window, name);
    const rec = {
      ownOnWindow: has,
      winFlags: wd ? flags(wd) : 'inherited',
      typeof: typeof v,
      ctorName: v.name,
      arity: v.length,
      ctorStr: String(v).slice(0, 60),
      statics: Object.getOwnPropertyNames(v).filter((k) => !['length', 'name', 'prototype'].includes(k)).map((k) => member(v, k)).join(','),
      ctorProtoOf: (() => { const p = Object.getPrototypeOf(v); return p === Function.prototype ? 'Function.prototype' : (p && p.name) || String(p); })(),
    };
    if (v.prototype) {
      rec.protoOwn = members(v.prototype);
      rec.protoChain = chain(v.prototype);
      rec.protoDescOfCtor = flags(Object.getOwnPropertyDescriptor(v, 'prototype'));
    } else {
      rec.protoOwn = 'NO-PROTOTYPE';
    }
    rec.newNoArg = (() => {
      try {
        const i = new v();
        return { ok: true, brand: brand(i), own: Object.getOwnPropertyNames(i).join(','), str: String(i).slice(0, 60) };
      } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    rec.callNoNew = (() => {
      try { const r = v(); return `ok: ${String(r).slice(0, 40)}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    shapes[name] = rec;
  }

  // ---- what a page can actually build --------------------------------------
  const entry = {};

  entry.VideoColorSpace = (() => {
    const empty = new VideoColorSpace();
    const full = new VideoColorSpace({ primaries: 'bt709', transfer: 'iec61966-2-1', matrix: 'smpte170m', fullRange: true });
    return {
      empty: dump(empty),
      emptyJson: empty.toJSON(),
      full: dump(full),
      fullJson: full.toJSON(),
      jsonBrand: brand(full.toJSON()),
      jsonKeys: Object.getOwnPropertyNames(full.toJSON()),
      badPrimaries: sync(() => new VideoColorSpace({ primaries: 'nope' })),
      stringArg: sync(() => new VideoColorSpace('nope')),
    };
  })();

  entry.VideoFrame = await (async () => {
    const canvas = document.createElement('canvas');
    canvas.width = 32; canvas.height = 16;
    canvas.getContext('2d').fillRect(0, 0, 8, 8);
    const out = {};
    out.fromCanvas = sync(() => new VideoFrame(canvas, { timestamp: 1234 }));
    const frame = (() => { try { return new VideoFrame(canvas, { timestamp: 1234 }); } catch (e) { return null; } })();
    if (frame) {
      out.frame = dump(frame);
      out.visibleRect = frame.visibleRect ? { brand: brand(frame.visibleRect), json: JSON.parse(JSON.stringify(frame.visibleRect)) } : 'null';
      out.colorSpace = frame.colorSpace ? { brand: brand(frame.colorSpace), json: frame.colorSpace.toJSON() } : 'null';
      out.allocationSize = sync(() => frame.allocationSize());
      out.allocationSizeValue = (() => { try { return frame.allocationSize(); } catch (e) { return `${e.name}: ${e.message}`; } })();
      out.metadata = (() => { try { const m = frame.metadata(); return { brand: brand(m), keys: Object.getOwnPropertyNames(m) }; } catch (e) { return `${e.name}: ${e.message}`; } })();
      out.cloned = (() => { try { const c = frame.clone(); const d = dump(c); c.close(); return d; } catch (e) { return `${e.name}: ${e.message}`; } })();
      out.copyTo = await (async () => {
        try { return `resolved ${JSON.stringify(await frame.copyTo(new Uint8Array(frame.allocationSize())))}`; }
        catch (e) { return `${e.name}: ${e.message}`; }
      })();
      out.afterClose = (() => {
        frame.close();
        return { codedWidth: frame.codedWidth, format: String(frame.format), timestamp: frame.timestamp, allocationSize: sync(() => frame.allocationSize()) };
      })();
    }
    out.noTimestamp = sync(() => new VideoFrame(canvas));
    out.noArg = sync(() => new VideoFrame());
    out.badSource = sync(() => new VideoFrame(5, { timestamp: 0 }));
    out.fromBuffer = sync(() => new VideoFrame(new Uint8Array(32 * 16 * 4), {
      format: 'RGBA', codedWidth: 32, codedHeight: 16, timestamp: 0,
    }));
    out.fromBufferNoFormat = sync(() => new VideoFrame(new Uint8Array(16), { codedWidth: 2, codedHeight: 2, timestamp: 0 }));
    out.fromBufferBadFormat = sync(() => new VideoFrame(new Uint8Array(16), { format: 'nope', codedWidth: 2, codedHeight: 2, timestamp: 0 }));
    return out;
  })();

  entry.EncodedVideoChunk = (() => {
    const c = new EncodedVideoChunk({ type: 'key', timestamp: 7, data: new Uint8Array([1, 2, 3]) });
    return {
      chunk: dump(c),
      copyTo: (() => { try { const b = new Uint8Array(c.byteLength); c.copyTo(b); return Array.from(b); } catch (e) { return `${e.name}: ${e.message}`; } })(),
      withDuration: dump(new EncodedVideoChunk({ type: 'delta', timestamp: 1, duration: 5, data: new Uint8Array(1) })),
      noArg: sync(() => new EncodedVideoChunk()),
      empty: sync(() => new EncodedVideoChunk({})),
      noType: sync(() => new EncodedVideoChunk({ timestamp: 0, data: new Uint8Array(1) })),
      badType: sync(() => new EncodedVideoChunk({ type: 'nope', timestamp: 0, data: new Uint8Array(1) })),
      noTimestamp: sync(() => new EncodedVideoChunk({ type: 'key', data: new Uint8Array(1) })),
      noData: sync(() => new EncodedVideoChunk({ type: 'key', timestamp: 0 })),
      badData: sync(() => new EncodedVideoChunk({ type: 'key', timestamp: 0, data: 5 })),
    };
  })();

  entry.EncodedAudioChunk = (() => {
    const c = new EncodedAudioChunk({ type: 'key', timestamp: 7, data: new Uint8Array([1, 2, 3]) });
    return {
      chunk: dump(c),
      noArg: sync(() => new EncodedAudioChunk()),
      empty: sync(() => new EncodedAudioChunk({})),
      badType: sync(() => new EncodedAudioChunk({ type: 'nope', timestamp: 0, data: new Uint8Array(1) })),
    };
  })();

  entry.AudioData = (() => {
    const make = (extra) => new AudioData(Object.assign({
      format: 'f32', sampleRate: 48000, numberOfFrames: 100, numberOfChannels: 2,
      timestamp: 0, data: new Float32Array(200),
    }, extra));
    const d = (() => { try { return make({}); } catch (e) { return null; } })();
    return {
      data: d ? dump(d) : 'THREW',
      allocationSize: d ? sync(() => d.allocationSize({ planeIndex: 0 })) : 'n/a',
      allocationSizeValue: d ? (() => { try { return d.allocationSize({ planeIndex: 0 }); } catch (e) { return `${e.name}: ${e.message}`; } })() : 'n/a',
      cloned: d ? (() => { try { const c = d.clone(); const r = dump(c); c.close(); return r; } catch (e) { return `${e.name}: ${e.message}`; } })() : 'n/a',
      afterClose: d ? (() => { d.close(); return { format: String(d.format), sampleRate: d.sampleRate, numberOfFrames: d.numberOfFrames }; })() : 'n/a',
      noArg: sync(() => new AudioData()),
      empty: sync(() => new AudioData({})),
      badFormat: sync(() => make({ format: 'nope' })),
      noData: sync(() => new AudioData({ format: 'f32', sampleRate: 48000, numberOfFrames: 1, numberOfChannels: 1, timestamp: 0 })),
    };
  })();

  const codecEntry = async (Ctor, name, config) => {
    const out = { statics: Object.getOwnPropertyNames(Ctor).filter((k) => !['length', 'name', 'prototype'].includes(k)) };
    out.isConfigSupported = await (async () => {
      try { const r = await Ctor.isConfigSupported(config); return { brand: brand(r), keys: Object.getOwnPropertyNames(r), json: JSON.parse(JSON.stringify(r)) }; }
      catch (e) { return `${e.name}: ${e.message}`; }
    })();
    out.isConfigSupportedNoArg = await (async () => {
      try { return `resolved ${brand(await Ctor.isConfigSupported())}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    out.isConfigSupportedEmpty = await (async () => {
      try { return `resolved ${JSON.stringify(await Ctor.isConfigSupported({}))}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    out.isConfigSupportedBogusCodec = await (async () => {
      try { return `resolved ${JSON.stringify(await Ctor.isConfigSupported(Object.assign({}, config, { codec: 'nope' })))}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();

    const instance = (() => { try { return new Ctor({ output() {}, error() {} }); } catch (e) { return `${e.name}: ${e.message}`; } })();
    if (typeof instance === 'string') { out.instance = instance; return out; }
    out.instance = dump(instance);
    out.configure = sync(() => instance.configure(config));
    out.afterConfigure = { state: instance.state, queue: instance.decodeQueueSize ?? instance.encodeQueueSize };
    out.configureEmpty = sync(() => instance.configure({}));
    out.configureBogus = sync(() => instance.configure(Object.assign({}, config, { codec: 'nope' })));
    out.reset = sync(() => instance.reset());
    out.stateAfterReset = instance.state;
    out.close = sync(() => instance.close());
    out.stateAfterClose = instance.state;
    out.configureAfterClose = sync(() => instance.configure(config));
    out.ctorNoArg = sync(() => new Ctor());
    out.ctorEmpty = sync(() => new Ctor({}));
    out.ctorNoError = sync(() => new Ctor({ output() {} }));
    out.ctorBadOutput = sync(() => new Ctor({ output: 5, error() {} }));
    return out;
  };

  entry.VideoDecoder = await codecEntry(VideoDecoder, 'VideoDecoder', { codec: 'vp8', codedWidth: 320, codedHeight: 240 });
  entry.VideoEncoder = await codecEntry(VideoEncoder, 'VideoEncoder', { codec: 'vp8', width: 320, height: 240, bitrate: 1000000, framerate: 30 });
  entry.AudioDecoder = await codecEntry(AudioDecoder, 'AudioDecoder', { codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
  entry.AudioEncoder = await codecEntry(AudioEncoder, 'AudioEncoder', { codec: 'opus', sampleRate: 48000, numberOfChannels: 2, bitrate: 128000 });

  entry.ImageDecoder = await (async () => {
    const out = { statics: Object.getOwnPropertyNames(ImageDecoder).filter((k) => !['length', 'name', 'prototype'].includes(k)) };
    out.isTypeSupported = await (async () => {
      const r = {};
      for (const t of ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml', 'nope']) {
        try { r[t] = await ImageDecoder.isTypeSupported(t); } catch (e) { r[t] = `${e.name}: ${e.message}`; }
      }
      return r;
    })();
    out.isTypeSupportedNoArg = await (async () => {
      try { return `resolved ${await ImageDecoder.isTypeSupported()}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();

    // A 1x1 PNG, so the tracks and the decode are real.
    const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0));
    const dec = (() => { try { return new ImageDecoder({ data: png, type: 'image/png' }); } catch (e) { return `${e.name}: ${e.message}`; } })();
    if (typeof dec === 'string') { out.instance = dec; return out; }
    out.instance = dump(dec);
    out.completed = await (async () => { try { await dec.completed; return 'resolved'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    out.tracks = (() => {
      const t = dec.tracks;
      const r = { brand: brand(t), length: t.length, selectedIndex: t.selectedIndex, ready: brand(t.ready), own: Object.getOwnPropertyNames(t).join(',') };
      r.byIndex = t.length ? dump(t[0]) : 'none';
      r.isArray = Array.isArray(t);
      r.iterable = typeof t[Symbol.iterator] === 'function';
      return r;
    })();
    out.decoded = await (async () => {
      try {
        const r = await dec.decode();
        return { brand: brand(r), keys: Object.getOwnPropertyNames(r), complete: r.complete, image: dump(r.image) };
      } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    out.decodeBadIndex = await (async () => {
      try { return `resolved ${brand(await dec.decode({ frameIndex: 99 }))}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    out.reset = sync(() => dec.reset());
    out.close = sync(() => dec.close());
    out.afterClose = { complete: sync(() => dec.complete), decode: await dec.decode().then(() => 'resolved', (e) => `${e.name}: ${e.message}`) };
    out.ctorNoArg = sync(() => new ImageDecoder());
    out.ctorEmpty = sync(() => new ImageDecoder({}));
    out.ctorNoType = sync(() => new ImageDecoder({ data: png }));
    out.ctorNoData = sync(() => new ImageDecoder({ type: 'image/png' }));
    out.ctorBogusType = sync(() => new ImageDecoder({ data: png, type: 'nope' }));
    return out;
  })();

  return { shapes, entry };
})()
