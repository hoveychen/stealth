(async () => {
  // Batch 12: the Permissions API -- the name table, the failure mode of each
  // rejection, and the PermissionStatus shape.
  const out = {};
  const err = (e) => e && `${e.name}|${e.message}|${e.constructor && e.constructor.name}`;

  // Every candidate name, and whether the answer is a state, a sync throw or a
  // rejection. Kept apart on purpose: which of the two it is, is the thing.
  const NAMES = [
    'geolocation', 'notifications', 'push', 'midi', 'camera', 'microphone', 'speaker',
    'device-info', 'background-fetch', 'background-sync', 'bluetooth', 'persistent-storage',
    'ambient-light-sensor', 'accelerometer', 'gyroscope', 'magnetometer', 'clipboard-read',
    'clipboard-write', 'display-capture', 'nfc', 'screen-wake-lock', 'system-wake-lock',
    'payment-handler', 'periodic-background-sync', 'storage-access', 'window-management',
    'local-fonts', 'top-level-storage-access', 'captured-surface-control', 'speaker-selection',
    'idle-detection', 'window-placement', 'accessibility-events', 'automatic-fullscreen',
    'web-app-installation', 'pointer-lock', 'keyboard-lock', 'smart-card',
    'protected-media-identifier', 'sensors', 'compute-pressure', 'hand-tracking',
    'xr-spatial-tracking', 'fullscreen', 'vr', 'ar', 'audio-capture', 'video-capture',
    'durable-storage', 'wake-lock', 'periodic-sync', 'bogus-name', '', 'GEOLOCATION',
  ];
  const names = {};
  for (const name of NAMES) {
    let p;
    try { p = navigator.permissions.query({ name }); } catch (e) { names[name] = { syncThrew: err(e) }; continue; }
    try { const s = await p; names[name] = { state: s.state, statusName: s.name }; }
    catch (e) { names[name] = { rejected: err(e) }; }
  }
  out.names = names;

  // Descriptor-level errors, sync vs rejection again.
  const desc = {};
  const probe = async (label, arg, hasArg = true) => {
    let p;
    try { p = hasArg ? navigator.permissions.query(arg) : navigator.permissions.query(); }
    catch (e) { desc[label] = { syncThrew: err(e) }; return; }
    try { const s = await p; desc[label] = { state: s.state, statusName: s.name }; }
    catch (e) { desc[label] = { rejected: err(e) }; }
  };
  await probe('noArg', undefined, false);
  await probe('{}', {});
  await probe('{name:undefined}', { name: undefined });
  await probe('{name:null}', { name: null });
  await probe('{name:1}', { name: 1 });
  await probe('1', 1);
  await probe('null', null);
  await probe('"x"', 'x');
  await probe('[]', []);
  await probe('push+uvo', { name: 'push', userVisibleOnly: true });
  await probe('push+uvo:false', { name: 'push', userVisibleOnly: false });
  await probe('midi+sysex', { name: 'midi', sysex: true });
  await probe('midi+sysex:false', { name: 'midi', sysex: false });
  await probe('geo+extra', { name: 'geolocation', bogus: 1 });
  await probe('camera+panTiltZoom', { name: 'camera', panTiltZoom: true });
  await probe('tlsa+origin', { name: 'top-level-storage-access', requestedOrigin: 'https://example.com' });
  out.descriptors = desc;

  // PermissionStatus and Permissions shapes.
  const st = await navigator.permissions.query({ name: 'geolocation' });
  const proto = Object.getPrototypeOf(st);
  const pd = (o, k) => {
    const d = Object.getOwnPropertyDescriptor(o, k);
    if (!d) return null;
    if ('value' in d) return { kind: 'value', t: typeof d.value, arity: typeof d.value === 'function' ? d.value.length : undefined, e: d.enumerable, c: d.configurable, w: d.writable };
    return { kind: 'accessor', get: !!d.get, set: !!d.set, e: d.enumerable, c: d.configurable };
  };
  out.status = {
    brand: Object.prototype.toString.call(st),
    protoKeys: Object.getOwnPropertyNames(proto),
    protoSyms: Object.getOwnPropertySymbols(proto).map(String),
    tag: proto[Symbol.toStringTag],
    chainIsEventTarget: Object.getPrototypeOf(proto) === EventTarget.prototype,
    name: st.name,
    state: st.state,
    onchange: st.onchange,
    ownKeys: Object.getOwnPropertyNames(st),
    isEventTarget: st instanceof EventTarget,
    hasAddEventListener: typeof st.addEventListener,
    descs: { name: pd(proto, 'name'), state: pd(proto, 'state'), onchange: pd(proto, 'onchange') },
    ctorArity: PermissionStatus.length,
    ctorName: PermissionStatus.name,
    winDesc: pd(window, 'PermissionStatus'),
    illegal: (() => { try { new PermissionStatus(); return 'ok'; } catch (e) { return err(e); } })(),
    identity: (await navigator.permissions.query({ name: 'geolocation' })) === st,
  };
  out.permissions = {
    brand: Object.prototype.toString.call(navigator.permissions),
    protoKeys: Object.getOwnPropertyNames(Permissions.prototype),
    protoSyms: Object.getOwnPropertySymbols(Permissions.prototype).map(String),
    queryArity: Permissions.prototype.query.length,
    ctorArity: Permissions.length,
    identity: navigator.permissions === navigator.permissions,
    illegal: (() => { try { new Permissions(); return 'ok'; } catch (e) { return err(e); } })(),
  };

  // onchange is a real handler slot even though nothing ever fires here.
  const fn = () => {};
  st.onchange = fn;
  out.onchangeReadsBack = st.onchange === fn;
  st.onchange = null;
  out.onchangeClears = st.onchange;
  out.onchangeNonFunction = (() => { st.onchange = 7; return st.onchange; })();

  return { href: location.href, secure: isSecureContext, out };
})()
