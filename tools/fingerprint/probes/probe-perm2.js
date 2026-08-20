(async () => {
  const out = {}; const err=(e)=>e&&`${e.name}|${e.message}`;
  const probe = async (label, arg) => {
    let p; try { p = navigator.permissions.query(arg); } catch (e) { out[label]='SYNC '+err(e); return; }
    try { const s = await p; out[label] = { state: s.state, name: s.name }; } catch (e) { out[label] = 'REJECT '+err(e); }
  };
  await probe('fullscreen+awg', { name: 'fullscreen', allowWithoutGesture: true });
  await probe('fullscreen+awg:false', { name: 'fullscreen', allowWithoutGesture: false });
  await probe('tlsa+badorigin', { name: 'top-level-storage-access', requestedOrigin: 'notaurl' });
  await probe('tlsa+origin', { name: 'top-level-storage-access', requestedOrigin: 'https://example.com' });
  await probe('camera+ptz:false', { name: 'camera', panTiltZoom: false });
  await probe('mic+ptz', { name: 'microphone', panTiltZoom: true });
  // is `name` an own or inherited read? and does a second query give a fresh object
  const a = await navigator.permissions.query({ name: 'accelerometer' });
  const b = await navigator.permissions.query({ name: 'gyroscope' });
  out.sensorNames = [a.name, b.name, a === b];
  // toStringTag on Permissions.prototype
  out.permTag = Permissions.prototype[Symbol.toStringTag];
  out.statusTag = PermissionStatus.prototype[Symbol.toStringTag];
  // navigator.permissions descriptor
  const d = Object.getOwnPropertyDescriptor(Navigator.prototype, 'permissions');
  out.navDesc = d ? { get: !!d.get, set: !!d.set, e: d.enumerable, c: d.configurable } : 'own?';
  return out;
})()
