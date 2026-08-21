// The shape of the interfaces Chrome puts on the window and we do not, in
// enough detail to author each one: the prototype root, the prototype's own
// members in Chrome's order with their kind and arity, the interface object's
// arity, the toStringTag, and whether `new X()` is refused and with what
// wording.
//
// The name list is the pure-surface half of the secure-context diff -- the 47
// of the 83 missing names that no site uses as a capability gate (probe
// probe-secure-context.js produces the 83; the other 36 are SharedStorage, the
// fenced-frame family, the built-in AI family and friends, which are deliberately
// left absent).
//
// Measure on a trustworthy origin or the [SecureContext] members are missing
// from the reading:
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-shapes.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-shapes.chrome.json.
(() => {
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

  const out = {};
  for (const name of NAMES) {
    const desc = Object.getOwnPropertyDescriptor(window, name);
    if (!desc) { out[name] = { present: false }; continue; }

    const entry = {
      present: true,
      descriptor: { writable: desc.writable, enumerable: desc.enumerable, configurable: desc.configurable, accessor: !!(desc.get || desc.set) },
    };

    let value;
    try { value = window[name]; } catch (e) { entry.readThrew = String(e); }
    entry.typeof = typeof value;

    if (typeof value === 'function') {
      entry.length = value.length;
      entry.fnName = value.name;
      entry.fnSource = String(value);
      // The prototype chain of the interface object's .prototype, by name.
      const chain = [];
      let p = value.prototype;
      while (p) {
        const ctor = Object.getOwnPropertyDescriptor(p, 'constructor');
        chain.push((ctor && ctor.value && ctor.value.name) || Object.prototype.toString.call(p));
        p = Object.getPrototypeOf(p);
      }
      entry.protoChain = chain;
      if (value.prototype) {
        entry.protoMembers = Object.getOwnPropertyNames(value.prototype).map((k) => {
          const d = Object.getOwnPropertyDescriptor(value.prototype, k);
          const kind = d.get ? (d.set ? 'get/set' : 'get') : (d.set ? 'set' : (typeof d.value === 'function' ? 'method' : 'value'));
          const arity = typeof d.value === 'function' ? d.value.length : undefined;
          return arity === undefined ? `${k}:${kind}` : `${k}:${kind}(${arity})`;
        });
        const tag = Object.getOwnPropertyDescriptor(value.prototype, Symbol.toStringTag);
        entry.toStringTag = tag ? tag.value : null;
        entry.protoBrand = Object.prototype.toString.call(value.prototype);
      }
      entry.staticMembers = Object.getOwnPropertyNames(value).filter((k) => !['length', 'name', 'prototype'].includes(k));
      try { new value(); entry.newBare = 'constructed'; } catch (e) { entry.newBare = String(e); }
      try { new value('x'); entry.newOneArg = 'constructed'; } catch (e) { entry.newOneArg = String(e); }
      try { value(); entry.callBare = 'called'; } catch (e) { entry.callBare = String(e); }
    } else if (value && typeof value === 'object') {
      entry.brand = Object.prototype.toString.call(value);
      entry.ownProps = Object.getOwnPropertyNames(value);
      const chain = [];
      let p = Object.getPrototypeOf(value);
      while (p) {
        const ctor = Object.getOwnPropertyDescriptor(p, 'constructor');
        chain.push((ctor && ctor.value && ctor.value.name) || Object.prototype.toString.call(p));
        p = Object.getPrototypeOf(p);
      }
      entry.instanceProtoChain = chain;
      if (chain.length) {
        const proto = Object.getPrototypeOf(value);
        entry.instanceProtoMembers = Object.getOwnPropertyNames(proto);
      }
      // Values of the plain readable members, for the ones that are just data.
      const vals = {};
      for (const k of new Set([...entry.ownProps, ...(entry.instanceProtoMembers || [])])) {
        if (k === 'constructor') continue;
        try {
          const v = value[k];
          vals[k] = typeof v === 'function' ? 'function' : (v && typeof v === 'object' ? Object.prototype.toString.call(v) : v);
        } catch (e) { vals[k] = `threw: ${String(e)}`; }
      }
      entry.memberValues = vals;
    } else {
      entry.value = value;
    }
    out[name] = entry;
  }
  return { href: location.href, isSecureContext: window.isSecureContext, shapes: out };
})();
