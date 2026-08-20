(async () => {
  // Batch 16 P4: what device.create*() actually hands back, and which
  // descriptor members are required. WebGPU validation is mostly *asynchronous*
  // (it lands in an error scope rather than throwing), so this records both:
  // whether the call threw, and what popErrorScope caught.
  const out = {};
  const brand = (v) => { try { return Object.prototype.toString.call(v); } catch (e) { return `ERR ${e.name}`; } };
  const dev = await (await navigator.gpu.requestAdapter()).requestDevice();

  // Reads every own getter off the prototype chain, so the record is the whole
  // observable surface rather than a list I guessed.
  const dump = (o) => {
    const out = { brand: brand(o) };
    for (let p = Object.getPrototypeOf(o); p && p !== Object.prototype; p = Object.getPrototypeOf(p)) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (k === 'constructor') continue;
        const d = Object.getOwnPropertyDescriptor(p, k);
        if (!d.get) continue;
        try { out[k] = o[k]; } catch (e) { out[k] = `ERR ${e.name}: ${e.message}`; }
      }
    }
    return out;
  };

  // `scoped` runs fn inside a validation error scope so an async failure is
  // attributable to it.
  const scoped = async (fn) => {
    dev.pushErrorScope('validation');
    let threw = null;
    let value;
    try { value = fn(); } catch (e) { threw = `${e.name}: ${e.message}`; }
    const err = await dev.popErrorScope();
    return { threw, err: err ? { brand: brand(err), message: err.message } : null, value };
  };

  const record = async (name, fn) => {
    const r = await scoped(fn);
    out[name] = { threw: r.threw, err: r.err, value: r.threw ? undefined : dump(r.value) };
  };

  await record('buffer_minimal', () => dev.createBuffer({ size: 16, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC }));
  await record('buffer_labelled', () => dev.createBuffer({ size: 4, usage: GPUBufferUsage.MAP_READ, label: 'buf' }));
  await record('buffer_mapped_at_creation', () => dev.createBuffer({ size: 4, usage: GPUBufferUsage.MAP_WRITE, mappedAtCreation: true }));
  await record('buffer_no_size', () => dev.createBuffer({ usage: GPUBufferUsage.COPY_DST }));
  await record('buffer_no_usage', () => dev.createBuffer({ size: 4 }));
  await record('buffer_no_descriptor', () => dev.createBuffer());
  await record('buffer_usage_zero', () => dev.createBuffer({ size: 4, usage: 0 }));

  await record('texture_array_size', () => dev.createTexture({ size: [8, 4], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING }));
  await record('texture_dict_size', () => dev.createTexture({ size: { width: 8, height: 4, depthOrArrayLayers: 2 }, format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING }));
  await record('texture_width_only', () => dev.createTexture({ size: [8], format: 'r8unorm', usage: GPUTextureUsage.COPY_DST }));
  await record('texture_3d', () => dev.createTexture({ size: [8, 8, 4], dimension: '3d', format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING }));
  await record('texture_mips', () => dev.createTexture({ size: [8, 8], mipLevelCount: 3, format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING, label: 'tex' }));
  await record('texture_no_format', () => dev.createTexture({ size: [8, 8], usage: GPUTextureUsage.COPY_DST }));
  await record('texture_no_size', () => dev.createTexture({ format: 'rgba8unorm', usage: GPUTextureUsage.COPY_DST }));
  await record('texture_no_usage', () => dev.createTexture({ size: [8, 8], format: 'rgba8unorm' }));
  await record('texture_bad_format', () => dev.createTexture({ size: [8, 8], format: 'nope', usage: GPUTextureUsage.COPY_DST }));

  await record('view_default', () => dev.createTexture({ size: [8, 8], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING }).createView());
  await record('view_labelled', () => dev.createTexture({ size: [8, 8], format: 'rgba8unorm', usage: GPUTextureUsage.TEXTURE_BINDING }).createView({ label: 'v' }));

  await record('sampler_default', () => dev.createSampler());
  await record('sampler_labelled', () => dev.createSampler({ label: 's' }));

  await record('queryset', () => dev.createQuerySet({ type: 'occlusion', count: 4 }));
  await record('queryset_labelled', () => dev.createQuerySet({ type: 'occlusion', count: 2, label: 'q' }));
  await record('queryset_no_type', () => dev.createQuerySet({ count: 2 }));
  await record('queryset_no_count', () => dev.createQuerySet({ type: 'occlusion' }));
  await record('queryset_bad_type', () => dev.createQuerySet({ type: 'nope', count: 2 }));

  await record('bind_group_layout_empty', () => dev.createBindGroupLayout({ entries: [] }));
  await record('bind_group_layout_no_entries', () => dev.createBindGroupLayout({}));
  await record('pipeline_layout_empty', () => dev.createPipelineLayout({ bindGroupLayouts: [] }));
  await record('pipeline_layout_no_member', () => dev.createPipelineLayout({}));

  await record('bind_group_empty', () => {
    const layout = dev.createBindGroupLayout({ entries: [] });
    return dev.createBindGroup({ layout, entries: [] });
  });
  await record('bind_group_no_layout', () => dev.createBindGroup({ entries: [] }));

  await record('external_texture_no_source', () => dev.importExternalTexture({}));
  await record('external_texture_bad_source', () => dev.importExternalTexture({ source: 5 }));

  // The label round-trips on every one of them.
  out.label_roundtrip = (() => {
    const buf = dev.createBuffer({ size: 4, usage: GPUBufferUsage.COPY_DST });
    buf.label = 'x';
    const sampler = dev.createSampler();
    sampler.label = 'y';
    return { buffer: buf.label, sampler: sampler.label };
  })();

  // pushErrorScope / popErrorScope themselves.
  out.errorScope = {
    popWithoutPush: await dev.popErrorScope().then((v) => (v === null ? 'null' : brand(v)), (e) => `${e.name}: ${e.message}`),
    badFilter: (() => { try { dev.pushErrorScope('nope'); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })(),
    emptyScope: await (async () => { dev.pushErrorScope('validation'); const v = await dev.popErrorScope(); return v === null ? 'null' : brand(v); })(),
    outOfMemoryFilter: (() => { try { dev.pushErrorScope('out-of-memory'); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })(),
    internalFilter: (() => { try { dev.pushErrorScope('internal'); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })(),
  };

  return out;
})()
