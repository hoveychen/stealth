// What the 42 members the HTML-family batch adds actually answer. Same shape
// as the SVG pair: descriptor kind and arity for every name, then the
// behaviour, read off a live document rather than off the IDL.
//
// The clamping rules on <meter> and <progress> are the reason this exists.
// "value is a double reflecting the value attribute" is true and useless: what
// the getter answers for a missing attribute depends on min, max and on which
// interface it is, and every one of those defaults is a measurement.
(() => {
  const host = document.createElement('div');
  host.innerHTML =
    '<img id="img" src="/x.png" alt="a" sizes="100vw" fetchpriority="high" attributionsrc="/a" browsingtopics sharedstoragewritable>' +
    '<video id="video" poster="/p.png"></video>' +
    '<meter id="meter" value="0.7" min="0" max="1" low="0.2" high="0.8" optimum="0.9"></meter>' +
    '<meter id="bareMeter"></meter>' +
    '<meter id="oddMeter" value="5" min="10" max="4" low="1" high="99" optimum="-2"></meter>' +
    '<select id="select" autocomplete="country"><option id="o1" value="a">A</option><option id="o2" value="b" selected>B</option></select>' +
    '<a id="a" href="/h" hreflang="en" hreftranslate="fr" attributionsrc="/s">t</a>' +
    '<form id="form" rel="noopener"><input id="field" value="v"></form>' +
    '<marquee id="marquee" loop="3"></marquee>' +
    '<dialog id="dialog" closedby="any"></dialog>' +
    '<progress id="progress" value="0.3" max="2"></progress>' +
    '<progress id="bareProgress"></progress>' +
    '<video id="track-owner"><track id="track" src="/t.vtt" kind="captions" default></track></video>';
  document.body.appendChild(host);
  const $ = (id) => host.querySelector('#' + id);

  const out = {};
  const describe = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    const t = typeof v;
    if (t === 'number' || t === 'boolean' || t === 'string') return t + ' ' + String(v);
    if (t === 'function') return 'function ' + v.name + '/' + v.length;
    let name = 'object';
    try { name = Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto'; } catch (e) { /* */ }
    return name;
  };
  const call = (label, fn) => {
    try { out[label] = describe(fn()); } catch (e) { out[label] = (e.name || e.constructor.name) + ': ' + e.message; }
  };
  const shape = (iface, names) => {
    const proto = self[iface]?.prototype;
    for (const n of names) {
      const d = proto && Object.getOwnPropertyDescriptor(proto, n);
      if (!d) { out[iface + '.' + n + ' [desc]'] = 'absent'; continue; }
      out[iface + '.' + n + ' [desc]'] =
        (d.get ? 'accessor get' + (d.set ? '+set' : '') : 'data ' + describe(d.value)) +
        ' enum=' + d.enumerable + ' conf=' + d.configurable;
    }
  };

  shape('HTMLImageElement', ['sizes', 'fetchPriority', 'x', 'y', 'decode', 'browsingTopics', 'attributionSrc', 'sharedStorageWritable']);
  shape('HTMLVideoElement', ['webkitDecodedFrameCount', 'webkitDroppedFrameCount', 'onenterpictureinpicture',
    'onleavepictureinpicture', 'disablePictureInPicture', 'cancelVideoFrameCallback', 'requestPictureInPicture',
    'requestVideoFrameCallback']);
  shape('HTMLMeterElement', ['value', 'min', 'max', 'low', 'high', 'optimum']);
  shape('HTMLSelectElement', ['autocomplete', 'item', 'namedItem', 'remove', 'showPicker']);
  shape('HTMLAnchorElement', ['interestForElement', 'hrefTranslate', 'attributionSrc']);
  shape('HTMLFormElement', ['rel', 'relList', 'reset']);
  shape('HTMLMarqueeElement', ['loop', 'start', 'stop']);
  shape('HTMLDialogElement', ['closedBy', 'requestClose']);
  shape('HTMLProgressElement', ['value', 'position']);
  shape('HTMLTrackElement', ['readyState', 'track']);

  const img = $('img');
  call('img.sizes', () => img.sizes);
  call('img.sizes = 50vw', () => { img.sizes = '50vw'; return img.getAttribute('sizes'); });
  call('img.fetchPriority', () => img.fetchPriority);
  call('img.fetchPriority bogus', () => { img.setAttribute('fetchpriority', 'bogus'); return img.fetchPriority; });
  call('img.fetchPriority missing', () => { img.removeAttribute('fetchpriority'); return img.fetchPriority; });
  call('img.fetchPriority = low', () => { img.fetchPriority = 'low'; return img.getAttribute('fetchpriority'); });
  call('img.x', () => img.x);
  call('img.y', () => img.y);
  call('img.decode()', () => img.decode());
  call('img.browsingTopics', () => img.browsingTopics);
  call('img.browsingTopics off', () => { img.removeAttribute('browsingtopics'); return img.browsingTopics; });
  call('img.browsingTopics = true', () => { img.browsingTopics = true; return img.getAttribute('browsingtopics'); });
  call('img.attributionSrc', () => img.attributionSrc);
  call('img.attributionSrc missing', () => { img.removeAttribute('attributionsrc'); return img.attributionSrc; });
  call('img.sharedStorageWritable', () => img.sharedStorageWritable);

  const video = $('video');
  call('video.webkitDecodedFrameCount', () => video.webkitDecodedFrameCount);
  call('video.webkitDroppedFrameCount', () => video.webkitDroppedFrameCount);
  call('video.onenterpictureinpicture', () => video.onenterpictureinpicture);
  call('video.onenterpictureinpicture set', () => { video.onenterpictureinpicture = () => {}; return typeof video.onenterpictureinpicture; });
  call('video.onleavepictureinpicture', () => video.onleavepictureinpicture);
  call('video.disablePictureInPicture', () => video.disablePictureInPicture);
  call('video.disablePictureInPicture = true', () => { video.disablePictureInPicture = true; return video.getAttribute('disablepictureinpicture'); });
  call('video.requestVideoFrameCallback(fn)', () => video.requestVideoFrameCallback(() => {}));
  call('video.requestVideoFrameCallback twice', () => video.requestVideoFrameCallback(() => {}));
  call('video.cancelVideoFrameCallback(1)', () => video.cancelVideoFrameCallback(1));
  call('video.cancelVideoFrameCallback(9999)', () => video.cancelVideoFrameCallback(9999));
  call('video.requestVideoFrameCallback()', () => video.requestVideoFrameCallback());
  call('video.requestPictureInPicture()', () => video.requestPictureInPicture().catch(() => {}));

  const meter = $('meter');
  for (const n of ['value', 'min', 'max', 'low', 'high', 'optimum']) {
    call('meter.' + n, () => meter[n]);
    call('bareMeter.' + n, () => $('bareMeter')[n]);
    call('oddMeter.' + n, () => $('oddMeter')[n]);
  }
  call('meter.value = 5', () => { meter.value = 5; return [meter.value, meter.getAttribute('value')].join('|'); });
  call('meter.value = -5', () => { meter.value = -5; return [meter.value, meter.getAttribute('value')].join('|'); });
  call('meter.max = 0.5', () => { meter.max = 0.5; return [meter.max, meter.value].join('|'); });
  call('meter.value NaN', () => { meter.value = NaN; return meter.value; });

  const progress = $('progress');
  call('progress.value', () => progress.value);
  call('progress.max', () => progress.max);
  call('progress.position', () => progress.position);
  call('bareProgress.value', () => $('bareProgress').value);
  call('bareProgress.max', () => $('bareProgress').max);
  call('bareProgress.position', () => $('bareProgress').position);
  call('progress.value = 9', () => { progress.value = 9; return [progress.value, progress.position].join('|'); });
  call('progress.value = -1', () => { progress.value = -1; return progress.value; });
  call('progress.max = 0', () => { progress.max = 0; return [progress.max, progress.getAttribute('max')].join('|'); });
  call('progress.value = NaN', () => { progress.value = NaN; return progress.value; });

  const select = $('select');
  call('select.autocomplete', () => select.autocomplete);
  call('select.autocomplete bogus', () => { select.setAttribute('autocomplete', 'zz'); return select.autocomplete; });
  call('select.autocomplete missing', () => { select.removeAttribute('autocomplete'); return select.autocomplete; });
  call('select.item(0)', () => select.item(0)?.id);
  call('select.item(9)', () => select.item(9));
  call('select.item()', () => select.item());
  call('select.namedItem(o2)', () => select.namedItem('o2')?.id);
  call('select.namedItem(zz)', () => select.namedItem('zz'));
  call('select.showPicker()', () => select.showPicker());
  call('select.remove(0)', () => { select.remove(0); return select.length; });
  call('select.remove(99)', () => { select.remove(99); return select.length; });
  call('select.remove()', () => { select.remove(); return select.isConnected; });

  const a = $('a');
  call('a.interestForElement', () => a.interestForElement);
  call('a.hrefTranslate', () => a.hrefTranslate);
  call('a.hrefTranslate = de', () => { a.hrefTranslate = 'de'; return a.getAttribute('hreftranslate'); });
  call('a.attributionSrc', () => a.attributionSrc);
  call('a.attributionSrc missing', () => { a.removeAttribute('attributionsrc'); return a.attributionSrc; });

  const form = $('form');
  call('form.rel', () => form.rel);
  call('form.relList', () => form.relList);
  call('form.relList.value', () => form.relList.value);
  call('form.relList same object', () => form.relList === form.relList);
  call('form.rel = nofollow', () => { form.rel = 'nofollow'; return [form.getAttribute('rel'), form.relList.value].join('|'); });
  call('form.relList = x', () => { form.relList = 'x'; return form.getAttribute('rel'); });
  call('form.reset()', () => { $('field').value = 'changed'; form.reset(); return $('field').value; });

  const marquee = $('marquee');
  call('marquee.loop', () => marquee.loop);
  call('marquee.loop missing', () => { marquee.removeAttribute('loop'); return marquee.loop; });
  call('marquee.loop = 5', () => { marquee.loop = 5; return marquee.getAttribute('loop'); });
  call('marquee.loop = 0', () => { try { marquee.loop = 0; } catch (e) { return e.name + ': ' + e.message; } return marquee.loop; });
  call('marquee.loop = -1', () => { marquee.loop = -1; return [marquee.loop, String(marquee.getAttribute('loop'))].join('|'); });
  call('marquee.start()', () => marquee.start());
  call('marquee.stop()', () => marquee.stop());

  const dialog = $('dialog');
  call('dialog.closedBy', () => dialog.closedBy);
  call('dialog.closedBy bogus', () => { dialog.setAttribute('closedby', 'zz'); return dialog.closedBy; });
  call('dialog.closedBy missing closed', () => { dialog.removeAttribute('closedby'); return dialog.closedBy; });
  call('dialog.closedBy missing open', () => { dialog.show(); const v = dialog.closedBy; dialog.close(); return v; });
  call('dialog.closedBy missing modal', () => { dialog.showModal(); const v = dialog.closedBy; dialog.close(); return v; });
  call('dialog.closedBy = none', () => { dialog.closedBy = 'none'; return dialog.getAttribute('closedby'); });
  call('dialog.requestClose()', () => { dialog.show(); const r = dialog.requestClose('rv'); return [describe(r), dialog.open, dialog.returnValue].join('|'); });
  call('dialog.requestClose() closed', () => dialog.requestClose());

  const track = $('track');
  call('track.readyState', () => track.readyState);
  call('track.track', () => track.track);
  call('track.track.kind', () => track.track.kind);
  call('track.track.label', () => track.track.label);
  call('track.track.language', () => track.track.language);
  call('track.track.mode', () => track.track.mode);
  call('track.track same object', () => track.track === track.track);
  call('track.NONE', () => track.NONE);
  call('video.textTracks.length', () => $('track-owner').textTracks.length);

  host.remove();
  return JSON.stringify(out);
})()
