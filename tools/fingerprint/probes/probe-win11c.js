(async () => {
  // Batch 11, round 2: the details the shape and first behaviour pass left open.
  const out = {};
  const err = (e) => e && `${e.name}|${e.message}`;
  const sync = (n, f) => { try { out[n] = { ok: true, v: f() }; } catch (e) { out[n] = { threw: err(e) }; } };

  // --- data / error identity and copying ---
  const u8 = new Uint8Array([1, 2, 3]);
  const mm = new MIDIMessageEvent('m', { data: u8 });
  out.dataIdentityWithInit = mm.data === u8;
  out.dataStableAcrossReads = mm.data === mm.data;
  out.dataMutationVisible = (() => { u8[0] = 9; return mm.data[0]; })();
  const de = new DOMException('boom', 'NotAllowedError');
  const see = new SensorErrorEvent('e', { error: de });
  out.errorIdentity = see.error === de;
  out.errorStable = see.error === see.error;

  // --- data accepts other views? ---
  sync('data:Uint8ClampedArray', () => new MIDIMessageEvent('m', { data: new Uint8ClampedArray([1]) }).data.length);
  sync('data:Int8Array', () => new MIDIMessageEvent('m', { data: new Int8Array([1]) }).data.length);
  sync('data:ArrayBuffer', () => new MIDIMessageEvent('m', { data: new ArrayBuffer(2) }).data.length);
  sync('data:undefined', () => String(new MIDIMessageEvent('m', { data: undefined }).data));
  sync('data:null', () => String(new MIDIMessageEvent('m', { data: null }).data));
  sync('port:undefined', () => String(new MIDIConnectionEvent('s', { port: undefined }).port));

  // --- Event init members still work on these subclasses ---
  const bub = new MIDIMessageEvent('m', { bubbles: true, cancelable: true, composed: true });
  out.eventInit = { bubbles: bub.bubbles, cancelable: bub.cancelable, composed: bub.composed, isTrusted: bub.isTrusted };

  // --- brand checks / illegal invocation ---
  sync('MIDIMessageEvent.data on Event', () => Object.getOwnPropertyDescriptor(MIDIMessageEvent.prototype, 'data').get.call(new Event('x')));
  sync('Sensor.activated on plain', () => Object.getOwnPropertyDescriptor(Sensor.prototype, 'activated').get.call({}));
  sync('Sensor.start on plain', () => Sensor.prototype.start.call({}));
  sync('Sensor.activated on Accelerometer', () => Object.getOwnPropertyDescriptor(Sensor.prototype, 'activated').get.call(new Accelerometer()));

  // --- frequency edge cases ---
  for (const f of [0, -1, Infinity, NaN, 1e9, '60', null]) {
    sync(`frequency:${String(f)}`, () => { new Accelerometer({ frequency: f }); return 'constructed'; });
  }
  sync('options:null', () => { new Accelerometer(null); return 'constructed'; });
  sync('options:1', () => { new Accelerometer(1); return 'constructed'; });
  sync('options:"x"', () => { new Accelerometer('x'); return 'constructed'; });

  // --- start()/stop() state machine ---
  const a = new Accelerometer();
  const seen = [];
  a.addEventListener('error', (e) => seen.push(`listener:${e.error.name}:${e.error.message}:${e.type}:${e.bubbles}:${e.cancelable}:${e.isTrusted}:${Object.prototype.toString.call(e)}`));
  a.start();
  out.activatedRightAfterStart = a.activated;
  out.startTwice = (() => { try { a.start(); return 'ok'; } catch (e) { return err(e); } })();
  out.microtaskAfterStart = await Promise.resolve().then(() => seen.length);
  await new Promise((r) => setTimeout(r, 0));
  out.afterTimeout0 = seen.length;
  await new Promise((r) => setTimeout(r, 800));
  out.afterTimeout800 = seen.slice();
  out.activatedAfterError = a.activated;

  // start again after the failure: does it error a second time?
  seen.length = 0;
  a.stop();
  a.start();
  await new Promise((r) => setTimeout(r, 800));
  out.secondRound = seen.slice();

  // stop() before the error lands
  const b = new Gyroscope();
  const bseen = [];
  b.onerror = () => bseen.push('err');
  b.start();
  b.stop();
  await new Promise((r) => setTimeout(r, 800));
  out.stoppedBeforeError = bseen.slice();

  // --- populateMatrix with DOMMatrix ---
  const o = new RelativeOrientationSensor();
  sync('populateMatrix(DOMMatrix)', () => { o.populateMatrix(new DOMMatrix()); return 'ok'; });
  sync('populateMatrix(Float64Array16)', () => { o.populateMatrix(new Float64Array(16)); return 'ok'; });
  sync('populateMatrix(null)', () => { o.populateMatrix(null); return 'ok'; });

  // --- prototype descriptor enumerability spot-check ---
  const d = Object.getOwnPropertyDescriptor(Sensor.prototype, 'start');
  out.startDesc = { e: d.enumerable, c: d.configurable, w: d.writable };
  const g = Object.getOwnPropertyDescriptor(Sensor.prototype, 'activated');
  out.activatedDesc = { e: g.enumerable, c: g.configurable };
  out.toStringTagDesc = Object.getOwnPropertyDescriptor(Sensor.prototype, Symbol.toStringTag);
  out.midiMapIteratorSame = MIDIInputMap.prototype[Symbol.iterator] === MIDIInputMap.prototype.entries;
  out.midiMapTag = MIDIInputMap.prototype[Symbol.toStringTag];
  out.sensorProtoTag = Sensor.prototype[Symbol.toStringTag];

  // --- sensor toString ---
  out.sensorToString = String(Sensor);
  out.accelToString = String(Accelerometer);

  return { href: location.href, out };
})()
