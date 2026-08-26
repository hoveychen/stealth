// A shared worker's realm is not a dedicated worker's. Reports the pieces that
// differ so the two can be told apart from the outside.
onconnect = (e) => {
  const port = e.ports[0];
  const has = (name) => name in self;
  port.postMessage({
    SharedWorkerGlobalScope: Object.getOwnPropertyNames(SharedWorkerGlobalScope.prototype).join(','),
    // [Exposed=DedicatedWorker] interface objects: none of these belong here.
    dedicated_only_interfaces: [
      'IdleDetector', 'RTCDataChannel', 'RTCEncodedAudioFrame', 'RTCEncodedVideoFrame',
      'RTCTransformEvent', 'RTCRtpScriptTransformer', 'EncodedVideoChunk', 'EncodedAudioChunk',
      'AudioData', 'VideoFrame', 'VideoDecoder', 'VideoEncoder', 'AudioDecoder', 'AudioEncoder',
      'ImageDecoder', 'ImageTrack', 'ImageTrackList', 'VideoColorSpace',
      'MediaSource', 'SourceBuffer', 'SourceBufferList', 'MediaSourceHandle',
      'USB', 'USBDevice', 'HID', 'HIDDevice', 'Serial', 'SerialPort',
    ].filter(has).join(','),
    // ...and the [Exposed=DedicatedWorker] members.
    navigator_device_members: ['hid', 'serial', 'usb'].filter((n) => n in WorkerNavigator.prototype).join(','),
    file_handle_has_sync: 'createSyncAccessHandle' in FileSystemFileHandle.prototype,
    // The pieces a shared worker does keep, so this is not just an
    // absence test.
    WorkerNavigator_tail: Object.getOwnPropertyNames(WorkerNavigator.prototype).slice(-6).join(','),
    has_fetch: typeof self.fetch,
    has_caches: typeof self.caches,
  });
};
