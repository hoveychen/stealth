// The scroll-driven-animation family probe-shapes.js found on the window and
// this engine did not have. Three of the six have constructors --
// TimelineTrigger, ScrollTimeline and ViewTimeline -- and the other three
// (AnimationTrigger as the root, TimelineTriggerRange, TimelineTriggerRangeList)
// are illegal constructors.
//
// Illegal does not mean unreachable, which is the reading that took four rounds
// to get right. `new TimelineTrigger([5])` is refused as "not of type
// 'TimelineTriggerOptions'" while `([null])` and `([document.timeline])` both
// *succeed*, so that argument is a sequence of **dictionaries**, not of ranges:
// a page builds a TimelineTriggerRange by passing a dictionary and reads it back
// off `ranges`. So five of the six have live instances and only
// TimelineTriggerRangeList's own constructor is out of reach.
//
// Which members each dictionary declares is read off a Proxy rather than
// guessed (`dictMembers`, `rangeOffset.members`): Chrome's binding touches
// exactly the declared members in its own order, so the trap log is the WebIDL
// declaration.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s5-timelines.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s5-timelines.chrome.json. The `numbers` block mutates
// the document (a tall body, then a scroll) because a scroll-driven timeline's
// currentTime is null until its source can actually scroll -- so anything after
// it reads a scrolled document.
(async () => {
  const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
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

  // What the CSSUnitValues actually *say*. The readings above only recorded the
  // brand, and "[object CSSUnitValue]" is not enough to implement a getter --
  // the number and the unit are the part a page reads. Taken in three states,
  // because a scroll-driven timeline's progress depends on layout: the bare
  // document (nothing scrolls), a document tall enough to scroll, and that same
  // document scrolled to a known offset.
  const U = (fn) => {
    const v = S(fn);
    if (typeof v !== 'string' || v !== '[object CSSUnitValue]') return v;
    const u = fn();
    return `${u.value}${u.unit}`;
  };
  const sample = (label) => ({
    scrollDuration: U(() => new ScrollTimeline().duration),
    scrollCurrentTime: U(() => new ScrollTimeline().currentTime),
    viewDuration: U(() => new ViewTimeline().duration),
    viewCurrentTime: U(() => new ViewTimeline().currentTime),
    subjectDuration: U(() => new ViewTimeline({ subject: document.getElementById('subject') }).duration),
    subjectCurrentTime: U(() => new ViewTimeline({ subject: document.getElementById('subject') }).currentTime),
    subjectStartOffset: U(() => new ViewTimeline({ subject: document.getElementById('subject') }).startOffset),
    subjectEndOffset: U(() => new ViewTimeline({ subject: document.getElementById('subject') }).endOffset),
    documentDuration: S(() => document.timeline.duration),
    documentCurrentTimeType: S(() => typeof document.timeline.currentTime),
    // Whether two reads answer the same object, which a page can see.
    durationIdentity: S(() => { const t = new ScrollTimeline(); return t.duration === t.duration; }),
    scrollY: scrollY,
    label,
  });

  out.numbers = { bare: sample('bare') };
  document.body.style.margin = '0';
  document.body.innerHTML = '<div id="subject" style="height:100px"></div><div style="height:5000px"></div>';
  await frame();
  out.numbers.tall = sample('tall');
  scrollTo(0, 1000);
  await frame();
  out.numbers.scrolled = sample('scrolled');

  // The edges an implementation has to pick a side on and the readings above do
  // not settle: which values count as a sequence, which axis names the enum
  // takes, what `inset` accepts, and what the second addAnimation argument is
  // for. Taken last, on the scrolled document the block above built.
  const subject = () => document.getElementById('subject');
  out.edges = {
    // Is the sequence check `Array.isArray` or real iterability?
    plainObject: S(() => new TimelineTrigger({}).ranges.length),
    emptySet: S(() => new TimelineTrigger(new Set()).ranges.length),
    customIterable: S(() => new TimelineTrigger({ [Symbol.iterator]: function* () {} }).ranges.length),
    arrayLike: S(() => new TimelineTrigger({ length: 0 }).ranges.length),
    // A sequence whose item is the wrong thing: does the message name the item's
    // interface or the options dictionary?
    wrongItem: S(() => new TimelineTrigger([document.timeline])),
    nullItem: S(() => new TimelineTrigger([null])),
    twoBadItems: S(() => new TimelineTrigger([5, 5])),
    // ScrollAxis: every name, and the two spellings a page might guess.
    axes: Object.fromEntries(['block', 'inline', 'x', 'y', 'horizontal', ''].map((a) =>
      [a || '(empty)', S(() => new ScrollTimeline({ axis: a }).axis)])),
    axisUndefined: S(() => new ScrollTimeline({ axis: undefined }).axis),
    axisNull: S(() => new ScrollTimeline({ axis: null }).axis),
    axisNumber: S(() => new ScrollTimeline({ axis: 5 }).axis),
    // inset, the one member with a bespoke refusal.
    insets: Object.fromEntries(['auto', '0px', '10px', '10px 20px', '10px 20px 30px', '10%',
      'auto auto', '10px auto', 'nope', '', 'inherit'].map((i) =>
      [i || '(empty)', S(() => new ViewTimeline({ subject: subject(), inset: i }).startOffset)])),
    insetNumber: S(() => new ViewTimeline({ subject: subject(), inset: 5 })),
    insetNull: S(() => new ViewTimeline({ subject: subject(), inset: null }).startOffset),
    insetArray: S(() => new ViewTimeline({ subject: subject(), inset: [] })),
    insetOnly: S(() => new ViewTimeline({ inset: 'nope' })),
    // Does ViewTimelineOptions carry a `source`, or is it always derived?
    viewSourceIgnored: S(() => new ViewTimeline({ subject: subject(), source: document.body }).source),
    // addAnimation's second argument.
    addTwo: S(() => new TimelineTrigger().addAnimation(subject().animate([], 1), {})),
    addTwoNull: S(() => new TimelineTrigger().addAnimation(subject().animate([], 1), null)),
    addTwoNumber: S(() => new TimelineTrigger().addAnimation(subject().animate([], 1), 5)),
    addBadFirst: S(() => new TimelineTrigger().addAnimation(5, {})),
    addThenGet: S(() => {
      const t = new TimelineTrigger();
      t.addAnimation(subject().animate([], 1), {});
      return t.getAnimations().length;
    }),
    removeUnknown: S(() => new TimelineTrigger().removeAnimation(subject().animate([], 1))),
    removeBad: S(() => new TimelineTrigger().removeAnimation(5)),
    getAnimationsIdentity: S(() => { const t = new TimelineTrigger(); return t.getAnimations() === t.getAnimations(); }),
    // Can a timeline drive an animation? That is the only way a page reaches a
    // scroll timeline's effect, and it says whether Animation accepts one.
    animateWithScrollTimeline: S(() =>
      Object.prototype.toString.call(subject().animate([], { duration: 1, timeline: new ScrollTimeline() }).timeline)),
  };

  // `new TimelineTrigger([null])` and `([document.timeline])` both *succeed*
  // while `([5])` does not, which only fits one reading: the argument is a
  // sequence of *dictionaries*, so a TimelineTriggerRange is reachable after all
  // and its five getters have to answer something real.
  //
  // Which members each dictionary declares is read off a Proxy rather than
  // guessed: Chrome's binding touches exactly the declared members, in its own
  // order, so the trap log *is* the WebIDL declaration.
  const spy = () => {
    const seen = [];
    const p = new Proxy({}, {
      get(_, k) { seen.push(String(k)); return undefined; },
      has() { return true; },
    });
    return { seen, p };
  };
  const spyOn = (fn) => {
    const { seen, p } = spy();
    const outcome = S(() => fn(p));
    return { members: seen, outcome };
  };
  out.dictMembers = {
    TimelineTriggerOptions: spyOn((p) => new TimelineTrigger([p])),
    ScrollTimelineOptions: spyOn((p) => new ScrollTimeline(p)),
    ViewTimelineOptions: spyOn((p) => new ViewTimeline(p)),
  };

  // A real TimelineTriggerRange, built through that sequence.
  const range = (opts) => S(() => read(new TimelineTrigger([opts]).ranges.item(0), Object.prototype));
  out.ranges = {
    lengthNull: S(() => new TimelineTrigger([null]).ranges.length),
    lengthTwo: S(() => new TimelineTrigger([{}, {}]).ranges.length),
    itemBrand: S(() => Object.prototype.toString.call(new TimelineTrigger([{}]).ranges.item(0))),
    itemIdentity: S(() => { const t = new TimelineTrigger([{}]); return t.ranges.item(0) === t.ranges.item(0); }),
    spread: S(() => [...new TimelineTrigger([{}, {}]).ranges].length),
    indexAfterFill: S(() => new TimelineTrigger([{}]).ranges[0]),
    itemPastEnd: S(() => new TimelineTrigger([{}]).ranges.item(1)),
    itemNegative: S(() => new TimelineTrigger([{}]).ranges.item(-1)),
    bare: range({}),
    empty: range(null),
    withTimeline: range({ timeline: document.timeline }),
    withScrollTimeline: range({ timeline: new ScrollTimeline() }),
    withNullTimeline: range({ timeline: null }),
    withNumberTimeline: S(() => new TimelineTrigger([{ timeline: 5 }])),
    forEachCount: S(() => { let n = 0; new TimelineTrigger([{}, {}]).ranges.forEach(() => n++); return n; }),
    forEachArgs: S(() => {
      let shape = '';
      new TimelineTrigger([{}]).ranges.forEach((v, i, l) =>
        shape = `${Object.prototype.toString.call(v)}|${i}|${Object.prototype.toString.call(l)}`);
      return shape;
    }),
    entriesFirst: S(() => JSON.stringify([...new TimelineTrigger([{}]).ranges.entries()]
      .map(([i, v]) => [i, Object.prototype.toString.call(v)]))),
    keys: S(() => JSON.stringify([...new TimelineTrigger([{}, {}]).ranges.keys()])),
  };

  // AnimationTriggerBehavior: which names the enum takes.
  out.behaviours = Object.fromEntries(['once', 'repeat', 'alternate', 'state', 'play', 'pause', 'none']
    .map((b) => [b, S(() => new TimelineTrigger().addAnimation(subject().animate([], 1), b))]));
  out.behaviourEffect = S(() => {
    const t = new TimelineTrigger();
    t.addAnimation(subject().animate([], 1), 'once');
    return t.getAnimations().length;
  });

  // inset's sequence branch, which `inset: []` proved exists.
  out.insetSequence = {
    empty: S(() => Object.prototype.toString.call(new ViewTimeline({ subject: subject(), inset: [] }).startOffset)),
    oneUnit: S(() => new ViewTimeline({ subject: subject(), inset: [CSS.px(10)] }).startOffset),
    twoUnits: S(() => new ViewTimeline({ subject: subject(), inset: [CSS.px(10), CSS.px(20)] }).startOffset),
    threeUnits: S(() => new ViewTimeline({ subject: subject(), inset: [CSS.px(1), CSS.px(2), CSS.px(3)] })),
    numbers: S(() => new ViewTimeline({ subject: subject(), inset: [5] })),
    strings: S(() => new ViewTimeline({ subject: subject(), inset: ['10px'] })),
    percent: S(() => new ViewTimeline({ subject: subject(), inset: [CSS.percent(10)] }).startOffset),
  };

  // The four string members of a range: whether the value is echoed back as
  // given, normalised, or refused.
  const member = (name) => Object.fromEntries([
    'normal', 'auto', 'cover', 'contain', 'entry', 'exit', 'cover 0%', 'entry 50%',
    'cover 0% cover 100%', '0px', 'nope', '',
  ].map((v) => [v || '(empty)', S(() => new TimelineTrigger([{ [name]: v }]).ranges.item(0)[name])]));
  out.rangeMembers = {
    activationRangeStart: member('activationRangeStart'),
    activeRangeStart: member('activeRangeStart'),
    // Non-strings, on the one member, to see whether it is a DOMString at all.
    coercions: Object.fromEntries([['number', 5], ['null', null], ['object', {}], ['array', []]]
      .map(([label, v]) => [label, S(() => new TimelineTrigger([{ activationRangeStart: v }])
        .ranges.item(0).activationRangeStart)])),
    // Do the two halves of a pair stay independent?
    pair: S(() => {
      const r = new TimelineTrigger([{ activationRangeStart: 'cover', activationRangeEnd: 'contain' }]).ranges.item(0);
      return `${r.activationRangeStart}|${r.activationRangeEnd}`;
    }),
    timelineIdentity: S(() => new TimelineTrigger([{ timeline: document.timeline }])
      .ranges.item(0).timeline === document.timeline),
    defaultTimelineIdentity: S(() => new TimelineTrigger([{}]).ranges.item(0).timeline === document.timeline),
  };

  // addAnimation with a behaviour the enum accepts, which is the only way the
  // trigger's animation list changes.
  out.addAnimation = {
    playThenGet: S(() => {
      const t = new TimelineTrigger();
      t.addAnimation(subject().animate([], 1), 'play');
      return t.getAnimations().length;
    }),
    twiceSame: S(() => {
      const t = new TimelineTrigger();
      const a = subject().animate([], 1);
      t.addAnimation(a, 'play');
      t.addAnimation(a, 'play');
      return t.getAnimations().length;
    }),
    twoAnimations: S(() => {
      const t = new TimelineTrigger();
      t.addAnimation(subject().animate([], 1), 'play');
      t.addAnimation(subject().animate([], 1), 'pause');
      return t.getAnimations().length;
    }),
    addThenRemove: S(() => {
      const t = new TimelineTrigger();
      const a = subject().animate([], 1);
      t.addAnimation(a, 'play');
      t.removeAnimation(a);
      return t.getAnimations().length;
    }),
    entryBrand: S(() => {
      const t = new TimelineTrigger();
      t.addAnimation(subject().animate([], 1), 'play');
      return Object.prototype.toString.call(t.getAnimations()[0]);
    }),
    animationIdentity: S(() => {
      const t = new TimelineTrigger();
      const a = subject().animate([], 1);
      t.addAnimation(a, 'play');
      return t.getAnimations()[0] === a;
    }),
    behaviourMissing: S(() => new TimelineTrigger().addAnimation(subject().animate([], 1))),
    behaviourUndefined: S(() => new TimelineTrigger().addAnimation(subject().animate([], 1), undefined)),
  };

  // inset's remaining shapes, and what it does to the numbers.
  const insetOffset = (i) => S(() => {
    const t = new ViewTimeline({ subject: subject(), inset: i });
    return `${t.startOffset.value}${t.startOffset.unit}|${t.endOffset.value}${t.endOffset.unit}`;
  });
  out.insetNumbers = {
    none: insetOffset(undefined),
    auto: insetOffset('auto'),
    tenPx: insetOffset('10px'),
    twoLengths: insetOffset('10px 20px'),
    percent: insetOffset('10%'),
    autoString: S(() => new ViewTimeline({ subject: subject(), inset: ['auto'] }).startOffset),
    unitAndAuto: S(() => new ViewTimeline({ subject: subject(), inset: [CSS.px(10), 'auto'] }).startOffset),
    twoAutos: S(() => new ViewTimeline({ subject: subject(), inset: ['auto', 'auto'] }).startOffset),
    emptySequence: insetOffset([]),
    unitSequence: insetOffset([CSS.px(10)]),
  };

  // A range member handed an *object* reads back as an object, so the member is
  // not a DOMString but a union with a dictionary. What that dictionary is:
  const offsetOf = (v) => S(() => JSON.stringify(
    new TimelineTrigger([{ activationRangeStart: v }]).ranges.item(0).activationRangeStart));
  out.rangeOffset = {
    fromNull: offsetOf(null),
    fromEmpty: offsetOf({}),
    fromArray: offsetOf([]),
    fromNamed: offsetOf({ rangeName: 'cover' }),
    keys: S(() => JSON.stringify(Object.keys(
      new TimelineTrigger([{ activationRangeStart: {} }]).ranges.item(0).activationRangeStart))),
    members: spyOn((p) => new TimelineTrigger([{ activationRangeStart: p }])),
    stringStaysString: S(() => typeof new TimelineTrigger([{ activationRangeStart: 'cover' }])
      .ranges.item(0).activationRangeStart),
  };

  // The grammar of the string branch, since "must be a name <length-percent>
  // pair" is a rule an implementation has to apply rather than echo. Every
  // token class, on both a member that defaults to 'normal' and one that
  // defaults to 'auto'.
  const grammar = (name) => Object.fromEntries([
    'entry-crossing', 'exit-crossing', 'cover 100%', '50%', '10px', '-10px', '10em',
    'cover 10px', 'cover -5%', 'cover cover', 'normal 0%', 'auto 0%', '0% cover',
    'COVER', 'Cover 50%', 'cover  50%', ' cover 50% ', 'cover 50', 'cover 0%extra',
    'calc(10px + 5%)', 'var(--x)', 'none', 'initial',
  ].map((v) => [v, S(() => new TimelineTrigger([{ [name]: v }]).ranges.item(0)[name])]));
  out.grammar = {
    activation: grammar('activationRangeStart'),
    active: grammar('activeRangeEnd'),
  };

  // Property descriptors and symbols, rendered exactly the way tests/shape.js
  // renders them, so the expected strings can be pasted straight across.
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;
  const shapeOf = (o) => {
    const list = [];
    for (const k of Object.getOwnPropertyNames(o)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (d.get || d.set) list.push(`${d.get ? (d.set ? 'accessor' : 'get') : 'set'} ${k}[${flags(d)}]`);
      else if (typeof d.value === 'function') list.push(`${k}/${d.value.length}[${flags(d)}]`);
      else list.push(`${k}=${String(d.value)}[${flags(d)}]`);
    }
    for (const s of Object.getOwnPropertySymbols(o)) {
      const v = o[s];
      list.push(`@@${String(s).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${typeof v === 'function' ? `fn:${v.name}` : String(v)}`);
    }
    return list.join(',');
  };
  out.shapes = Object.fromEntries(['AnimationTrigger', 'TimelineTrigger', 'TimelineTriggerRange',
    'TimelineTriggerRangeList', 'ScrollTimeline', 'ViewTimeline', 'AnimationTimeline']
    .map((n) => [n, shapeOf(window[n].prototype)]));

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
