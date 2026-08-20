(async () => {
  // Batch 16 P5: the pipeline / encoder half of WebGPU. probe-win37.js already
  // recorded the shapes of these twelve interfaces; what is missing is what the
  // calls that build them actually hand back, and how they refuse.
  //
  // Same two helpers as probe-win39.js: `dump` reads every getter on the whole
  // prototype chain so the record is the observable surface rather than a list
  // I guessed, and `scoped` runs a call inside a validation error scope so an
  // asynchronous failure is attributable to it.
  const out = {};
  const brand = (v) => { try { return Object.prototype.toString.call(v); } catch (e) { return `ERR ${e.name}`; } };
  const dev = await (await navigator.gpu.requestAdapter()).requestDevice();

  const dump = (o) => {
    if (o === null || o === undefined || typeof o !== 'object') return { primitive: String(o) };
    const r = { brand: brand(o) };
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

  const scoped = async (fn) => {
    dev.pushErrorScope('validation');
    let threw = null;
    let value;
    try { value = await fn(); } catch (e) { threw = `${e.name}: ${e.message}`; }
    const err = await dev.popErrorScope();
    return { threw, err: err ? { brand: brand(err), message: err.message } : null, value };
  };

  const record = async (name, fn) => {
    const r = await scoped(fn);
    out[name] = { threw: r.threw, err: r.err, value: r.threw ? undefined : dump(r.value) };
  };

  const COMPUTE_WGSL = '@compute @workgroup_size(1) fn main() {}';
  const RENDER_WGSL = `
@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0, 0.0, 0.0, 1.0); }
@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }`;

  // ---- GPUShaderModule / GPUCompilationInfo / GPUCompilationMessage --------
  await record('shader_minimal', () => dev.createShaderModule({ code: COMPUTE_WGSL }));
  await record('shader_labelled', () => dev.createShaderModule({ code: COMPUTE_WGSL, label: 'sm' }));
  await record('shader_no_arg', () => dev.createShaderModule());
  await record('shader_empty_descriptor', () => dev.createShaderModule({}));
  await record('shader_undefined_descriptor', () => dev.createShaderModule(undefined));
  await record('shader_code_number', () => dev.createShaderModule({ code: 5 }));
  await record('shader_empty_code', () => dev.createShaderModule({ code: '' }));

  const infoOf = async (code) => {
    const info = await dev.createShaderModule({ code }).getCompilationInfo();
    return {
      brand: brand(info),
      messagesBrand: brand(info.messages),
      isArray: Array.isArray(info.messages),
      frozen: Object.isFrozen(info.messages),
      length: info.messages.length,
      sameOnReread: info.messages === info.messages,
      messages: Array.from(info.messages, (m) => dump(m)),
    };
  };
  out.compilation_info_ok = await infoOf(COMPUTE_WGSL).catch((e) => `${e.name}: ${e.message}`);
  out.compilation_info_bad = await infoOf('@compute fn main( {}').catch((e) => `${e.name}: ${e.message}`);
  out.compilation_info_warning = await infoOf('@compute @workgroup_size(1) fn main() { if false { } }').catch((e) => `${e.name}: ${e.message}`);
  out.compilation_info_identity = await (async () => {
    const m = dev.createShaderModule({ code: COMPUTE_WGSL });
    const [a, b] = await Promise.all([m.getCompilationInfo(), m.getCompilationInfo()]);
    return { same: a === b, sameMessages: a.messages === b.messages };
  })();

  // ---- GPUComputePipeline / GPURenderPipeline ------------------------------
  const computeModule = dev.createShaderModule({ code: COMPUTE_WGSL });
  const renderModule = dev.createShaderModule({ code: RENDER_WGSL });

  await record('compute_pipeline', () => dev.createComputePipeline({ layout: 'auto', compute: { module: computeModule } }));
  await record('compute_pipeline_labelled', () => dev.createComputePipeline({ layout: 'auto', compute: { module: computeModule, entryPoint: 'main' }, label: 'cp' }));
  await record('compute_pipeline_no_arg', () => dev.createComputePipeline());
  await record('compute_pipeline_empty', () => dev.createComputePipeline({}));
  await record('compute_pipeline_no_layout', () => dev.createComputePipeline({ compute: { module: computeModule } }));
  await record('compute_pipeline_no_compute', () => dev.createComputePipeline({ layout: 'auto' }));
  await record('compute_pipeline_compute_no_module', () => dev.createComputePipeline({ layout: 'auto', compute: {} }));
  await record('compute_pipeline_module_number', () => dev.createComputePipeline({ layout: 'auto', compute: { module: 5 } }));
  await record('compute_pipeline_layout_bogus', () => dev.createComputePipeline({ layout: 'nope', compute: { module: computeModule } }));

  out.compute_pipeline_bind_group_layout = await (async () => {
    const p = dev.createComputePipeline({ layout: 'auto', compute: { module: computeModule } });
    const zero = (() => { try { return dump(p.getBindGroupLayout(0)); } catch (e) { return `${e.name}: ${e.message}`; } })();
    const same = (() => { try { return p.getBindGroupLayout(0) === p.getBindGroupLayout(0); } catch { return 'threw'; } })();
    const noArg = (() => { try { return brand(p.getBindGroupLayout()); } catch (e) { return `${e.name}: ${e.message}`; } })();
    dev.pushErrorScope('validation');
    let outOfRange;
    try { outOfRange = brand(p.getBindGroupLayout(9)); } catch (e) { outOfRange = `${e.name}: ${e.message}`; }
    const err = await dev.popErrorScope();
    return { zero, same, noArg, outOfRange, outOfRangeScoped: err ? err.message : null };
  })();

  await record('compute_pipeline_async', () => dev.createComputePipelineAsync({ layout: 'auto', compute: { module: computeModule } }));
  out.compute_pipeline_async_is_promise = (() => {
    const p = dev.createComputePipelineAsync({ layout: 'auto', compute: { module: computeModule } });
    return { brand: brand(p), isPromise: p instanceof Promise };
  })();
  out.compute_pipeline_async_reject = await dev.createComputePipelineAsync({ layout: 'auto', compute: { module: dev.createShaderModule({ code: 'fn nope() {}' }) } })
    .then((v) => `resolved ${brand(v)}`, (e) => ({ brand: brand(e), name: e.name, message: e.message, reason: e.reason, isDomException: e instanceof DOMException }));

  const RENDER_DESC = {
    layout: 'auto',
    vertex: { module: renderModule },
    fragment: { module: renderModule, targets: [{ format: 'bgra8unorm' }] },
  };
  await record('render_pipeline', () => dev.createRenderPipeline(RENDER_DESC));
  await record('render_pipeline_labelled', () => dev.createRenderPipeline({ ...RENDER_DESC, label: 'rp' }));
  await record('render_pipeline_vertex_only', () => dev.createRenderPipeline({ layout: 'auto', vertex: { module: renderModule } }));
  await record('render_pipeline_no_arg', () => dev.createRenderPipeline());
  await record('render_pipeline_empty', () => dev.createRenderPipeline({}));
  await record('render_pipeline_no_vertex', () => dev.createRenderPipeline({ layout: 'auto' }));
  await record('render_pipeline_no_layout', () => dev.createRenderPipeline({ vertex: { module: renderModule } }));
  await record('render_pipeline_vertex_no_module', () => dev.createRenderPipeline({ layout: 'auto', vertex: {} }));
  await record('render_pipeline_fragment_no_targets', () => dev.createRenderPipeline({ layout: 'auto', vertex: { module: renderModule }, fragment: { module: renderModule } }));
  await record('render_pipeline_async', () => dev.createRenderPipelineAsync(RENDER_DESC));

  out.render_pipeline_bind_group_layout = (() => {
    const p = dev.createRenderPipeline(RENDER_DESC);
    try { return { zero: dump(p.getBindGroupLayout(0)), same: p.getBindGroupLayout(0) === p.getBindGroupLayout(0) }; }
    catch (e) { return `${e.name}: ${e.message}`; }
  })();

  // ---- GPUCommandEncoder / GPUCommandBuffer / the pass encoders -----------
  await record('command_encoder', () => dev.createCommandEncoder());
  await record('command_encoder_labelled', () => dev.createCommandEncoder({ label: 'ce' }));
  await record('command_encoder_undefined', () => dev.createCommandEncoder(undefined));
  await record('command_encoder_string', () => dev.createCommandEncoder('nope'));
  await record('command_buffer', () => dev.createCommandEncoder({ label: 'ce' }).finish());
  await record('command_buffer_labelled', () => dev.createCommandEncoder().finish({ label: 'cb' }));

  await record('compute_pass', () => dev.createCommandEncoder().beginComputePass());
  await record('compute_pass_labelled', () => dev.createCommandEncoder().beginComputePass({ label: 'pass' }));
  await record('render_pass_no_arg', () => dev.createCommandEncoder().beginRenderPass());
  await record('render_pass_empty', () => dev.createCommandEncoder().beginRenderPass({}));

  const attachment = () => dev
    .createTexture({ size: [8, 8], format: 'bgra8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT })
    .createView();
  await record('render_pass', () => dev.createCommandEncoder().beginRenderPass({
    colorAttachments: [{ view: attachment(), loadOp: 'clear', storeOp: 'store' }],
  }));
  await record('render_pass_labelled', () => dev.createCommandEncoder().beginRenderPass({
    label: 'rpass',
    colorAttachments: [{ view: attachment(), loadOp: 'clear', storeOp: 'store' }],
  }));
  await record('render_pass_attachment_no_view', () => dev.createCommandEncoder().beginRenderPass({
    colorAttachments: [{ loadOp: 'clear', storeOp: 'store' }],
  }));

  // The whole encode-and-submit round trip, to see whether any of it throws.
  out.round_trip = await (async () => {
    try {
      const enc = dev.createCommandEncoder();
      const pass = enc.beginComputePass();
      pass.setPipeline(dev.createComputePipeline({ layout: 'auto', compute: { module: computeModule } }));
      pass.dispatchWorkgroups(1);
      pass.end();
      const buf = enc.finish();
      dev.queue.submit([buf]);
      await dev.queue.onSubmittedWorkDone();
      return { ok: true, buffer: brand(buf) };
    } catch (e) { return `${e.name}: ${e.message}`; }
  })();

  // Encoder state: what a second finish(), or a call after finish(), does.
  out.encoder_state = await (async () => {
    const enc = dev.createCommandEncoder();
    const first = brand(enc.finish());
    dev.pushErrorScope('validation');
    let second;
    try { second = brand(enc.finish()); } catch (e) { second = `${e.name}: ${e.message}`; }
    const err = await dev.popErrorScope();
    return { first, second, secondScoped: err ? err.message : null };
  })();

  // ---- GPURenderBundleEncoder / GPURenderBundle ---------------------------
  await record('render_bundle_encoder', () => dev.createRenderBundleEncoder({ colorFormats: ['bgra8unorm'] }));
  await record('render_bundle_encoder_labelled', () => dev.createRenderBundleEncoder({ colorFormats: ['bgra8unorm'], label: 'rbe' }));
  await record('render_bundle_encoder_no_arg', () => dev.createRenderBundleEncoder());
  await record('render_bundle_encoder_empty', () => dev.createRenderBundleEncoder({}));
  await record('render_bundle', () => dev.createRenderBundleEncoder({ colorFormats: ['bgra8unorm'] }).finish());
  await record('render_bundle_labelled', () => dev.createRenderBundleEncoder({ colorFormats: ['bgra8unorm'] }).finish({ label: 'rb' }));

  // ---- GPUCanvasContext ---------------------------------------------------
  out.canvas = await (async () => {
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('webgpu');
    const r = {
      brand: brand(ctx),
      sameOnReread: ctx === canvas.getContext('webgpu'),
      canvasIdentity: ctx.canvas === canvas,
      canvasBrand: brand(ctx.canvas),
      before: dump(ctx),
      configurationBefore: (() => { const c = ctx.getConfiguration(); return c === null ? 'null' : dump(c); })(),
      currentTextureBefore: (() => { try { return dump(ctx.getCurrentTexture()); } catch (e) { return `${e.name}: ${e.message}`; } })(),
      preferredFormat: navigator.gpu.getPreferredCanvasFormat(),
      // A canvas that already has a webgpu context: what other context types do.
      then2d: String(canvas.getContext('2d')),
      thenWebgl: String(canvas.getContext('webgl')),
    };
    r.configureNoArg = (() => { try { ctx.configure(); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.configureEmpty = (() => { try { ctx.configure({}); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.configureNoFormat = (() => { try { ctx.configure({ device: dev }); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.configureNoDevice = (() => { try { ctx.configure({ format: 'bgra8unorm' }); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.configureBadFormat = (() => { try { ctx.configure({ device: dev, format: 'nope' }); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();

    dev.pushErrorScope('validation');
    try { ctx.configure({ device: dev, format: navigator.gpu.getPreferredCanvasFormat() }); r.configure = 'ok'; }
    catch (e) { r.configure = `${e.name}: ${e.message}`; }
    const err = await dev.popErrorScope();
    r.configureScoped = err ? err.message : null;

    r.configurationAfter = (() => { const c = ctx.getConfiguration(); return c === null ? 'null' : { keys: Object.keys(c), json: JSON.parse(JSON.stringify({ ...c, device: undefined })), deviceIsDevice: c.device === dev }; })();
    r.currentTexture = (() => { try { return dump(ctx.getCurrentTexture()); } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.currentTextureSame = (() => { try { return ctx.getCurrentTexture() === ctx.getCurrentTexture(); } catch { return 'threw'; } })();
    r.unconfigure = (() => { try { ctx.unconfigure(); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    r.configurationAfterUnconfigure = (() => { const c = ctx.getConfiguration(); return c === null ? 'null' : Object.keys(c); })();
    r.currentTextureAfterUnconfigure = (() => { try { return brand(ctx.getCurrentTexture()); } catch (e) { return `${e.name}: ${e.message}`; } })();

    // A sized canvas, to see whether the texture follows width/height.
    const big = document.createElement('canvas');
    big.width = 64; big.height = 32;
    const bigCtx = big.getContext('webgpu');
    bigCtx.configure({ device: dev, format: navigator.gpu.getPreferredCanvasFormat() });
    r.sizedTexture = dump(bigCtx.getCurrentTexture());
    r.sizedConfiguration = (() => { const c = bigCtx.getConfiguration(); return c === null ? 'null' : JSON.parse(JSON.stringify({ ...c, device: undefined })); })();

    // getContext on an offscreen canvas, for completeness.
    r.offscreen = (() => {
      try { return brand(new OffscreenCanvas(8, 8).getContext('webgpu')); } catch (e) { return `${e.name}: ${e.message}`; }
    })();
    return r;
  })();

  return out;
})()
