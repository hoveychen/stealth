// The worker-realm half of probe-shapes.js: which of the 47 pure-surface names
// a DedicatedWorkerGlobalScope carries, and for the ones it does, the same
// prototype root / member list / arity reading the window probe takes.
//
// [SecureContext] reaches the worker realm through its owner, so measure from a
// trustworthy origin -- and from a *served* one, because the worker here is a
// blob URL and an opaque origin cannot spawn one:
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-shapes-worker.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-shapes-worker.chrome.json.
(async () => {
  const NAMES = `AnimationTrigger CSPViolationReportBody CSSFontFeatureValuesRule
CSSFunctionDeclarations CSSFunctionDescriptors CSSFunctionRule CSSMarginRule
CSSNestedDeclarations CSSPositionTryDescriptors CSSPositionTryRule CSSScopeRule
CSSStartingStyleRule CSSViewTransitionRule CharacterBoundsUpdateEvent
ClipboardChangeEvent CommandEvent CrashReportContext HTMLGeolocationElement
HTMLSelectedContentElement HTMLUserMediaElement IntegrityViolationReportBody
InteractionContentfulPaint InterestEvent MediaStreamTrackVideoStats
NavigationPrecommitController NotRestoredReasonDetails NotRestoredReasons Origin
PageRevealEvent PageSwapEvent PerformanceLongAnimationFrameTiming
PerformanceScriptTiming PerformanceSoftNavigation ReportBody ScrollTimeline
SnapEvent TextFormat TextFormatUpdateEvent TextUpdateEvent TimelineTrigger
TimelineTriggerRange TimelineTriggerRangeList ViewTimeline Viewport WebGLObject
crashReport viewport`.split(/\s+/).filter(Boolean);

  const src = `
    const NAMES = ${JSON.stringify(NAMES)};
    const have = [], miss = [], shapes = {};
    for (const name of NAMES) {
      if (!Object.getOwnPropertyDescriptor(self, name)) { miss.push(name); continue; }
      have.push(name);
      const value = self[name];
      const entry = { typeof: typeof value };
      if (typeof value === 'function') {
        entry.length = value.length;
        const chain = [];
        for (let p = value.prototype; p && p !== Object.prototype; p = Object.getPrototypeOf(p)) {
          chain.push(p.constructor && p.constructor.name);
        }
        entry.protoChain = chain;
        if (value.prototype) {
          entry.protoMembers = Object.getOwnPropertyNames(value.prototype).map((k) => {
            const d = Object.getOwnPropertyDescriptor(value.prototype, k);
            if (d.get) return k + ':get';
            if (d.set) return k + ':set-only';
            return typeof d.value === 'function' ? k + ':method(' + d.value.length + ')' : k + ':value';
          });
        }
      }
      shapes[name] = entry;
    }
    self.postMessage({ have, miss, shapes });
  `;

  const worker = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
  const report = await new Promise((resolve) => {
    worker.onmessage = (e) => resolve(e.data);
    worker.onerror = (e) => resolve({ error: String(e.message || e) });
    setTimeout(() => resolve({ error: 'TIMEOUT' }), 5000);
  });

  return {
    href: location.href,
    isSecureContext: window.isSecureContext,
    ...report,
  };
})()
