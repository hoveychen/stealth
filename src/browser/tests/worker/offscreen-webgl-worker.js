// An OffscreenCanvas hands back a WebGL context inside a worker in Chrome
// (measured: typeof self.WebGLRenderingContext === 'function' there, and
// new OffscreenCanvas(256, 256).getContext('webgl') is a WebGLRenderingContext
// whose .canvas is the OffscreenCanvas). This checks the same holds here.
try {
  const canvas = new OffscreenCanvas(256, 256);
  const gl = canvas.getContext('webgl');
  const gl2 = new OffscreenCanvas(64, 32).getContext('webgl2');
  postMessage({
    ok: true,
    results: {
      has_webgl_ctor: typeof self.WebGLRenderingContext,
      has_webgl2_ctor: typeof self.WebGL2RenderingContext,
      has_audio_ctor: typeof self.AudioContext,
      gl_tag: Object.prototype.toString.call(gl),
      gl_canvas_is_same: gl.canvas === canvas,
      gl_canvas_tag: Object.prototype.toString.call(gl.canvas),
      drawing_buffer: [gl.drawingBufferWidth, gl.drawingBufferHeight],
      viewport: Array.from(gl.getParameter(gl.VIEWPORT)),
      // Needed an Execution rather than a Frame to work here.
      buffer_tag: Object.prototype.toString.call(gl.createBuffer()),
      gl2_tag: Object.prototype.toString.call(gl2),
      gl2_drawing_buffer: [gl2.drawingBufferWidth, gl2.drawingBufferHeight],
    },
  });
} catch (err) {
  postMessage({ ok: false, err: String(err && err.stack || err) });
}
