(async () => {
  // Batch 11 behaviour: how Sensor / Web MIDI construct, throw and reject.
  const out = {};

  function err(e) {
    if (e === null || e === undefined) return String(e);
    return `${e.name}|${e.message}|${e.constructor && e.constructor.name}|code=${e.code}`;
  }
  function brand(o) {
    if (o === null) return 'null';
    if (typeof o !== 'object' && typeof o !== 'function') return typeof o;
    return Object.prototype.toString.call(o);
  }

  // sync-throw probes
  function sync(name, fn) {
    try {
      const v = fn();
      out[name] = { ok: true, brand: brand(v), v: typeof v === 'object' || typeof v === 'function' ? undefined : v };
    } catch (e) {
      out[name] = { threw: err(e) };
    }
  }

  // rejection probes — sync throw and rejection kept apart
  async function asy(name, fn) {
    let p;
    try { p = fn(); } catch (e) { out[name] = { syncThrew: err(e) }; return; }
    if (!p || typeof p.then !== 'function') { out[name] = { notAPromise: brand(p) }; return; }
    const TO = Symbol('to');
    const guard = new Promise((r) => setTimeout(() => r(TO), 2500));
    try {
      const v = await Promise.race([p, guard]);
      if (v === TO) { out[name] = { pendingAfter2500ms: true }; return; }
      out[name] = { resolved: brand(v) };
      return v;
    } catch (e) { out[name] = { rejected: err(e) }; }
  }

  const SENSORS = ['Sensor', 'Accelerometer', 'LinearAccelerationSensor', 'GravitySensor',
    'Gyroscope', 'OrientationSensor', 'AbsoluteOrientationSensor', 'RelativeOrientationSensor'];
  for (const n of SENSORS) {
    sync(`new ${n}()`, () => new window[n]());
    sync(`new ${n}({frequency:60})`, () => new window[n]({ frequency: 60 }));
    sync(`${n}() no new`, () => window[n]());
  }
  sync('new Accelerometer({frequency:"x"})', () => new Accelerometer({ frequency: 'x' }));
  sync('new AbsoluteOrientationSensor({referenceFrame:"screen"})', () => new AbsoluteOrientationSensor({ referenceFrame: 'screen' }));
  sync('new AbsoluteOrientationSensor({referenceFrame:"bogus"})', () => new AbsoluteOrientationSensor({ referenceFrame: 'bogus' }));

  // if a concrete sensor constructs, record its idle state and what start() does
  try {
    const a = new Accelerometer();
    out.accelIdle = {
      brand: brand(a),
      activated: a.activated, hasReading: a.hasReading, timestamp: a.timestamp,
      x: a.x, y: a.y, z: a.z,
      onerror: a.onerror, onreading: a.onreading, onactivate: a.onactivate,
    };
    const events = [];
    a.onerror = (e) => events.push(`error:${e.error ? err(e.error) : '?'}|target=${brand(e.target)}|type=${e.type}|ctor=${e.constructor.name}`);
    a.onactivate = (e) => events.push(`activate:${e.type}|ctor=${e.constructor.name}`);
    a.onreading = () => events.push('reading');
    let startThrew = null;
    try { a.start(); } catch (e) { startThrew = err(e); }
    await new Promise((r) => setTimeout(r, 1200));
    out.accelStart = { startThrew, events, activated: a.activated, hasReading: a.hasReading, timestamp: a.timestamp, x: a.x };
    let stopThrew = null;
    try { a.stop(); } catch (e) { stopThrew = err(e); }
    out.accelStop = { stopThrew, activated: a.activated };
    out.accelStopTwice = (() => { try { a.stop(); return 'ok'; } catch (e) { return err(e); } })();
  } catch (e) {
    out.accelIdle = { threw: err(e) };
  }
  try {
    const o = new RelativeOrientationSensor();
    out.orientIdle = { quaternion: o.quaternion, activated: o.activated };
    out.populateMatrixNoArg = (() => { try { o.populateMatrix(); return 'ok'; } catch (e) { return err(e); } })();
    out.populateMatrixFloat32x16 = (() => { try { o.populateMatrix(new Float32Array(16)); return 'ok'; } catch (e) { return err(e); } })();
    out.populateMatrixShort = (() => { try { o.populateMatrix(new Float32Array(4)); return 'ok'; } catch (e) { return err(e); } })();
    out.populateMatrixArray = (() => { try { o.populateMatrix([]); return 'ok'; } catch (e) { return err(e); } })();
  } catch (e) {
    out.orientIdle = { threw: err(e) };
  }

  // SensorErrorEvent
  sync('new SensorErrorEvent()', () => new SensorErrorEvent());
  sync('new SensorErrorEvent("e")', () => new SensorErrorEvent('e'));
  sync('new SensorErrorEvent("e",{})', () => new SensorErrorEvent('e', {}));
  try {
    const ev = new SensorErrorEvent('e', { error: new DOMException('boom', 'NotAllowedError') });
    out.sensorErrorEvent = { type: ev.type, error: err(ev.error), bubbles: ev.bubbles, cancelable: ev.cancelable, ctor: ev.constructor.name };
  } catch (e) { out.sensorErrorEvent = { threw: err(e) }; }
  sync('new SensorErrorEvent("e",{error:null})', () => new SensorErrorEvent('e', { error: null }));
  sync('new SensorErrorEvent("e",{error:1})', () => new SensorErrorEvent('e', { error: 1 }));

  // MIDI interfaces are all illegal constructors
  for (const n of ['MIDIAccess', 'MIDIPort', 'MIDIInput', 'MIDIOutput', 'MIDIInputMap', 'MIDIOutputMap']) {
    sync(`new ${n}()`, () => new window[n]());
    sync(`${n}() no new`, () => window[n]());
  }
  sync('new MIDIMessageEvent()', () => new MIDIMessageEvent());
  try {
    const m = new MIDIMessageEvent('midimessage');
    out.midiMessageEventDefault = { type: m.type, data: m.data, dataBrand: brand(m.data), ctor: m.constructor.name };
  } catch (e) { out.midiMessageEventDefault = { threw: err(e) }; }
  try {
    const m = new MIDIMessageEvent('midimessage', { data: new Uint8Array([0x90, 0x45, 0x7f]) });
    out.midiMessageEventData = { dataBrand: brand(m.data), bytes: Array.from(m.data), len: m.data.length };
  } catch (e) { out.midiMessageEventData = { threw: err(e) }; }
  sync('new MIDIMessageEvent("m",{data:[1,2]})', () => new MIDIMessageEvent('m', { data: [1, 2] }));
  sync('new MIDIConnectionEvent()', () => new MIDIConnectionEvent());
  try {
    const c = new MIDIConnectionEvent('statechange');
    out.midiConnectionEventDefault = { type: c.type, port: c.port, ctor: c.constructor.name };
  } catch (e) { out.midiConnectionEventDefault = { threw: err(e) }; }
  sync('new MIDIConnectionEvent("s",{port:null})', () => new MIDIConnectionEvent('s', { port: null }));
  sync('new MIDIConnectionEvent("s",{port:1})', () => new MIDIConnectionEvent('s', { port: 1 }));

  // navigator.requestMIDIAccess
  out.requestMIDIAccessType = typeof navigator.requestMIDIAccess;
  out.requestMIDIAccessArity = navigator.requestMIDIAccess && navigator.requestMIDIAccess.length;
  const acc = await asy('requestMIDIAccess()', () => navigator.requestMIDIAccess());
  if (acc) {
    out.midiAccess = {
      brand: brand(acc),
      sysexEnabled: acc.sysexEnabled,
      inputsBrand: brand(acc.inputs), outputsBrand: brand(acc.outputs),
      inputsSize: acc.inputs.size, outputsSize: acc.outputs.size,
      inputsIsMapProto: Object.getPrototypeOf(acc.inputs) === MIDIInputMap.prototype,
      onstatechange: acc.onstatechange,
      spread: [...acc.inputs].length,
      getMissing: acc.inputs.get('nope'),
      hasMissing: acc.inputs.has('nope'),
      keysBrand: brand(acc.inputs.keys()),
      identity: acc.inputs === acc.inputs,
    };
  }
  await asy('requestMIDIAccess({sysex:true})', () => navigator.requestMIDIAccess({ sysex: true }));
  await asy('requestMIDIAccess({software:true})', () => navigator.requestMIDIAccess({ software: true }));
  await asy('requestMIDIAccess(1)', () => navigator.requestMIDIAccess(1));
  await asy('requestMIDIAccess(null)', () => navigator.requestMIDIAccess(null));

  // permissions
  for (const name of ['accelerometer', 'gyroscope', 'magnetometer', 'midi', 'ambient-light-sensor']) {
    try { const s = await navigator.permissions.query({ name }); out[`perm:${name}`] = s.state; }
    catch (e) { out[`perm:${name}`] = err(e); }
  }

  return { href: location.href, secure: isSecureContext, out };
})()
