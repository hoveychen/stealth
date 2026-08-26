(async () => {
  const out = {};
  const f = document.createElement('iframe'); f.style.display='none'; document.body.appendChild(f);
  out.framesBefore = window.length;
  const saved = f.contentWindow;
  f.remove();
  out.framesAfter = window.length;
  out.contentWindowAfter = String(f.contentWindow);
  out.savedClosed = saved.closed;
  out.savedParent = String(saved.parent);
  out.fontsIterable = (() => { try { const a = new FontFace('Q','local(Arial)'); document.fonts.add(a); const n = [...document.fonts].length; document.fonts.clear(); return `${n}/${document.fonts.size}`; } catch (e) { return 'throw: ' + e.message; } })();
  const w = new Worker(URL.createObjectURL(new Blob(["self.onmessage=()=>postMessage(navigator.connection?navigator.connection.effectiveType+'/'+navigator.connection.rtt:'absent')"],{type:'text/javascript'})));
  out.workerConnection = await new Promise((r)=>{const t=setTimeout(()=>r('timeout'),6000); w.onmessage=(e)=>{clearTimeout(t);r(e.data);};w.postMessage(1);});
  return JSON.stringify(out);
})()
