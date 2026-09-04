// Dumps the whole graphics API surface out of the real Google Chrome on this
// machine, into results/reference-chrome-graphics.json.
//
//   node tools/fingerprint/dump-graphics.mjs [--headed] [--out <path>]
//
// This is the input the Zig side is transcribed from. probe.js answers "what
// does a fingerprinting script see"; this answers "what exactly should we
// report", down to every GLenum, every method's arity, and every advance width.
// The WebGL spec pins the enum numbering but says nothing about what a driver
// answers for MAX_TEXTURE_SIZE, SAMPLES or the ANGLE renderer string, and those
// are the values that identify a machine — so they get measured, not recalled.
//
// Re-run it when the reference host or its Chrome changes. The values in
// src/browser/webapi/canvas/*.zig should then be regenerated to match, and the
// assertions in src/browser/tests/canvas/*.html updated alongside them.
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Cdp, goto, evaluate, sleep, personaScaleFlags } from './cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const headed = process.argv.includes('--headed');
const outArg = process.argv.indexOf('--out');
const outPath = path.resolve(
    repo,
    outArg !== -1 ? process.argv[outArg + 1] : 'tools/fingerprint/results/reference-chrome-graphics.json',
);
const PORT = 9461;
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// One expression per section, so a section that throws does not cost the rest.
// Every one returns a JSON string: a raw return value containing a function or a
// BigInt makes CDP refuse with "Object couldn't be returned by value".
const SECTIONS = {
    interfaces: `(() => {
  const surface = (name) => {
    const P = window[name];
    if (!P) return null;
    const proto = P.prototype;
    const constants = {}, methods = [], accessors = [];
    for (const k of Object.getOwnPropertyNames(proto)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(proto, k);
      if (d.get || d.set) { accessors.push(k); continue; }
      if (typeof d.value === 'function') { methods.push({ name: k, length: d.value.length }); continue; }
      if (typeof d.value === 'number') { constants[k] = d.value; continue; }
      accessors.push(k);
    }
    return { constants, methods, accessors };
  };
  const out = {};
  for (const n of ['WebGLRenderingContext', 'WebGL2RenderingContext', 'CanvasRenderingContext2D', 'TextMetrics']) {
    out[n] = surface(n);
  }
  // Prototype chains matter: WebGL2RenderingContext does NOT extend
  // WebGLRenderingContext in Chrome, and the handle types DO extend WebGLObject.
  out.chains = {};
  for (const n of Object.getOwnPropertyNames(window).filter((k) => /^WebGL/.test(k)).sort()) {
    const P = window[n];
    if (typeof P !== 'function' || !P.prototype) continue;
    const chain = [];
    for (let p = Object.getPrototypeOf(P.prototype); p; p = Object.getPrototypeOf(p)) {
      chain.push(p.constructor ? p.constructor.name : '?');
    }
    out.chains[n] = { chain, members: Object.getOwnPropertyNames(P.prototype).filter((k) => k !== 'constructor') };
  }
  out.canvasElementMethods = Object.getOwnPropertyNames(HTMLCanvasElement.prototype).filter((k) => k !== 'constructor');
  return JSON.stringify(out);
})()`,

    webglParameters: `(() => {
  const describe = (v) => {
    if (v === null) return { t: 'null' };
    if (Array.isArray(v)) return { t: 'array', v };
    const t = typeof v;
    if (t === 'number' || t === 'string' || t === 'boolean') return { t, v };
    if (v && v.constructor) return { t: v.constructor.name, v: v.length !== undefined ? Array.from(v) : String(v) };
    return { t };
  };
  const sweep = (kind) => {
    const gl = document.createElement('canvas').getContext(kind);
    if (!gl) return null;
    const Iface = kind === 'webgl2' ? WebGL2RenderingContext : WebGLRenderingContext;
    const params = {};
    for (const n of Object.getOwnPropertyNames(Iface.prototype)) {
      const d = Object.getOwnPropertyDescriptor(Iface.prototype, n);
      if (!d || typeof d.value !== 'number') continue;
      try { params[n] = describe(gl.getParameter(gl[n])); } catch { params[n] = { t: 'throw' }; }
    }
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    return {
      getParameter: params,
      unmasked: dbg ? { vendor: gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL), renderer: gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) } : null,
      supportedExtensions: gl.getSupportedExtensions(),
      contextAttributes: gl.getContextAttributes(),
      drawingBuffer: {
        width: gl.drawingBufferWidth, height: gl.drawingBufferHeight,
        colorSpace: gl.drawingBufferColorSpace, format: gl.drawingBufferFormat, unpackColorSpace: gl.unpackColorSpace,
      },
    };
  };
  return JSON.stringify({ webgl1: sweep('webgl'), webgl2: sweep('webgl2') });
})()`,

    // What every value-returning call answers for a context with nothing bound,
    // nothing compiled, nothing linked, and never drawn into — which is the only
    // state ours is ever in.
    webglGetters: `(() => {
  const out = {};
  const g = (label, fn) => { try { const v = fn(); out[label] = v && typeof v === 'object' && v.length !== undefined ? Array.from(v) : v; } catch (e) { out[label] = 'THROWS: ' + e.message; } };
  const gl = document.createElement('canvas').getContext('webgl');
  const prog = gl.createProgram(), sh = gl.createShader(gl.VERTEX_SHADER);
  const buf = gl.createBuffer(), tex = gl.createTexture(), rb = gl.createRenderbuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf); gl.bindTexture(gl.TEXTURE_2D, tex); gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
  g('getError', () => gl.getError());
  g('isContextLost', () => gl.isContextLost());
  g('checkFramebufferStatus', () => gl.checkFramebufferStatus(gl.FRAMEBUFFER));
  for (const p of ['LOW_FLOAT', 'MEDIUM_FLOAT', 'HIGH_FLOAT', 'LOW_INT', 'MEDIUM_INT', 'HIGH_INT']) {
    g('precision.' + p, () => { const f = gl.getShaderPrecisionFormat(gl.VERTEX_SHADER, gl[p]); return [f.rangeMin, f.rangeMax, f.precision]; });
  }
  for (const p of ['DELETE_STATUS', 'LINK_STATUS', 'VALIDATE_STATUS', 'ATTACHED_SHADERS', 'ACTIVE_UNIFORMS', 'ACTIVE_ATTRIBUTES']) {
    g('programParameter.' + p, () => gl.getProgramParameter(prog, gl[p]));
  }
  for (const p of ['SHADER_TYPE', 'DELETE_STATUS', 'COMPILE_STATUS']) g('shaderParameter.' + p, () => gl.getShaderParameter(sh, gl[p]));
  for (const p of ['BUFFER_SIZE', 'BUFFER_USAGE']) g('bufferParameter.' + p, () => gl.getBufferParameter(gl.ARRAY_BUFFER, gl[p]));
  for (const p of ['TEXTURE_MAG_FILTER', 'TEXTURE_MIN_FILTER', 'TEXTURE_WRAP_S', 'TEXTURE_WRAP_T']) g('texParameter.' + p, () => gl.getTexParameter(gl.TEXTURE_2D, gl[p]));
  for (const p of ['RENDERBUFFER_WIDTH', 'RENDERBUFFER_HEIGHT', 'RENDERBUFFER_INTERNAL_FORMAT', 'RENDERBUFFER_RED_SIZE']) g('renderbufferParameter.' + p, () => gl.getRenderbufferParameter(gl.RENDERBUFFER, gl[p]));
  for (const p of ['VERTEX_ATTRIB_ARRAY_ENABLED', 'VERTEX_ATTRIB_ARRAY_SIZE', 'VERTEX_ATTRIB_ARRAY_STRIDE', 'VERTEX_ATTRIB_ARRAY_TYPE', 'VERTEX_ATTRIB_ARRAY_NORMALIZED', 'VERTEX_ATTRIB_ARRAY_BUFFER_BINDING', 'CURRENT_VERTEX_ATTRIB']) g('vertexAttrib.' + p, () => gl.getVertexAttrib(0, gl[p]));
  g('vertexAttribOffset', () => gl.getVertexAttribOffset(0, gl.VERTEX_ATTRIB_ARRAY_POINTER));
  g('framebufferAttachmentParameter', () => gl.getFramebufferAttachmentParameter(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE));
  g('getActiveAttrib', () => gl.getActiveAttrib(prog, 0));
  g('getActiveUniform', () => gl.getActiveUniform(prog, 0));
  g('getAttachedShaders', () => gl.getAttachedShaders(prog));
  g('getAttribLocation', () => gl.getAttribLocation(prog, 'aPos'));
  g('getUniformLocation', () => gl.getUniformLocation(prog, 'uColor'));
  g('getShaderSource', () => gl.getShaderSource(sh));
  g('getShaderInfoLog', () => gl.getShaderInfoLog(sh));
  g('getProgramInfoLog', () => gl.getProgramInfoLog(prog));
  g('isBuffer', () => gl.isBuffer(buf));
  g('isTexture', () => gl.isTexture(tex));
  g('isProgram', () => gl.isProgram(prog));
  g('isShader', () => gl.isShader(sh));
  g('isEnabled.DITHER', () => gl.isEnabled(gl.DITHER));
  g('isEnabled.BLEND', () => gl.isEnabled(gl.BLEND));
  g('readPixels', () => { const px = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); return Array.from(px); });
  g('createdObjectTags', () => [gl.createBuffer(), gl.createTexture(), gl.createShader(gl.VERTEX_SHADER), gl.createProgram(), gl.createFramebuffer(), gl.createRenderbuffer()].map((o) => Object.prototype.toString.call(o)).join(' '));

  const gl2 = document.createElement('canvas').getContext('webgl2');
  const prog2 = gl2.createProgram(), sam = gl2.createSampler();
  const sync = () => gl2.fenceSync(gl2.SYNC_GPU_COMMANDS_COMPLETE, 0);
  g('gl2.createdObjectTags', () => [gl2.createQuery(), sam, gl2.createVertexArray(), gl2.createTransformFeedback(), sync()].map((o) => Object.prototype.toString.call(o)).join(' '));
  g('gl2.isQuery', () => gl2.isQuery(gl2.createQuery()));
  g('gl2.isSampler', () => gl2.isSampler(sam));
  g('gl2.isSync', () => gl2.isSync(sync()));
  g('gl2.isVertexArray', () => gl2.isVertexArray(gl2.createVertexArray()));
  g('gl2.isTransformFeedback', () => gl2.isTransformFeedback(gl2.createTransformFeedback()));
  g('gl2.syncParameter.SYNC_STATUS', () => gl2.getSyncParameter(sync(), gl2.SYNC_STATUS));
  g('gl2.syncParameter.OBJECT_TYPE', () => gl2.getSyncParameter(sync(), gl2.OBJECT_TYPE));
  g('gl2.clientWaitSync', () => gl2.clientWaitSync(sync(), 0, 0));
  g('gl2.getQuery', () => gl2.getQuery(gl2.ANY_SAMPLES_PASSED, gl2.CURRENT_QUERY));
  g('gl2.getQueryParameter', () => gl2.getQueryParameter(gl2.createQuery(), gl2.QUERY_RESULT_AVAILABLE));
  g('gl2.getSamplerParameter', () => gl2.getSamplerParameter(sam, gl2.TEXTURE_MAG_FILTER));
  g('gl2.getIndexedParameter', () => gl2.getIndexedParameter(gl2.UNIFORM_BUFFER_BINDING, 0));
  g('gl2.getInternalformatParameter', () => gl2.getInternalformatParameter(gl2.RENDERBUFFER, gl2.RGBA8, gl2.SAMPLES));
  g('gl2.getUniformIndices', () => gl2.getUniformIndices(prog2, ['x']));
  g('gl2.getActiveUniforms', () => gl2.getActiveUniforms(prog2, [0], gl2.UNIFORM_TYPE));
  g('gl2.getUniformBlockIndex', () => gl2.getUniformBlockIndex(prog2, 'Block'));
  g('gl2.getActiveUniformBlockName', () => gl2.getActiveUniformBlockName(prog2, 0));
  g('gl2.getTransformFeedbackVarying', () => gl2.getTransformFeedbackVarying(prog2, 0));
  g('gl2.getFragDataLocation', () => gl2.getFragDataLocation(prog2, 'color'));
  g('gl2.TIMEOUT_IGNORED', () => gl2.TIMEOUT_IGNORED);
  return JSON.stringify(out);
})()`,

    canvas2d: `(() => {
  const out = {};
  const ctx = document.createElement('canvas').getContext('2d');
  out.defaultFont = ctx.font;
  out.contextAttributes = ctx.getContextAttributes();
  out.isContextLost = ctx.isContextLost();
  out.lineDash = ctx.getLineDash();
  out.transformType = Object.getPrototypeOf(ctx.getTransform()).constructor.name;
  // A fingerprint reads the PNG bytes, so both the empty and the one-solid-fill
  // cases are recorded: the first is pure geometry, the second proves the fill
  // actually reached the bitmap.
  out.emptyDataUrls = {};
  out.solidRedDataUrls = {};
  for (const [w, h] of [[1, 1], [10, 10], [240, 60], [300, 150]]) {
    const a = document.createElement('canvas'); a.width = w; a.height = h;
    out.emptyDataUrls[w + 'x' + h] = { len: a.toDataURL().length, url: a.toDataURL() };
    const b = document.createElement('canvas'); b.width = w; b.height = h;
    const bx = b.getContext('2d'); bx.fillStyle = '#ff0000'; bx.fillRect(0, 0, w, h);
    out.solidRedDataUrls[w + 'x' + h] = { len: b.toDataURL().length, url: b.toDataURL() };
  }
  out.dataUrlTypes = (() => {
    const c = document.createElement('canvas'); c.width = 10; c.height = 10;
    const r = {};
    for (const t of ['image/png', 'image/jpeg', 'image/webp', 'image/bogus']) r[t] = c.toDataURL(t).slice(0, 30);
    return r;
  })();
  // Every 2D context attribute's default, so the stubs report Chrome's values
  // rather than plausible-looking ones.
  out.accessorDefaults = {};
  {
    const fresh = document.createElement('canvas').getContext('2d');
    for (const name of Object.getOwnPropertyNames(CanvasRenderingContext2D.prototype)) {
      if (name === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(CanvasRenderingContext2D.prototype, name);
      if (!d.get) continue;
      let v;
      try { v = fresh[name]; } catch (e) { v = '__throws__'; }
      out.accessorDefaults[name] = (v && typeof v === 'object') ? ('[object ' + v.constructor.name + ']') : v;
    }
    out.gradientTypes = {
      linear: fresh.createLinearGradient(0, 0, 1, 1).constructor.name,
      pattern: String(fresh.createPattern(document.createElement('canvas'), 'repeat')?.constructor.name),
      transform: fresh.getTransform().constructor.name,
      isPointInPath: fresh.isPointInPath(0, 0),
      isPointInStroke: fresh.isPointInStroke(0, 0),
      lineDash: fresh.getLineDash(),
    };
    out.gradientProto = Object.getOwnPropertyNames(CanvasGradient.prototype);
    out.patternProto = Object.getOwnPropertyNames(CanvasPattern.prototype);
  }
  out.getImageDataAfterRedFill = (() => {
    const c = document.createElement('canvas'); c.width = 10; c.height = 10;
    const x = c.getContext('2d'); x.fillStyle = '#ff0000'; x.fillRect(0, 0, 10, 10);
    const d = x.getImageData(0, 0, 10, 10).data;
    return { first4: [d[0], d[1], d[2], d[3]], anyNonZero: Array.prototype.some.call(d, (v) => v !== 0) };
  })();
  return JSON.stringify(out);
})()`,

    // measureText is what a canvas-text fingerprint actually reads. Measured at
    // 100px so a per-family table can be scaled: the metric is exactly linear in
    // font size, and a string's width is the plain sum of its characters'
    // advances except across a kerning pair.
    text: `(() => {
  const out = {};
  const ctx = document.createElement('canvas').getContext('2d');
  const families = ['sans-serif', 'serif', 'monospace', 'Arial', 'Helvetica', 'Times New Roman', 'Courier New'];
  out.advancesAt100px = {};
  for (const f of families) {
    ctx.font = '100px ' + f;
    const widths = {};
    for (let c = 32; c < 127; c++) widths[c] = ctx.measureText(String.fromCharCode(c)).width;
    out.advancesAt100px[f] = { resolvedFont: ctx.font, widths };
  }
  out.linearityInFontSize = {};
  for (const size of [10, 11, 12, 14, 16, 24, 72, 100]) {
    ctx.font = size + 'px sans-serif';
    out.linearityInFontSize[size] = { m: ctx.measureText('m').width, sample: ctx.measureText('mmmmmmmmmmlli').width };
  }
  ctx.font = '10px sans-serif';
  out.kerningPairsVsSumOfAdvances = {};
  for (const s of ['mmmmmmmmmmlli', 'AV', 'To', 'Hello, world!', 'Cwm fjordbank glyphs vext quiz', 'WWW', 'iii']) {
    let sum = 0;
    for (const ch of s) sum += ctx.measureText(ch).width;
    out.kerningPairsVsSumOfAdvances[s] = { whole: ctx.measureText(s).width, sumOfChars: sum };
  }
  out.fullMetrics = {};
  for (const [font, text] of [['10px sans-serif', 'mmmmmmmmmmlli'], ['14px Arial', 'Cwm fjordbank glyphs vext quiz'], ['10px sans-serif', '']]) {
    ctx.font = font;
    const m = ctx.measureText(text);
    const rec = {};
    for (const k of Object.getOwnPropertyNames(Object.getPrototypeOf(m))) if (k !== 'constructor') rec[k] = m[k];
    out.fullMetrics[font + '|' + text] = rec;
  }
  // Everything TextMetrics reports for a single glyph, so a string's ink box
  // can be reconstructed: left/right are the bearings from the pen position,
  // ascent/descent the ink extent above/below the alphabetic baseline. Same
  // 100px basis as the advances, for the same reason.
  out.glyphMetricsAt100px = {};
  for (const f of families) {
    ctx.font = '100px ' + f;
    const glyphs = {};
    for (let c = 32; c < 127; c++) {
      const m = ctx.measureText(String.fromCharCode(c));
      glyphs[c] = [m.width, m.actualBoundingBoxLeft, m.actualBoundingBoxRight, m.actualBoundingBoxAscent, m.actualBoundingBoxDescent];
    }
    out.glyphMetricsAt100px[f] = { resolvedFont: ctx.font, order: ['width', 'left', 'right', 'ascent', 'descent'], glyphs };
  }

  // Font-level metrics do not depend on the text, only on the family and size.
  // Sampled at several sizes to show how Chrome rounds them.
  out.fontLevelMetrics = {};
  for (const f of families.concat(['NoSuchFamily12345'])) {
    const bySize = {};
    for (const size of [10, 14, 16, 100]) {
      ctx.font = size + 'px ' + f;
      const m = ctx.measureText('x');
      bySize[size] = {
        resolvedFont: ctx.font,
        fontBoundingBoxAscent: m.fontBoundingBoxAscent,
        fontBoundingBoxDescent: m.fontBoundingBoxDescent,
        hangingBaseline: m.hangingBaseline,
        alphabeticBaseline: m.alphabeticBaseline,
        ideographicBaseline: m.ideographicBaseline,
        emHeightAscent: m.emHeightAscent,
        emHeightDescent: m.emHeightDescent,
      };
    }
    out.fontLevelMetrics[f] = bySize;
  }

  // fontBoundingBox is NOT linear in size: CoreText quantises it per size, so
  // 16px sans-serif reports an ascent of 14 where scaling 100px's 92 would say
  // 15. Sweep every size a page is likely to ask for and store the answers.
  out.fontBoundingBoxBySize = {};
  for (const f of families) {
    const ascents = [], descents = [];
    for (let size = 1; size <= 120; size++) {
      ctx.font = size + 'px ' + f;
      const m = ctx.measureText('x');
      ascents.push(m.fontBoundingBoxAscent);
      descents.push(m.fontBoundingBoxDescent);
    }
    out.fontBoundingBoxBySize[f] = { from: 1, to: 120, ascents, descents };
  }

  // Which of the measured families, if any, an unresolvable one falls back to.
  out.fallbackFamilyAdvances = {};
  for (const f of ['NoSuchFamily12345', 'cursive', 'fantasy', 'system-ui', 'Times', 'Courier']) {
    ctx.font = '100px ' + f;
    const widths = {};
    for (let c = 32; c < 127; c++) widths[c] = ctx.measureText(String.fromCharCode(c)).width;
    out.fallbackFamilyAdvances[f] = widths;
  }

  // An unresolvable family still measures - as whatever Chrome falls back to.
  out.unknownFamilyAdvances = {};
  for (const f of ['NoSuchFamily12345', 'cursive', 'fantasy', 'system-ui']) {
    ctx.font = '100px ' + f;
    out.unknownFamilyAdvances[f] = { resolvedFont: ctx.font, m: ctx.measureText('m').width, sample: ctx.measureText('mmmmmmmmmmlli').width };
  }

  out.fontShorthandRoundTrip = {};
  for (const f of ['10px sans-serif', '14px Arial', 'bold 12px serif', 'italic 700 16px/1.5 "Times New Roman", serif', 'small-caps 20px monospace', '1em sans-serif', 'not-a-font']) {
    ctx.font = '10px sans-serif';
    ctx.font = f;
    out.fontShorthandRoundTrip[f] = ctx.font;
  }
  // Same list, but starting from a non-default font, which separates "parsed
  // and happened to resolve to the default" from "rejected, kept the old one".
  out.fontShorthandFromNonDefault = {};
  for (const f of ['1em sans-serif', 'not-a-font', '', '12pt serif', 'xx-large serif', '16px', 'bold serif', '16px Arial, sans-serif',
      '900 16px serif', '100 16px serif', 'lighter 16px serif', 'bolder 16px serif', 'oblique 16px serif', 'oblique 30deg 16px serif',
      'condensed 16px serif', 'normal normal normal 16px serif', '16px "Foo Bar"', "16px 'Single'", '16px Foo Bar',
      '2rem serif', '150% serif', 'larger serif', 'smaller serif', 'xx-small serif', 'x-small serif', 'small serif',
      'medium serif', 'large serif', 'x-large serif', 'xxx-large serif', '16.5px serif', 'italic small-caps bold 16px serif',
      '1.5ex serif', '10ch serif', '1in serif', '1cm serif', '10mm serif', '1pc serif', 'inherit', 'caption', '  16px   serif  ']) {
    ctx.font = '33px monospace';
    ctx.font = f;
    out.fontShorthandFromNonDefault[f] = ctx.font;
  }
  return JSON.stringify(out);
})()`,
};

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'fp-graphics-'));
const flags = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check', ...personaScaleFlags(),
];
if (!headed) flags.push('--headless=new');

// CDP_ENDPOINT points this at a Chrome we did not spawn -- the Linux container
// from linux-chrome.mjs. The renderer strings and every driver limit below are
// the whole reason this file exists, and they belong to the platform we claim.
const ENDPOINT = process.env.CDP_ENDPOINT ?? null;
// Nothing here reads Chrome's output, so do not give it a pipe to fill: a
// child that fills an unread pipe blocks in write and stops answering CDP.
const proc = ENDPOINT ? null : spawn(CHROME, flags, { stdio: 'ignore' });
const snapshot = {
    note:
        'Graphics-surface ground truth, measured from the real Google Chrome on the reference host. ' +
        'The Zig implementations under src/browser/webapi/canvas/ are transcribed from this file. ' +
        'Do not edit those values from memory — re-run tools/fingerprint/dump-graphics.mjs.',
    engine: headed ? 'chrome-headed' : 'chrome-headless',
    sections: {},
};

try {
    for (let i = 0; i < 100; i++) {
        try {
            if ((await fetch(`http://127.0.0.1:${PORT}/json/version`)).ok) break;
        } catch {}
        await sleep(100);
    }
    const cdp = await Cdp.connect(ENDPOINT ?? `http://127.0.0.1:${PORT}`);
    const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    await cdp.send('Runtime.enable', {}, sessionId);
    await cdp.send('Page.enable', {}, sessionId);
    await goto(cdp, sessionId, 'about:blank', { settleMs: 300 });

    for (const [name, expression] of Object.entries(SECTIONS)) {
        try {
            snapshot.sections[name] = JSON.parse(await evaluate(cdp, sessionId, expression));
            console.log(`  ok ${name}`);
        } catch (e) {
            snapshot.sections[name] = { __err: String((e && e.message) || e) };
            console.error(`  ! ${name}: ${(e && e.message) || e}`);
        }
    }
} finally {
    proc?.kill('SIGKILL');
}

await fs.writeFile(outPath, JSON.stringify(snapshot, null, 1));
console.log(`wrote ${outPath}`);
