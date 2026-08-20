(async () => {
  // Batch 15 follow-ups: the exact init-dictionary semantics and error strings
  // the first two probes left open.
  const out = {};
  const S = (fn) => { try { const v = fn(); return typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };

  // SecurityPolicyViolationEvent defaults bubbles/composed true -- are they
  // still overridable from the init dictionary?
  out.spveOverride = S(() => { const e = new SecurityPolicyViolationEvent('x', { bubbles: false, composed: false, cancelable: true }); return { bubbles: e.bubbles, composed: e.composed, cancelable: e.cancelable }; });
  out.spveEmptyDict = S(() => { const e = new SecurityPolicyViolationEvent('x', {}); return { bubbles: e.bubbles, composed: e.composed }; });
  out.spveNonDict = S(() => new SecurityPolicyViolationEvent('x', 7));
  out.spveNumericStrings = S(() => { const e = new SecurityPolicyViolationEvent('x', { statusCode: '12', lineNumber: '3.7', columnNumber: -1 }); return { statusCode: e.statusCode, lineNumber: e.lineNumber, columnNumber: e.columnNumber }; });

  // BeforeInstallPromptEvent's two exotic members.
  out.bipe = await (async () => {
    try {
      const e = new BeforeInstallPromptEvent('beforeinstallprompt');
      const p = e.platforms;
      const r = { isArray: Array.isArray(p), len: p.length, frozen: Object.isFrozen(p), sameTwice: e.platforms === e.platforms, choiceIsPromise: e.userChoice instanceof Promise, choiceSameTwice: e.userChoice === e.userChoice };
      r.choice = await Promise.race([e.userChoice.then((v) => `resolved ${JSON.stringify(v)}`, (x) => `rejected ${x.name}: ${x.message}`), new Promise((res) => setTimeout(() => res('pending'), 800))]);
      r.withInit = S(() => { const f = new BeforeInstallPromptEvent('x', { platforms: ['web'] }); return JSON.stringify(f.platforms); });
      return r;
    } catch (e) { return `${e.name}: ${e.message}`; }
  })();

  // ClipboardEvent with a real DataTransfer, and the non-object case.
  out.clipboardEventReal = S(() => { const dt = new DataTransfer(); dt.setData('text/plain', 'x'); const e = new ClipboardEvent('paste', { clipboardData: dt }); return { same: e.clipboardData === dt, brand: e.clipboardData && Object.prototype.toString.call(e.clipboardData), data: e.clipboardData && e.clipboardData.getData('text/plain') }; });
  out.clipboardEventBadType = S(() => new ClipboardEvent('paste', { clipboardData: 5 }));
  out.clipboardEventNonDict = S(() => new ClipboardEvent('paste', 'str'));

  // TrackEvent with each of the three union arms it accepts.
  out.trackEventReal = S(() => { const v = document.createElement('video'); const t = v.addTextTrack('subtitles'); const e = new TrackEvent('addtrack', { track: t }); return { same: e.track === t, brand: Object.prototype.toString.call(e.track) }; });
  out.trackEventBadType = S(() => new TrackEvent('addtrack', { track: 5 }));
  out.trackEventUndefined = S(() => String(new TrackEvent('addtrack', { track: undefined }).track));

  // BlobEvent's data conversion and timecode coercion.
  out.blobEventBadData = S(() => new BlobEvent('x', { data: 5 }));
  out.blobEventNullData = S(() => new BlobEvent('x', { data: null }));
  out.blobEventTimecodeString = S(() => new BlobEvent('x', { data: new Blob([]), timecode: '2.5' }).timecode);
  out.blobEventTimecodeNaN = S(() => new BlobEvent('x', { data: new Blob([]), timecode: NaN }).timecode);
  out.blobEventNegTimecode = S(() => new BlobEvent('x', { data: new Blob([]), timecode: -1 }).timecode);

  // AnimationPlaybackEvent's nullable doubles.
  out.apeStrings = S(() => { const e = new AnimationPlaybackEvent('x', { currentTime: '4', timelineTime: null }); return { currentTime: e.currentTime, timelineTime: String(e.timelineTime) }; });
  out.apeBadString = S(() => new AnimationPlaybackEvent('x', { currentTime: 'abc' }).currentTime);
  out.apeNonDict = S(() => new AnimationPlaybackEvent('x', 3));

  // WindowControlsOverlay / VirtualKeyboard with an empty dictionary.
  out.wcoEmpty = S(() => { const e = new WindowControlsOverlayGeometryChangeEvent('x', {}); return { rect: String(e.titlebarAreaRect), visible: e.visible }; });
  out.wcoNonDict = S(() => new WindowControlsOverlayGeometryChangeEvent('x', 5));
  out.vkNonDict = S(() => { const e = new VirtualKeyboardGeometryChangeEvent('x', 5); return e.type; });
  out.vkNoDict = S(() => new VirtualKeyboardGeometryChangeEvent('x').type);

  // ContentVisibility / WebGLContextEvent coercions.
  out.cvNonDict = S(() => new ContentVisibilityAutoStateChangeEvent('x', 1).skipped);
  out.glStatusNumber = S(() => new WebGLContextEvent('x', { statusMessage: 7 }).statusMessage);
  out.glNonDict = S(() => new WebGLContextEvent('x', 7).statusMessage);
  out.glNoType = S(() => new WebGLContextEvent());

  // PictureInPictureEvent needs a window it cannot get -- confirm both arms.
  out.pipEmptyDict = S(() => new PictureInPictureEvent('x', {}));
  out.pipNonDict = S(() => new PictureInPictureEvent('x', 5));

  // Whether these events are in a worker at all.
  out.worker = await (async () => {
    const src = `const names=['AnimationPlaybackEvent','BeforeInstallPromptEvent','BlobEvent','ClipboardEvent','ClipboardItem','ContentVisibilityAutoStateChangeEvent','SecurityPolicyViolationEvent','TrackEvent','WebGLContextEvent','Path2D','DOMQuad','DOMRectList','TimeRanges','Touch','TouchList','TextTrack','TextTrackList','TextTrackCueList','URLPattern','Option','Profiler','EyeDropper','IdleDetector','InputDeviceCapabilities','ReportingObserver','KeyframeEffect','IDBOpenDBRequest','Highlight','HighlightRegistry','CustomStateSet','MathMLElement','XSLTProcessor','Sanitizer','DOMError','CaptureController','CropTarget','BrowserCaptureMediaStreamTrack','OverconstrainedError','PictureInPictureWindow','PictureInPictureEvent','NavigateEvent','NavigationDestination','NavigationTransition','DeviceMotionEventAcceleration','DeviceMotionEventRotationRate','VirtualKeyboardGeometryChangeEvent','WindowControlsOverlayGeometryChangeEvent'];
      const have=[],miss=[];for(const n of names){(typeof self[n]==='undefined'?miss:have).push(n)}self.postMessage({have,miss});`;
    const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
    return await new Promise((r) => { w.onmessage = (e) => r(e.data); setTimeout(() => r('TIMEOUT'), 3000); });
  })();

  // A few non-event follow-ups worth having before the later sub-tasks.
  out.quadOnePoint = S(() => { const q = new DOMQuad({ x: 2, y: 3 }); return [q.p1.x, q.p1.y, q.p2.x, q.p4.y].join(','); });
  out.quadNonDict = S(() => new DOMQuad(5).p1.x);
  out.quadBoundsNegative = S(() => JSON.stringify(DOMQuad.fromRect({ x: 5, y: 5, width: -3, height: -4 }).getBounds()));
  out.timeRangesNegative = S(() => document.createElement('video').buffered.start(-1));
  out.timeRangesNoArg = S(() => document.createElement('video').buffered.start());
  out.optionUndefinedText = S(() => { const o = new Option(undefined, 'v'); return { text: JSON.stringify(o.text), value: o.value, html: o.outerHTML }; });
  out.optionNullText = S(() => new Option(null, null).outerHTML);
  out.clipboardItemTwo = S(() => JSON.stringify(new ClipboardItem({ 'text/html': new Blob(['<b>'], { type: 'text/html' }), 'text/plain': 'x' }).types));
  out.highlightNegPriority = S(() => { const h = new Highlight(); h.priority = -2; return h.priority; });
  out.highlightPriorityString = S(() => { const h = new Highlight(); h.priority = '3'; return h.priority; });
  out.customStateSetAddEmpty = S(() => { const el = document.createElement('div'); return 'n/a'; });
  out.pathSvgBad = S(() => { const p = new Path2D('not a path'); return 'accepted'; });
  out.rectListIndexAssign = S(() => { const r = document.body.getClientRects(); r[0] = 5; return String(r[0]); });
  return out;
})()
