// The nine Event subclasses probe-shapes.js found on the window and this engine
// did not have, read at the level an implementation needs: what each member
// answers on a default-constructed event, which dictionary members are required,
// what a non-object dictionary does, whether the EventInit members get through,
// and the exact refusal wording for every wrong shape.
//
// The interesting one is ClipboardChangeEvent: its arity is 0 and `new
// ClipboardChangeEvent('x')` complains the value is not a ClipboardChangeEventInit,
// so unlike every other Event subclass its first argument is the *dictionary* --
// there is no type argument at all. `bare.type` below is what it settles on.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s2-events.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s2-events.chrome.json.
(() => {
  const S = (fn) => { try { return fn(); } catch (e) { return String(e); } };
  const J = (v) => {
    if (v === undefined) return 'undefined';
    if (v === null) return 'null';
    // ClipboardChangeEvent's changeId is a BigInt, which JSON cannot carry.
    if (typeof v === 'bigint') return `bigint:${v}`;
    if (typeof v === 'object') return Object.prototype.toString.call(v);
    return v;
  };
  // Every own member of the event, whatever its prototype declares.
  const read = (e) => {
    if (typeof e === 'string') return e;
    const out = { type: e.type, bubbles: e.bubbles, cancelable: e.cancelable, composed: e.composed };
    let p = Object.getPrototypeOf(e);
    const stop = Event.prototype;
    while (p && p !== stop) {
      for (const k of Object.getOwnPropertyNames(p)) {
        if (k === 'constructor') continue;
        out[k] = S(() => { const v = e[k]; return typeof v === 'function' ? J(S(() => v.call(e))) : J(v); });
      }
      p = Object.getPrototypeOf(p);
    }
    return out;
  };

  const out = {};

  // The seven with a type argument and their own dictionary.
  for (const [name, filled] of [
    ['CommandEvent', { source: document.body, command: 'show-modal' }],
    ['InterestEvent', { source: document.body }],
    ['PageRevealEvent', { viewTransition: null }],
    ['PageSwapEvent', { viewTransition: null, activation: null }],
    ['TextUpdateEvent', { updateRangeStart: 1, updateRangeEnd: 2, text: 'hi', selectionStart: 3, selectionEnd: 4 }],
    ['TextFormatUpdateEvent', { textFormats: [] }],
    ['CharacterBoundsUpdateEvent', { rangeStart: 5, rangeEnd: 6 }],
  ]) {
    const C = window[name];
    out[name] = {
      bare: S(() => read(new C('t'))),
      filled: S(() => read(new C('t', filled))),
      // A non-object second argument: a typed dictionary refuses it, plain
      // EventInit shrugs.
      nonDict: S(() => read(new C('t', 5))),
      nullDict: S(() => read(new C('t', null))),
      // Do the EventInit members get through?
      eventInit: S(() => read(new C('t', { bubbles: true, cancelable: true, composed: true }))),
      // Type coercion of the first argument.
      numericType: S(() => new C(7).type),
      undefinedType: S(() => new C(undefined).type),
    };
  }

  // ClipboardChangeEvent: no type argument at all.
  out.ClipboardChangeEvent = {
    bare: S(() => read(new ClipboardChangeEvent())),
    filled: S(() => read(new ClipboardChangeEvent({ types: ['text/plain'], changeId: 3 }))),
    stringArg: S(() => new ClipboardChangeEvent('x').type),
    nullArg: S(() => read(new ClipboardChangeEvent(null))),
    undefinedArg: S(() => read(new ClipboardChangeEvent(undefined))),
    numberArg: S(() => new ClipboardChangeEvent(5).type),
    eventInit: S(() => read(new ClipboardChangeEvent({ bubbles: true, cancelable: true, composed: true }))),
    typesIdentity: S(() => {
      const e = new ClipboardChangeEvent({ types: ['text/plain'] });
      return { same: e.types === e.types, json: JSON.stringify(e.types), frozen: Object.isFrozen(e.types) };
    }),
    changeIdCoercion: S(() => J(new ClipboardChangeEvent({ changeId: '7' }).changeId)),
    changeIdFractional: S(() => J(new ClipboardChangeEvent({ changeId: 7.9 }).changeId)),
    changeIdNegative: S(() => J(new ClipboardChangeEvent({ changeId: -1 }).changeId)),
    changeIdBig: S(() => J(new ClipboardChangeEvent({ changeId: 2n ** 64n }).changeId)),
  };

  // changeId is a WebIDL `bigint`, so its conversion is ToBigInt rather than
  // any of the integer coercions -- a Number is refused outright while a string
  // is parsed, and the two failures are a TypeError and a SyntaxError
  // respectively. Both wordings matter: Chrome prefixes V8's own message.
  const named = (fn) => { try { const v = fn(); return typeof v === 'bigint' ? `bigint:${v}` : v; } catch (e) { return `${e.name}: ${e.message}`; } };
  const cid = (v) => named(() => new ClipboardChangeEvent({ changeId: v }).changeId);
  out.changeIdConversion = {
    bigint: cid(9n), zero: cid(0n), string7: cid('7'), stringEmpty: cid(''),
    stringSpace: cid('  12  '), stringHex: cid('0x10'), stringBad: cid('nope'),
    stringNeg: cid('-3'), stringFloat: cid('1.5'),
    number: cid(3), numberZero: cid(0), float: cid(1.5), neg: cid(-1),
    nul: cid(null), undef: cid(undefined), tru: cid(true), fals: cid(false),
    obj: cid({}), arr: cid([]),
    sym: named(() => new ClipboardChangeEvent({ changeId: Symbol('s') }).changeId),
    valueOf: cid({ valueOf: () => 5n }), toStringy: cid({ toString: () => '11' }),
  };

  // The sequence-typed members, and the interface-typed ones a page cannot hold.
  out.memberConversion = {
    typesString: named(() => JSON.stringify(new ClipboardChangeEvent({ types: 'ab' }).types)),
    typesNumber: named(() => JSON.stringify(new ClipboardChangeEvent({ types: 5 }).types)),
    typesNull: named(() => JSON.stringify(new ClipboardChangeEvent({ types: null }).types)),
    typesMixed: named(() => JSON.stringify(new ClipboardChangeEvent({ types: [1, null, 'x'] }).types)),
    commandSourceNonElement: named(() => new CommandEvent('t', { source: 5 }).source),
    commandSourceWindow: named(() => new CommandEvent('t', { source: window }).source),
    commandSourceTextNode: named(() => new CommandEvent('t', { source: document.createTextNode('x') }).source),
    interestSourceNonElement: named(() => new InterestEvent('t', { source: 5 }).source),
    commandCommandNumber: named(() => new CommandEvent('t', { command: 5 }).command),
    pageRevealViewTransition: named(() => new PageRevealEvent('t', { viewTransition: 5 }).viewTransition),
    pageSwapViewTransition: named(() => new PageSwapEvent('t', { viewTransition: 5 }).viewTransition),
    pageSwapActivation: named(() => new PageSwapEvent('t', { activation: 5 }).activation),
    textFormatsFresh: named(() => { const e = new TextFormatUpdateEvent('t'); return e.getTextFormats() === e.getTextFormats(); }),
    textFormatsNonSequence: named(() => JSON.stringify(new TextFormatUpdateEvent('t', { textFormats: 5 }).getTextFormats())),
    textFormatsBadItem: named(() => JSON.stringify(new TextFormatUpdateEvent('t', { textFormats: [5] }).getTextFormats())),
    textFormatsReal: named(() => new TextFormatUpdateEvent('t', { textFormats: [new TextFormat({ rangeStart: 1, rangeEnd: 2 })] }).getTextFormats().length),
  };

  // The `unsigned long` members are plain ToUint32 -- no [EnforceRange], no
  // [Clamp] -- so -1 wraps rather than throwing.
  out.unsignedLongConversion = {
    negative: named(() => new TextUpdateEvent('t', { updateRangeStart: -1 }).updateRangeStart),
    fractional: named(() => new TextUpdateEvent('t', { updateRangeStart: 2.7 }).updateRangeStart),
    past32Bits: named(() => new TextUpdateEvent('t', { updateRangeStart: 2 ** 33 }).updateRangeStart),
    nan: named(() => new TextUpdateEvent('t', { updateRangeStart: NaN }).updateRangeStart),
    numericString: named(() => new TextUpdateEvent('t', { updateRangeStart: '9' }).updateRangeStart),
    textNumber: named(() => new TextUpdateEvent('t', { text: 5 }).text),
    textNull: named(() => new TextUpdateEvent('t', { text: null }).text),
    boundsNegative: named(() => new CharacterBoundsUpdateEvent('t', { rangeStart: -1 }).rangeStart),
    boundsFractional: named(() => new CharacterBoundsUpdateEvent('t', { rangeEnd: 2.7 }).rangeEnd),
  };

  // SnapEvent: Illegal constructor, so only the prototype is reachable. Reading
  // a getter off the prototype itself is the one thing a page can still do.
  out.SnapEvent = {
    newBare: S(() => { new SnapEvent(); return 'constructed'; }),
    protoGetter: S(() => SnapEvent.prototype.snapTargetBlock),
    protoGetterInline: S(() => SnapEvent.prototype.snapTargetInline),
  };

  // The same illegal-constructor reading for the eight that ARE constructible,
  // as a control: reading a getter off the prototype rather than an instance.
  out.protoGetterOffInterface = {};
  for (const name of ['CommandEvent', 'InterestEvent', 'PageRevealEvent', 'PageSwapEvent',
    'TextUpdateEvent', 'TextFormatUpdateEvent', 'CharacterBoundsUpdateEvent', 'ClipboardChangeEvent']) {
    const proto = window[name].prototype;
    const first = Object.getOwnPropertyNames(proto).find((k) => k !== 'constructor');
    out.protoGetterOffInterface[name] = S(() => J(proto[first]));
  }

  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
