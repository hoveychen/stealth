(async () => {
  // Batch 15 P4 details: the text-track cluster's behaviour and the capture
  // objects, each probed in its own try so one throw does not eat the rest.
  const out = {};
  const S = (fn) => { try { const v = fn(); return typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  const T = (p, ms = 1000) => Promise.race([
    Promise.resolve(p).then((v) => ({ settled: 'resolved', brand: v && Object.prototype.toString.call(v) }), (e) => ({ settled: 'rejected', err: `${e.name}: ${e.message}` })),
    new Promise((r) => setTimeout(() => r({ settled: 'pending' }), ms)),
  ]);

  const video = document.createElement('video');
  out.addTextTrackArity = S(() => HTMLMediaElement.prototype.addTextTrack.length);
  out.textTracksIdentity = S(() => video.textTracks === video.textTracks);
  out.addTextTrackDefaults = S(() => { const t = video.addTextTrack('metadata'); return { kind: t.kind, label: JSON.stringify(t.label), language: JSON.stringify(t.language), id: JSON.stringify(t.id), mode: t.mode }; });
  out.validKinds = S(() => ['subtitles', 'captions', 'descriptions', 'chapters', 'metadata'].map((k) => { try { return `${k}:${document.createElement('video').addTextTrack(k).kind}`; } catch (e) { return `${k}:${e.name}`; } }).join(','));
  out.modeDisabledCues = S(() => { const t = document.createElement('video').addTextTrack('captions'); t.mode = 'disabled'; return { mode: t.mode, cues: String(t.cues), activeCues: String(t.activeCues) }; });
  out.modeBadValue = S(() => { const t = document.createElement('video').addTextTrack('captions'); t.mode = 'nope'; return t.mode; });
  out.trackListShape = S(() => { const v = document.createElement('video'); const a = v.addTextTrack('subtitles', 'A'); const b = v.addTextTrack('captions', 'B'); const l = v.textTracks; return { len: l.length, zero: l[0].label, one: l[1].label, oob: String(l[2]), item: String(l.getTrackById('')), spread: Array.from(l).length, sameObject: l[0] === a && l[1] === b }; });
  out.getTrackByIdMissing = S(() => String(document.createElement('video').textTracks.getTrackById('zz')));
  out.addRemoveCue = S(() => {
    const t = document.createElement('video').addTextTrack('captions');
    const cue = new VTTCue(0, 1, 'hi');
    t.addCue(cue);
    const after = { len: t.cues.length, first: t.cues[0] === cue, byId: String(t.cues.getCueById('')), cueTrack: t.cues[0] && String(t.cues[0].track && Object.prototype.toString.call(t.cues[0].track)) };
    t.removeCue(cue);
    after.lenAfterRemove = t.cues.length;
    after.removeUnknown = (() => { try { t.removeCue(new VTTCue(0, 1, 'x')); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    after.addNonCue = (() => { try { t.addCue({}); return 'ok'; } catch (e) { return `${e.name}: ${e.message}`; } })();
    return after;
  });
  out.cueIdLookup = S(() => { const t = document.createElement('video').addTextTrack('captions'); const c = new VTTCue(0, 1, 'x'); c.id = 'c1'; t.addCue(c); return { byId: t.cues.getCueById('c1') === c, missing: String(t.cues.getCueById('nope')) }; });
  out.trackEventsFire = await (async () => {
    const v = document.createElement('video');
    const seen = [];
    v.textTracks.addEventListener('addtrack', (e) => seen.push(`addtrack:${Object.prototype.toString.call(e)}:${e.track && e.track.label}`));
    v.textTracks.onchange = () => seen.push('change');
    v.addTextTrack('subtitles', 'L');
    await new Promise((r) => setTimeout(r, 200));
    return seen.join('|') || 'none';
  })();

  // CaptureController, one member at a time.
  out.capture = (() => {
    const c = new CaptureController();
    const r = { own: Object.getOwnPropertyNames(c).join(','), isEventTarget: c instanceof EventTarget };
    for (const [k, fn] of [
      ['zoomLevel', () => String(c.zoomLevel)],
      ['onzoomlevelchange', () => String(c.onzoomlevelchange)],
      ['getSupportedZoomLevels', () => JSON.stringify(c.getSupportedZoomLevels())],
      ['setFocusBehaviorValid', () => String(c.setFocusBehavior('focus-captured-surface'))],
      ['setFocusBehaviorBad', () => String(c.setFocusBehavior('nope'))],
      ['setFocusBehaviorNoArg', () => String(c.setFocusBehavior())],
      ['increaseZoomLevel', () => String(c.increaseZoomLevel())],
      ['decreaseZoomLevel', () => String(c.decreaseZoomLevel())],
      ['resetZoomLevel', () => String(c.resetZoomLevel())],
      ['forwardWheelNull', () => String(c.forwardWheel(null))],
      ['forwardWheelBad', () => String(c.forwardWheel({}))],
    ]) r[k] = S(fn);
    return r;
  })();

  // CropTarget's only entry point.
  out.cropFromElementDiv = await T((() => { try { return CropTarget.fromElement(document.createElement('div')); } catch (e) { return Promise.reject(e); } })());
  out.cropFromElementNonElement = await T((() => { try { return CropTarget.fromElement({}); } catch (e) { return Promise.reject(e); } })());
  out.cropFromElementNoArg = await T((() => { try { return CropTarget.fromElement(); } catch (e) { return Promise.reject(e); } })());
  out.cropTargetsDiffer = await (async () => { try { const a = await CropTarget.fromElement(document.body); const b = await CropTarget.fromElement(document.body); return a === b ? 'same' : 'different'; } catch (e) { return `${e.name}: ${e.message}`; } })();

  // OverconstrainedError's DOMException-ness.
  out.oce = S(() => { const e = new OverconstrainedError('width', 'nope'); return { name: e.name, message: e.message, constraint: e.constraint, code: e.code, str: String(e), ownKeys: Object.getOwnPropertyNames(e).join(','), protoOfProto: Object.getPrototypeOf(Object.getPrototypeOf(e)).constructor.name, stack: typeof e.stack }; });
  out.oceNoArg = S(() => new OverconstrainedError());
  out.oceNonString = S(() => { const e = new OverconstrainedError(5, 6); return { constraint: e.constraint, message: e.message }; });
  out.oceThrown = S(() => { try { throw new OverconstrainedError('w', 'm'); } catch (e) { return `${e instanceof DOMException}/${e instanceof Error}/${e.name}`; } });

  // PictureInPictureWindow's reachability.
  out.pip = S(() => ({ ctor: typeof PictureInPictureWindow, docEnabled: document.pictureInPictureEnabled, docElement: String(document.pictureInPictureElement), exitFn: typeof document.exitPictureInPicture, onEnter: 'onenterpictureinpicture' in HTMLVideoElement.prototype, disablePip: 'disablePictureInPicture' in HTMLVideoElement.prototype }));
  out.pipExit = await T((() => { try { return document.exitPictureInPicture(); } catch (e) { return Promise.reject(e); } })());

  // BrowserCaptureMediaStreamTrack against a plain MediaStreamTrack.
  out.bcmst = S(() => ({ isSubclassOfMediaStreamTrack: Object.getPrototypeOf(BrowserCaptureMediaStreamTrack.prototype) === MediaStreamTrack.prototype, cropToArity: BrowserCaptureMediaStreamTrack.prototype.cropTo.length, restrictToArity: BrowserCaptureMediaStreamTrack.prototype.restrictTo.length }));
  return out;
})()
