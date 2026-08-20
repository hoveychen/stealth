(async () => {
  // Batch 16 sweep: the WebGPU family. Same shape dump as probe-win28.js for the
  // 41 GPU*/WGSL* globals, plus the navigator.gpu entry point and — if this
  // machine's Chrome really has a working adapter — the reachable adapter/device
  // values (features set, every numeric limit, adapterInfo strings).
  const NAMES = ['GPU', 'GPUAdapter', 'GPUAdapterInfo', 'GPUBindGroup', 'GPUBindGroupLayout', 'GPUBuffer', 'GPUBufferUsage', 'GPUCanvasContext', 'GPUColorWrite', 'GPUCommandBuffer', 'GPUCommandEncoder', 'GPUCompilationInfo', 'GPUCompilationMessage', 'GPUComputePassEncoder', 'GPUComputePipeline', 'GPUDevice', 'GPUDeviceLostInfo', 'GPUError', 'GPUExternalTexture', 'GPUInternalError', 'GPUMapMode', 'GPUOutOfMemoryError', 'GPUPipelineError', 'GPUPipelineLayout', 'GPUQuerySet', 'GPUQueue', 'GPURenderBundle', 'GPURenderBundleEncoder', 'GPURenderPassEncoder', 'GPURenderPipeline', 'GPUSampler', 'GPUShaderModule', 'GPUShaderStage', 'GPUSupportedFeatures', 'GPUSupportedLimits', 'GPUTexture', 'GPUTextureUsage', 'GPUTextureView', 'GPUUncapturedErrorEvent', 'GPUValidationError', 'WGSLLanguageFeatures'];

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
      rec.protoDescOfCtor = (() => { const d = Object.getOwnPropertyDescriptor(v, 'prototype'); return flags(d); })();
    } else {
      rec.protoOwn = 'NO-PROTOTYPE';
    }
    rec.newNoArg = (() => {
      try {
        const i = new v();
        return { ok: true, brand: Object.prototype.toString.call(i), own: Object.getOwnPropertyNames(i).join(','), str: String(i).slice(0, 60) };
      } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    rec.callNoNew = (() => {
      try { const r = v(); return `ok: ${String(r).slice(0, 40)}`; } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    shapes[name] = rec;
  }

  // ---- navigator.gpu entry point -------------------------------------------
  const entry = {};
  const navProto = Object.getPrototypeOf(navigator);
  const gd = Object.getOwnPropertyDescriptor(navProto, 'gpu');
  entry.navigatorProtoDesc = gd ? `${kind(gd)}[${flags(gd)}]` : (Object.prototype.hasOwnProperty.call(navigator, 'gpu') ? 'OWN-ON-INSTANCE' : 'MISSING');
  entry.navGpuBrand = (() => { try { return Object.prototype.toString.call(navigator.gpu); } catch (e) { return `ERR ${e.name}`; } })();
  entry.navGpuStr = (() => { try { return String(navigator.gpu); } catch (e) { return `ERR ${e.name}`; } })();
  entry.navGpuSameEachRead = (() => { try { return navigator.gpu === navigator.gpu; } catch (e) { return `ERR ${e.name}`; } })();
  entry.navGpuOwn = (() => { try { return Object.getOwnPropertyNames(navigator.gpu).join(','); } catch (e) { return `ERR ${e.name}`; } })();
  entry.preferredCanvasFormat = (() => { try { return navigator.gpu.getPreferredCanvasFormat(); } catch (e) { return `${e.name}: ${e.message}`; } })();
  entry.wgslLanguageFeatures = (() => {
    try {
      const f = navigator.gpu.wgslLanguageFeatures;
      return { brand: Object.prototype.toString.call(f), size: f.size, values: [...f].sort() };
    } catch (e) { return `${e.name}: ${e.message}`; }
  })();

  const dumpLimits = (l) => {
    const out = {};
    if (!l) return 'null';
    for (const k of Object.getOwnPropertyNames(Object.getPrototypeOf(l))) {
      if (k === 'constructor') continue;
      try { out[k] = l[k]; } catch (e) { out[k] = `ERR ${e.name}`; }
    }
    return out;
  };

  let adapter = null;
  try {
    adapter = await navigator.gpu.requestAdapter();
    entry.requestAdapter = adapter === null ? 'null' : 'ok';
  } catch (e) { entry.requestAdapter = `${e.name}: ${e.message}`; }

  if (adapter) {
    entry.adapter = {
      brand: Object.prototype.toString.call(adapter),
      own: Object.getOwnPropertyNames(adapter).join(','),
      features: [...adapter.features].sort(),
      featuresBrand: Object.prototype.toString.call(adapter.features),
      featuresSize: adapter.features.size,
      limits: dumpLimits(adapter.limits),
      limitsBrand: Object.prototype.toString.call(adapter.limits),
      isFallbackAdapter: (() => { try { return adapter.isFallbackAdapter; } catch (e) { return `ERR ${e.name}`; } })(),
      info: (() => {
        try {
          const i = adapter.info;
          if (!i) return 'null';
          const o = { brand: Object.prototype.toString.call(i) };
          for (const k of Object.getOwnPropertyNames(Object.getPrototypeOf(i))) {
            if (k === 'constructor') continue;
            try { o[k] = i[k]; } catch (e) { o[k] = `ERR ${e.name}`; }
          }
          return o;
        } catch (e) { return `${e.name}: ${e.message}`; }
      })(),
      requestAdapterInfo: (() => { try { return typeof adapter.requestAdapterInfo; } catch (e) { return `ERR ${e.name}`; } })(),
    };

    try {
      const dev = await adapter.requestDevice();
      entry.device = {
        brand: Object.prototype.toString.call(dev),
        label: dev.label,
        features: [...dev.features].sort(),
        limits: dumpLimits(dev.limits),
        queueBrand: Object.prototype.toString.call(dev.queue),
        queueLabel: dev.queue.label,
        adapterInfoOnDevice: (() => { try { return dev.adapterInfo ? Object.prototype.toString.call(dev.adapterInfo) : String(dev.adapterInfo); } catch (e) { return `ERR ${e.name}`; } })(),
        lostBrand: (() => { try { return Object.prototype.toString.call(dev.lost); } catch (e) { return `ERR ${e.name}`; } })(),
      };
      // A tiny real pipeline, to see what the reachable objects look like.
      try {
        const buf = dev.createBuffer({ size: 16, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC });
        entry.buffer = { brand: Object.prototype.toString.call(buf), label: buf.label, size: buf.size, usage: buf.usage, mapState: buf.mapState };
        buf.destroy();
      } catch (e) { entry.buffer = `${e.name}: ${e.message}`; }
      try {
        const sm = dev.createShaderModule({ code: '@compute @workgroup_size(1) fn main() {}' });
        const ci = await sm.getCompilationInfo();
        entry.shaderModule = { brand: Object.prototype.toString.call(sm), label: sm.label, ciBrand: Object.prototype.toString.call(ci), msgCount: ci.messages.length };
      } catch (e) { entry.shaderModule = `${e.name}: ${e.message}`; }
      try {
        const enc = dev.createCommandEncoder();
        const cb = enc.finish();
        entry.encoder = { encBrand: Object.prototype.toString.call(enc), cbBrand: Object.prototype.toString.call(cb), encLabel: enc.label };
      } catch (e) { entry.encoder = `${e.name}: ${e.message}`; }
      try {
        dev.pushErrorScope('validation');
        dev.createBuffer({ size: 0, usage: 0 });
        const err = await dev.popErrorScope();
        entry.errorScope = err === null ? 'null' : { brand: Object.prototype.toString.call(err), message: String(err.message).slice(0, 120) };
      } catch (e) { entry.errorScope = `${e.name}: ${e.message}`; }
      try {
        const cv = document.createElement('canvas');
        const ctx = cv.getContext('webgpu');
        entry.canvasContext = ctx === null ? 'null' : { brand: Object.prototype.toString.call(ctx), canvasSame: ctx.canvas === cv };
      } catch (e) { entry.canvasContext = `${e.name}: ${e.message}`; }
      dev.destroy();
    } catch (e) { entry.device = `${e.name}: ${e.message}`; }
  }

  // requestAdapter argument handling
  entry.requestAdapterBadArg = await (async () => {
    try { const a = await navigator.gpu.requestAdapter('nope'); return a === null ? 'null' : 'ok'; } catch (e) { return `${e.name}: ${e.message}`; }
  })();
  entry.requestAdapterForceFallback = await (async () => {
    try { const a = await navigator.gpu.requestAdapter({ forceFallbackAdapter: true }); return a === null ? 'null' : 'ok'; } catch (e) { return `${e.name}: ${e.message}`; }
  })();

  return { shapes, entry };
})()
