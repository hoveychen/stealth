// The RTC surface a Chrome DedicatedWorkerGlobalScope carries. Measured with
// agent-workspace/stealth-detector-probes/webrtc-worker-surface.mjs: exactly
// five names, none of them RTCPeerConnection.
(function() {
  const names = Object.getOwnPropertyNames(self).filter((k) => /^RTC/.test(k)).sort();

  const protoKeys = (n) => Object.getOwnPropertyNames(self[n].prototype);
  const throws = (n) => {
    try { new self[n](); return false; } catch (e) { return e instanceof TypeError; }
  };

  self.postMessage({
    names: names,
    has_peer_connection: typeof self.RTCPeerConnection,
    transform_event_proto: Object.getPrototypeOf(self.RTCTransformEvent.prototype) === Event.prototype,
    data_channel_proto: Object.getPrototypeOf(self.RTCDataChannel.prototype) === EventTarget.prototype,
    transformer_proto: Object.getPrototypeOf(self.RTCRtpScriptTransformer.prototype) === Object.prototype,
    transform_event_keys: protoKeys('RTCTransformEvent'),
    transformer_keys: protoKeys('RTCRtpScriptTransformer'),
    audio_frame_keys: protoKeys('RTCEncodedAudioFrame'),
    lengths: {
      RTCTransformEvent: self.RTCTransformEvent.length,
      RTCRtpScriptTransformer: self.RTCRtpScriptTransformer.length,
      RTCDataChannel: self.RTCDataChannel.length,
      RTCEncodedAudioFrame: self.RTCEncodedAudioFrame.length,
    },
    illegal: {
      RTCTransformEvent: throws('RTCTransformEvent'),
      RTCRtpScriptTransformer: throws('RTCRtpScriptTransformer'),
      RTCDataChannel: throws('RTCDataChannel'),
    },
  });
})();
