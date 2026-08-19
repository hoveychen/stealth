// How fast the WebGL surface answers, which is a fingerprint in its own right.
//
// browserscan.net's isWebGLCorrect rule -- the one the UI calls "WebGL
// exception" -- is a benchmark, not an exception check: it spins
// getParameter(UNMASKED_RENDERER_WEBGL) for five milliseconds and fails any
// browser answering faster than 100 calls per millisecond. The whole block sits
// inside a try/catch, so a browser that actually threw would pass it.
//
// The interesting part is which calls are slow in a real browser. Measured on
// the reference host, Chrome answers the *string* parameters at 23-33 calls per
// millisecond and the numeric ones at thousands, because the strings come from
// the driver and the numbers are cached state. An engine reading tables answers
// everything at thousands, and that is the anomaly -- so this measures both,
// and a fix that made the numbers slow too would show up here as its own.
//
//   node tools/fingerprint/webgl-query-rate.mjs
//   node tools/fingerprint/webgl-query-rate.mjs --chrome
//
// LP_BIN points at a build other than ./zig-out/bin/lightpanda.
import { spawn } from 'node:child_process';
import { Cdp, newPage, sleep } from './cdp.mjs';
const useChrome = process.argv.includes('--chrome');
const port = Number(process.env.PORT ?? 9670);
let proc;
if (useChrome) {
  const os = await import('node:os'), fsp = await import('node:fs/promises'), path = await import('node:path');
  const profile = await fsp.mkdtemp(path.join(os.tmpdir(), 'fp-r2-'));
  proc = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check'], {stdio:['ignore','pipe','pipe']});
} else {
  proc = spawn(process.env.LP_BIN ?? 'zig-out/bin/lightpanda',
    ['serve','--host','127.0.0.1','--port',String(port)], {stdio:['ignore','pipe','pipe']});
}
proc.stdout.resume(); proc.stderr.resume();
for (let i=0;i<300;i++){ try{ await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break }catch{ await sleep(200) } }
const cdp = await Cdp.connect(`http://127.0.0.1:${port}`);
let sessionId;
if (useChrome) { const {targetId}=await cdp.send('Target.createTarget',{url:'about:blank'}); ({sessionId}=await cdp.send('Target.attachToTarget',{targetId,flatten:true})); }
else ({sessionId}=await newPage(cdp));
await cdp.send('Page.enable',{},sessionId).catch(()=>{});
await cdp.send('Page.navigate',{url:'https://example.com/'},sessionId);
await sleep(2000);
const EXPR = `(() => {
  const c = document.createElement('canvas');
  const gl = c.getContext('webgl2') || c.getContext('webgl');
  const ee = gl.getExtension('WEBGL_debug_renderer_info');
  const rate = (fn) => { const h = performance.now(); let k = 0;
    for (; 5 > performance.now() - h;) { for (let i=0;i<10;i++) fn(); k += 10; }
    return Math.round(k / (performance.now() - h)); };
  return JSON.stringify({
    unmaskedRenderer: rate(() => gl.getParameter(ee.UNMASKED_RENDERER_WEBGL)),
    unmaskedVendor:   rate(() => gl.getParameter(ee.UNMASKED_VENDOR_WEBGL)),
    version:          rate(() => gl.getParameter(gl.VERSION)),
    maxTextureSize:   rate(() => gl.getParameter(gl.MAX_TEXTURE_SIZE)),
    maxViewportDims:  rate(() => gl.getParameter(gl.MAX_VIEWPORT_DIMS)),
    getExtension:     rate(() => gl.getExtension('OES_texture_float')),
    getSupportedExt:  rate(() => gl.getSupportedExtensions()),
    emptyLoop:        rate(() => {}),
  });
})()`;
const res = await cdp.send('Runtime.evaluate',{expression:EXPR,returnByValue:true},sessionId);
console.log(useChrome?'CHROME    ':'LIGHTPANDA', res.result.value ?? JSON.stringify(res).slice(0,300));
cdp.close(); proc.kill('SIGKILL'); process.exit(0);
