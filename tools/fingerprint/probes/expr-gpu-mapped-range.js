// What comes back out of a mapped GPUBuffer?
//
// B60 traced the one structural gap in the Cloudflare widget's payload to this:
// the widget runs a whole WebGPU pipeline and encodes a 4096-byte segment from
// the buffer it reads back, where this engine encodes nothing at all, because
// `getMappedRange()` returns undefined. The refusal on an unmapped buffer was
// already reproduced; the buffer itself was not.
(async () => {
    const out = {};
    if (!navigator.gpu) return { gpu: 'absent' };
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return { adapter: 'null' };
    const device = await adapter.requestDevice();

    const READ = GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST;
    const b = device.createBuffer({ size: 4096, usage: READ });
    out.freshMapState = b.mapState;
    try {
        b.getMappedRange();
        out.unmappedGetRange = 'returned';
    } catch (e) {
        out.unmappedGetRange = e.name + ': ' + e.message;
    }

    await b.mapAsync(GPUMapMode.READ);
    out.mappedMapState = b.mapState;
    const range = b.getMappedRange();
    out.rangeType = Object.prototype.toString.call(range);
    out.rangeLength = range && range.byteLength;
    out.rangeAllZero = !!range && new Uint8Array(range).every((v) => v === 0);
    out.rangeIsShared = !!range && ('growable' in range);

    // A second call over the same range is refused.
    try {
        b.getMappedRange();
        out.secondCall = 'returned';
    } catch (e) {
        out.secondCall = e.name;
    }

    // With an offset and a size.
    const c = device.createBuffer({ size: 4096, usage: READ });
    await c.mapAsync(GPUMapMode.READ);
    const part = c.getMappedRange(256, 512);
    out.partLength = part && part.byteLength;
    // Offset alone takes the rest of the buffer.
    const d = device.createBuffer({ size: 4096, usage: READ });
    await d.mapAsync(GPUMapMode.READ);
    out.offsetOnlyLength = d.getMappedRange(1024).byteLength;

    // unmap() detaches whatever was handed out.
    b.unmap();
    out.afterUnmapLength = range.byteLength;
    out.afterUnmapMapState = b.mapState;

    // mappedAtCreation hands out a writable range without any mapAsync.
    const e = device.createBuffer({
        size: 64,
        usage: GPUBufferUsage.COPY_SRC,
        mappedAtCreation: true,
    });
    out.atCreationMapState = e.mapState;
    const w = e.getMappedRange();
    out.atCreationLength = w && w.byteLength;
    if (w) {
        new Uint8Array(w)[0] = 7;
        out.atCreationWrote = new Uint8Array(w)[0];
    }

    return out;
})()
