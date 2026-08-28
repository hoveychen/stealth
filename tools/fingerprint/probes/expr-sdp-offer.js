// The offer SDP the widget reads. report-charsrc caught it going into the
// payload at 8398 characters in Chrome and 7186 here -- the largest single
// content difference found on this door, and the one family no knob has
// touched. The widget's offer carries a=group:BUNDLE 0 1 2 on BOTH arms while
// addTransceiver is refused here, so it asks for the media sections the legacy
// way; both routes are built so the refusal and the short offer stay separable.
(async () => {
    const out = { steps: [] };
    const step = (k, f) => { try { f(); out.steps.push(k + ':ok'); } catch (e) { out.steps.push(k + ':' + e.name); } };

    const a = new RTCPeerConnection();
    step('addTransceiver audio', () => a.addTransceiver('audio'));
    step('addTransceiver video', () => a.addTransceiver('video'));
    step('createDataChannel', () => a.createDataChannel('d'));
    try { out.transceiverSdp = (await a.createOffer()).sdp; } catch (e) { out.transceiverSdp = 'ERR:' + e.name; }
    try { a.close(); } catch (e) {}

    const b = new RTCPeerConnection();
    step('legacy createDataChannel', () => b.createDataChannel('d'));
    try {
        out.legacySdp = (await b.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: true })).sdp;
    } catch (e) { out.legacySdp = 'ERR:' + e.name; }
    try { b.close(); } catch (e) {}

    out.transceiverLen = out.transceiverSdp.length;
    out.legacyLen = out.legacySdp.length;
    return out;
})();
