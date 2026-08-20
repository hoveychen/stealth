// Batch 8: the CSS events, CSSAnimation/CSSTransition, AnimationEffect, and the
// two existing shapes that go with them (Animation, MediaQueryList).
(() => {
  const out = {};
  function T(name, fn) {
    try {
      const v = fn();
      out[name] = v === undefined ? '<undefined>' : v;
    } catch (e) {
      out[name] = `ERR ${e.name}: ${String(e.message).slice(0, 100)}`;
    }
  }
  const B = (v) => v === null ? 'null' : v === undefined ? '<undefined>' : `${v.constructor.name}|${String(v)}`;

  // ---- the four event types --------------------------------------------
  T('transitionEventBare', () => {
    const e = new TransitionEvent('transitionend');
    return `${B(e)} type=${e.type} prop=${JSON.stringify(e.propertyName)} elapsed=${e.elapsedTime} pseudo=${JSON.stringify(e.pseudoElement)} target=${e.pseudoTarget} bubbles=${e.bubbles} cancelable=${e.cancelable} composed=${e.composed}`;
  });
  T('transitionEventDict', () => {
    const e = new TransitionEvent('transitionrun', { propertyName: 'width', elapsedTime: 1.5, pseudoElement: '::before', bubbles: true, cancelable: true, composed: true });
    return `prop=${e.propertyName} elapsed=${e.elapsedTime} pseudo=${e.pseudoElement} bubbles=${e.bubbles} cancelable=${e.cancelable} composed=${e.composed}`;
  });
  T('transitionEventNoArgs', () => B(new TransitionEvent()));
  T('transitionEventInstanceOf', () => `${new TransitionEvent('x') instanceof Event}`);
  T('transitionEventSetters', () => { const e = new TransitionEvent('x'); e.propertyName = 'zz'; return e.propertyName; });

  T('animationEventBare', () => {
    const e = new AnimationEvent('animationend');
    return `${B(e)} name=${JSON.stringify(e.animationName)} elapsed=${e.elapsedTime} pseudo=${JSON.stringify(e.pseudoElement)} target=${e.pseudoTarget} bubbles=${e.bubbles} cancelable=${e.cancelable} composed=${e.composed}`;
  });
  T('animationEventDict', () => {
    const e = new AnimationEvent('animationstart', { animationName: 'spin', elapsedTime: 2, pseudoElement: '::after' });
    return `name=${e.animationName} elapsed=${e.elapsedTime} pseudo=${e.pseudoElement}`;
  });
  T('animationEventNoArgs', () => B(new AnimationEvent()));

  T('mqlEventBare', () => {
    const e = new MediaQueryListEvent('change');
    return `${B(e)} media=${JSON.stringify(e.media)} matches=${e.matches} bubbles=${e.bubbles} cancelable=${e.cancelable} composed=${e.composed}`;
  });
  T('mqlEventDict', () => {
    const e = new MediaQueryListEvent('change', { media: '(min-width: 100px)', matches: true });
    return `media=${e.media} matches=${e.matches}`;
  });
  T('mqlEventNoArgs', () => B(new MediaQueryListEvent()));

  T('ffsleBare', () => {
    const e = new FontFaceSetLoadEvent('loading');
    return `${B(e)} fontfaces=${JSON.stringify(e.fontfaces)} isArray=${Array.isArray(e.fontfaces)} frozen=${Object.isFrozen(e.fontfaces)} bubbles=${e.bubbles} cancelable=${e.cancelable} composed=${e.composed}`;
  });
  T('ffsleDict', () => {
    const f = new FontFace('A', 'url(a.woff2)');
    const e = new FontFaceSetLoadEvent('loadingdone', { fontfaces: [f] });
    return `len=${e.fontfaces.length} same=${e.fontfaces[0] === f} sameArrayTwice=${e.fontfaces === e.fontfaces}`;
  });
  T('ffsleNoArgs', () => B(new FontFaceSetLoadEvent()));

  // ---- Animation / CSSAnimation / CSSTransition -------------------------
  T('animationIllegal', () => B(new CSSAnimation()));
  T('cssTransitionIllegal', () => B(new CSSTransition()));
  T('animationEffectIllegal', () => B(new AnimationEffect()));
  T('newAnimation', () => {
    const a = new Animation();
    return `${B(a)} effect=${a.effect} timeline=${a.timeline && a.timeline.constructor.name} playState=${a.playState} pending=${a.pending} startTime=${a.startTime} currentTime=${a.currentTime} playbackRate=${a.playbackRate} rangeStart=${JSON.stringify(a.rangeStart)} rangeEnd=${JSON.stringify(a.rangeEnd)} replaceState=${a.replaceState} id=${JSON.stringify(a.id)} overallProgress=${a.overallProgress}`;
  });
  T('animationIsEventTarget', () => `${new Animation() instanceof EventTarget}`);
  T('animationHandlers', () => { const a = new Animation(); return `${a.onfinish} ${a.oncancel} ${a.onremove}`; });
  T('animationSetId', () => { const a = new Animation(); a.id = 'x'; return a.id; });
  T('animationSetCurrentTime', () => { const a = new Animation(); a.currentTime = 5; return String(a.currentTime); });
  T('animationSetPlaybackRate', () => { const a = new Animation(); a.playbackRate = 2; return a.playbackRate; });
  T('animationUpdatePlaybackRate', () => { const a = new Animation(); a.updatePlaybackRate(3); return a.playbackRate; });
  T('animationCommitStyles', () => { const a = new Animation(); try { a.commitStyles(); return 'ok'; } catch (e) { return `ERR ${e.name}`; } });
  T('animationPersist', () => { const a = new Animation(); a.persist(); return a.replaceState; });
  T('animationAddEventListener', () => { const a = new Animation(); let hit = 0; a.addEventListener('finish', () => hit++); a.dispatchEvent(new Event('finish')); return hit; });
  T('animationRanges', () => { const a = new Animation(); return `${JSON.stringify(a.rangeStart)} ${JSON.stringify(a.rangeEnd)}`; });

  // a real CSSAnimation / CSSTransition, if getAnimations gives one
  T('getAnimations', () => {
    const style = document.createElement('style');
    style.textContent = '@keyframes spin { from { opacity: 0 } to { opacity: 1 } } #anim { animation: spin 10s linear; transition: width 10s }';
    document.head.appendChild(style);
    const d = document.createElement('div');
    d.id = 'anim';
    document.body.appendChild(d);
    const list = (d.getAnimations ? d.getAnimations() : []).map((a) => `${a.constructor.name}(${a.animationName || a.transitionProperty || ''})`);
    return list.join(' | ') || 'none';
  });
  T('documentGetAnimations', () => (document.getAnimations ? document.getAnimations().length : 'no method'));

  // ---- MediaQueryList onchange ------------------------------------------
  T('mqlOnchange', () => {
    const mql = window.matchMedia('(min-width: 1px)');
    return `${typeof mql.onchange} ${mql.onchange}`;
  });
  T('mqlOnchangeFires', () => {
    const mql = window.matchMedia('(min-width: 1px)');
    let hit = 0;
    mql.onchange = () => hit++;
    mql.dispatchEvent(new MediaQueryListEvent('change', { media: 'x', matches: true }));
    return hit;
  });
  T('mqlIsEventTarget', () => `${window.matchMedia('(min-width: 1px)') instanceof EventTarget}`);

  return { href: location.href, out };
})()
