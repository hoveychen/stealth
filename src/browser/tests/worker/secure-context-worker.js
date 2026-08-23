// Reports the worker realm's own secure-context state, the shape of the
// property, and how much of the [SecureContext] surface it can see. Measured on
// a headed Chrome 151: from http://localhost:8777 a worker answers true and has
// 336 own names, from http://192.168.68.78:8777 it answers false and has 243,
// and isSecureContext is an enumerable, configurable getter on
// WorkerGlobalScope.prototype.
//
// The gated names below are the ones this engine has in the worker realm out of
// the 234 it used to leak in the window realm.
const GATED = [
  'CryptoKey', 'FileSystemDirectoryHandle', 'FileSystemFileHandle',
  'FileSystemHandle', 'FileSystemSyncAccessHandle',
  'FileSystemWritableFileStream', 'IdleDetector', 'StorageManager',
  'SubtleCrypto', 'WebTransport', 'WebTransportBidirectionalStream',
  'WebTransportDatagramDuplexStream', 'WebTransportError',
];
// Not [SecureContext]: present whatever the owner's origin.
const UNGATED = ['fetch', 'atob', 'crypto', 'Blob', 'Headers', 'Response'];

self.onmessage = () => {
  const shape = (d) => d === undefined ? null : {
    is_getter: typeof d.get === 'function',
    has_setter: d.set !== undefined,
    enumerable: d.enumerable,
    configurable: d.configurable,
  };

  // Above `self`, so the answer is about the interface prototype object rather
  // than about the [Global] flattening that mirrors members onto the global.
  let holder = null, on_prototype = null;
  for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
    const d = Object.getOwnPropertyDescriptor(o, 'isSecureContext');
    if (d) {
      holder = (o.constructor && o.constructor.name) || '?';
      on_prototype = shape(d);
      break;
    }
  }

  const present = (names) => names.filter((n) => n in self);

  postMessage({
    worker: true,
    secure: self.isSecureContext,
    count: Object.getOwnPropertyNames(self).length,
    gated: present(GATED),
    ungated: present(UNGATED),
    holder,
    on_prototype,
    on_self: shape(Object.getOwnPropertyDescriptor(self, 'isSecureContext')),
  });
};
