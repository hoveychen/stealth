// Reports the own-property name list of the prototypes a fingerprint script
// walks from inside a worker, in source order.
onmessage = () => {
  const own = (o) => Object.getOwnPropertyNames(o).join(',');
  postMessage({
    WorkerGlobalScope: own(WorkerGlobalScope.prototype),
    WorkerNavigator: own(WorkerNavigator.prototype),
    WorkerLocation: own(WorkerLocation.prototype),
    EventTarget: own(EventTarget.prototype),
    FileReaderSync: own(FileReaderSync.prototype),
    FileSystemFileHandle: own(FileSystemFileHandle.prototype),
    XMLHttpRequest_has_responseXML: 'responseXML' in XMLHttpRequest.prototype,
    HID_has_requestDevice: 'requestDevice' in HID.prototype,
    Serial_has_requestPort: 'requestPort' in Serial.prototype,
    USB_has_requestDevice: 'requestDevice' in USB.prototype,
    StorageManager_has_persist: 'persist' in StorageManager.prototype,
    StorageBucket_has_persist: 'persist' in StorageBucket.prototype,
    ServiceWorkerRegistration_has_cookies: 'cookies' in ServiceWorkerRegistration.prototype,
    caches_ctor: self.caches ? self.caches.constructor.name : null,
    createImageBitmap_is_function: typeof self.createImageBitmap,
    onlanguagechange_initially: self.onlanguagechange,
  });
};
