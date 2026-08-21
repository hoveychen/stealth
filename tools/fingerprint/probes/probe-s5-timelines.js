// The scroll-driven-animation family probe-shapes.js found on the window and
// this engine did not have. Three of the six are constructible from script --
// TimelineTrigger, ScrollTimeline and ViewTimeline -- so their dictionaries, the
// defaults every getter answers and the refusals a wrong value gets are all
// reachable; the other three (AnimationTrigger as the root, TimelineTriggerRange
// and TimelineTriggerRangeList) are illegal constructors.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s5-timelines.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s5-timelines.chrome.json.
(() => {
  const S = (fn) => {
    try {
      const v = fn();
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      return typeof v === 'object' ? Object.prototype.toString.call(v) : v;
    } catch (e) { return `${e.name}: ${e.message}`; }
  };
  const read = (obj, stopAt) => {
    const out = {};
    let p = Object.getPrototypeOf(obj);
    while (p && p !== stopAt) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (k === 'constructor') continue;
        out[k] = S(() => {
          const d = Object.getOwnPropertyDescriptor(p, k);
          return d.get ? d.get.call(obj) : d.value.call(obj);
        });
      }
      p = Object.getPrototypeOf(p);
    }
    return JSON.stringify(out);
  };

  const out = {};

  // Symbols on the prototypes: getOwnPropertyNames hides them, and whether the
  // list is iterable is part of its shape.
  out.protoSymbols = {};
  for (const n of ['AnimationTrigger', 'TimelineTrigger', 'TimelineTriggerRange',
    'TimelineTriggerRangeList', 'ScrollTimeline', 'ViewTimeline']) {
    out.protoSymbols[n] = Object.getOwnPropertySymbols(window[n].prototype).map(String);
  }

  // TimelineTrigger: `new TimelineTrigger()` works, and the one argument is a
  // sequence of TimelineTriggerRange -- an interface a page cannot hold one of.
  out.timelineTrigger = {
    bare: S(() => read(new TimelineTrigger(), Object.prototype)),
    rangesBrand: S(() => Object.prototype.toString.call(new TimelineTrigger().ranges)),
    rangesLength: S(() => new TimelineTrigger().ranges.length),
    rangesIdentity: S(() => { const t = new TimelineTrigger(); return t.ranges === t.ranges; }),
    rangesIterable: S(() => [...new TimelineTrigger().ranges].length),
    rangesItem: S(() => new TimelineTrigger().ranges.item(0)),
    rangesItemNoArg: S(() => new TimelineTrigger().ranges.item()),
    rangesIndex: S(() => new TimelineTrigger().ranges[0]),
    emptyArray: S(() => new TimelineTrigger([]).ranges.length),
    nonSequence: S(() => new TimelineTrigger('x')),
    numberArg: S(() => new TimelineTrigger(5)),
    nullArg: S(() => new TimelineTrigger(null)),
    undefinedArg: S(() => new TimelineTrigger(undefined).ranges.length),
    badItem: S(() => new TimelineTrigger([5])),
    // The three AnimationTrigger methods, on a real instance.
    getAnimations: S(() => JSON.stringify(new TimelineTrigger().getAnimations())),
    addAnimationNoArgs: S(() => new TimelineTrigger().addAnimation()),
    addAnimationOne: S(() => new TimelineTrigger().addAnimation(document.body.animate([], 1))),
    removeAnimationNoArgs: S(() => new TimelineTrigger().removeAnimation()),
    removeAnimationOne: S(() => new TimelineTrigger().removeAnimation(document.body.animate([], 1))),
  };

  // ScrollTimeline / ViewTimeline: both take one optional dictionary.
  for (const [name, dict, filled] of [
    ['ScrollTimeline', 'ScrollTimelineOptions', { source: document.documentElement, axis: 'x' }],
    ['ViewTimeline', 'ViewTimelineOptions', { subject: document.body, axis: 'x', inset: '10px' }],
  ]) {
    const C = window[name];
    out[name] = {
      bare: S(() => read(new C(), Object.prototype)),
      filled: S(() => read(new C(filled), Object.prototype)),
      sourceIdentity: name === 'ScrollTimeline'
        ? S(() => new C({ source: document.documentElement }).source === document.documentElement)
        : S(() => new C({ subject: document.body }).subject === document.body),
      nonDict: S(() => new C(5)),
      nullDict: S(() => read(new C(null), Object.prototype)),
      badAxis: S(() => new C({ axis: 'nope' })),
      badSource: S(() => new C(name === 'ScrollTimeline' ? { source: 5 } : { subject: 5 })),
      nullSource: S(() => S(() => new C(name === 'ScrollTimeline' ? { source: null } : { subject: null }).source)),
      // AnimationTimeline's inherited members on a live one.
      currentTime: S(() => new C().currentTime),
      duration: S(() => new C().duration),
    };
  }
  out.viewTimelineInset = {
    bad: S(() => new ViewTimeline({ inset: 'nope' })),
    two: S(() => new ViewTimeline({ inset: '10px 20px' }).startOffset),
    auto: S(() => new ViewTimeline({ inset: 'auto' }).startOffset),
  };

  // The three that cannot be built: reading a member off the prototype.
  out.unreachable = {};
  for (const n of ['AnimationTrigger', 'TimelineTriggerRange', 'TimelineTriggerRangeList']) {
    const proto = window[n].prototype;
    const per = {};
    for (const k of Object.getOwnPropertyNames(proto)) {
      if (k === 'constructor') continue;
      per[k] = S(() => {
        const d = Object.getOwnPropertyDescriptor(proto, k);
        return d.get ? d.get.call(proto) : d.value.call(proto);
      });
    }
    out.unreachable[n] = per;
  }

  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
