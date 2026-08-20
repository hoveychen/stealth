// Batch 18 / P1 (4): the leftovers -- whether an inline session ever dispatches
// `end`, what session.end()'s promise does, and how the three set-like /
// array-like XR collections behave when they are empty (which is the only state
// a desktop Chrome can reach).
(async () => {
  const s = (f) => { try { const v = f(); return v === undefined ? 'undefined' : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  const out = {};

  const session = await navigator.xr.requestSession('inline');
  const viewer = await session.requestReferenceSpace('viewer');
  const gl = document.createElement('canvas').getContext('webgl');
  session.updateRenderState({ baseLayer: new XRWebGLLayer(session, gl) });

  // Get into a frame so trackedAnchors / detectedPlanes are reachable.
  const frame = await new Promise((r) => {
    const t = setTimeout(() => r(null), 5000);
    session.requestAnimationFrame((_, f) => { clearTimeout(t); r(f); });
  });

  if (frame) {
    const anchors = frame.trackedAnchors;
    out.anchorSet = {
      brand: Object.prototype.toString.call(anchors),
      size: s(() => String(anchors.size)),
      stable: s(() => String(frame.trackedAnchors === frame.trackedAnchors)),
      isSet: s(() => String(anchors instanceof Set)),
      has: s(() => String(anchors.has({}))),
      values: s(() => `${Object.prototype.toString.call(anchors.values())}|${JSON.stringify([...anchors])}`),
      entries: s(() => JSON.stringify([...anchors.entries()])),
      forEach: s(() => { let n = 0; anchors.forEach(() => n++); return String(n); }),
      forEachNoArg: s(() => anchors.forEach()),
      iteratorIsValues: s(() => String(anchors[Symbol.iterator] === anchors.values)),
    };
    const planes = frame.detectedPlanes;
    out.planeSet = {
      brand: Object.prototype.toString.call(planes),
      size: s(() => String(planes.size)),
      isSet: s(() => String(planes instanceof Set)),
      spread: s(() => JSON.stringify([...planes])),
      iteratorIsValues: s(() => String(planes[Symbol.iterator] === planes.values)),
    };
  }

  const inputs = session.inputSources;
  out.inputSourceArray = {
    brand: Object.prototype.toString.call(inputs),
    length: s(() => String(inputs.length)),
    isArray: s(() => String(Array.isArray(inputs))),
    spread: s(() => JSON.stringify([...inputs])),
    entries: s(() => `${Object.prototype.toString.call(inputs.entries())}|${JSON.stringify([...inputs.entries()])}`),
    keys: s(() => JSON.stringify([...inputs.keys()])),
    forEach: s(() => { let n = 0; inputs.forEach(() => n++); return String(n); }),
    forEachNoArg: s(() => inputs.forEach()),
    index0: s(() => String(inputs[0])),
    hasIndexProp: s(() => String(Object.getOwnPropertyNames(inputs).join(','))),
    iteratorIsValues: s(() => String(inputs[Symbol.iterator] === inputs.values)),
  };

  // `end`: the promise, the event, and the ordering between them. Ten seconds,
  // both listener styles, and a plain-task probe in between so we can tell a
  // starved queue from a genuinely absent event.
  let ticks = 0;
  const tick = setInterval(() => { ticks++; }, 100);
  const events = [];
  session.onend = (e) => events.push(`onend:${e.type}:${e.isTrusted}:${e.eventPhase}:${Object.prototype.toString.call(e)}:session=${e.session === session}`);
  session.addEventListener('end', () => events.push('listener'));
  const endReturn = session.end();
  out.endReturnBrand = Object.prototype.toString.call(endReturn);
  out.endPromise = await Promise.race([
    Promise.resolve(endReturn).then((v) => `resolved ${String(v)}`, (e) => `${e.name}: ${e.message}`),
    new Promise((r) => setTimeout(() => r('PENDING 10s'), 10000)),
  ]);
  await new Promise((r) => setTimeout(r, 500));
  clearInterval(tick);
  out.endEvents = events.join(' | ') || 'none';
  out.ticksObserved = String(ticks);
  out.visibilityAfterEnd = s(() => String(session.visibilityState));

  return out;
})()
