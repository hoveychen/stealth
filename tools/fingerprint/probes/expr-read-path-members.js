// What the members on the challenge's read path actually answer. The
// interfaces here were picked off results/b50-prop-reads-replay.json -- the
// Akamai interstitial reads HTMLIFrameElement, HTMLMediaElement, MessageEvent,
// ScreenOrientation, OffscreenCanvas and Blob for real -- and every reading
// below is one the IDL does not pin down: a default value, a reflected
// keyword's invalid-value behaviour, a descriptor kind, or what a promise does
// when there is nothing to do.
(() => {
  const out = {};
  const host = document.createElement('div');
  document.body.appendChild(host);
  const grab = (fn) => { try { return fn(); } catch (e) { return 'threw: ' + e.name + ': ' + e.message; } };

  // ---- HTMLIFrameElement
  const f = document.createElement('iframe');
  out.iframe_fresh = {};
  for (const k of ['csp', 'allow', 'loading', 'credentialless', 'allowPaymentRequest',
    'privateToken', 'browsingTopics', 'adAuctionHeaders', 'sharedStorageWritable']) {
    out.iframe_fresh[k] = grab(() => { const v = f[k]; return typeof v + '|' + String(v); });
  }
  out.iframe_featurePolicy = grab(() => f.featurePolicy.constructor.name);
  out.iframe_featurePolicy_methods = grab(() => Object.getOwnPropertyNames(f.featurePolicy.constructor.prototype).join(','));
  out.iframe_getSVGDocument = grab(() => String(f.getSVGDocument()));
  out.iframe_getSVGDocument_length = f.getSVGDocument ? f.getSVGDocument.length : null;
  host.appendChild(f);
  out.iframe_attached_getSVGDocument = grab(() => String(f.getSVGDocument()));

  // Reflections: which content attribute, and how an unknown keyword reads back.
  out.iframe_reflect = grab(() => {
    const r = {};
    f.csp = 'script-src x';
    r.csp_attr = f.getAttribute('csp');
    f.allow = 'camera';
    r.allow_attr = f.getAttribute('allow');
    f.loading = 'LAZY'; r.loading_LAZY = f.loading;
    f.loading = 'bogus'; r.loading_bogus = f.loading; r.loading_bogus_attr = f.getAttribute('loading');
    f.loading = 'eager'; r.loading_eager = f.loading;
    f.credentialless = true; r.credentialless_attr = f.getAttribute('credentialless');
    f.browsingTopics = true; r.browsingTopics_attr = f.getAttribute('browsingtopics');
    f.privateToken = 'tok'; r.privateToken_attr = f.getAttribute('privatetoken');
    f.sharedStorageWritable = true; r.sharedStorageWritable_attr = f.getAttribute('sharedstoragewritable');
    f.adAuctionHeaders = true; r.adAuctionHeaders_attr = f.getAttribute('adauctionheaders');
    f.allowPaymentRequest = true; r.allowPaymentRequest_attr = f.getAttribute('allowpaymentrequest');
    return r;
  });

  // ---- HTMLMediaElement
  const v = document.createElement('video');
  out.media_fresh = {};
  for (const k of ['defaultPlaybackRate', 'preservesPitch', 'webkitAudioDecodedByteCount',
    'webkitVideoDecodedByteCount', 'srcObject', 'loading', 'sinkId']) {
    out.media_fresh[k] = grab(() => { const x = v[k]; return typeof x + '|' + String(x); });
  }
  out.media_controlsList = grab(() => v.controlsList.constructor.name + '|len=' + v.controlsList.length + '|value=' + JSON.stringify(v.controlsList.value));
  out.media_controlsList_same = grab(() => v.controlsList === v.controlsList);
  out.media_controlsList_reflect = grab(() => { v.controlsList = 'nodownload'; return v.getAttribute('controlslist'); });
  out.media_captureStream = grab(() => v.captureStream.length + '|' + String(v.captureStream()));
  out.media_setSinkId_arity = v.setSinkId ? v.setSinkId.length : null;
  out.media_loading_reflect = grab(() => { v.loading = 'lazy'; return v.loading + '|' + v.getAttribute('loading'); });
  out.media_defaultPlaybackRate_set = grab(() => { v.defaultPlaybackRate = 2.5; return v.defaultPlaybackRate + '|' + v.playbackRate; });
  out.media_preservesPitch_set = grab(() => { v.preservesPitch = false; return String(v.preservesPitch) + '|attr=' + String(v.getAttribute('preservespitch')); });
  out.media_srcObject_set = grab(() => { v.srcObject = null; return String(v.srcObject); });

  // ---- MessageEvent
  const me = new MessageEvent('message', { data: 1 });
  out.message_userActivation = grab(() => typeof me.userActivation + '|' + String(me.userActivation));
  out.message_initMessageEvent_arity = me.initMessageEvent ? me.initMessageEvent.length : null;
  out.message_initMessageEvent = grab(() => {
    const e = new MessageEvent('x');
    e.initMessageEvent('m', true, true, 'D', 'ORIGIN', 'LEID', window, []);
    return [e.type, e.bubbles, e.cancelable, e.data, e.origin, e.lastEventId, e.source === window, e.ports.length].join('|');
  });
  out.message_initMessageEvent_defaults = grab(() => {
    const e = new MessageEvent('x');
    e.initMessageEvent('m');
    return [e.type, e.bubbles, e.cancelable, String(e.data), JSON.stringify(e.origin), JSON.stringify(e.lastEventId), String(e.source), e.ports.length].join('|');
  });

  // ---- ScreenOrientation
  const so = screen.orientation;
  out.orientation = grab(() => ({
    onchange: String(so.onchange),
    lock_arity: so.lock.length,
    unlock_arity: so.unlock.length,
    unlock_returns: String(so.unlock()),
  }));

  // ---- OffscreenCanvas
  const oc = new OffscreenCanvas(1, 1);
  out.offscreen = grab(() => ({
    oncontextlost: String(oc.oncontextlost),
    oncontextrestored: String(oc.oncontextrestored),
    descriptor: (() => { const d = Object.getOwnPropertyDescriptor(OffscreenCanvas.prototype, 'oncontextlost'); return d ? (typeof d.get) + ',' + d.enumerable + ',' + d.configurable : 'absent'; })(),
  }));

  // ---- textStream on Blob and Response
  out.textStream = grab(() => {
    const b = new Blob(['hi']);
    const s = b.textStream();
    return b.textStream.length + '|' + s.constructor.name + '|' + String(s.locked);
  });
  out.textStream_response = grab(() => {
    const r = new Response('hi');
    return r.textStream.length + '|' + r.textStream().constructor.name;
  });

  return JSON.stringify(out);
})()
