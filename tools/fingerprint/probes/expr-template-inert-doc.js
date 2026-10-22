// What a page can read off the document that owns a <template>'s content --
// the "inert" document the HTML spec gives every document's templates, which
// has no browsing context. Compared field by field with the page's own.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-template-inert-doc.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:<port>/page.html'
(async () => {
  const out = {};
  const safe = (f) => { try { const v = f(); return v === undefined ? 'undefined' : v; } catch (e) { return 'throw:' + e.name; } };
  const tpl = document.createElement('template');
  tpl.innerHTML = '<p id=a>x</p><img src="/inert-img.png"><script>window.__tplRan = 1<\/script><a href="rel/x">l</a>';
  const d = tpl.content.ownerDocument;
  const fields = (doc) => ({
    isPage: doc === document,
    ctor: doc.constructor.name,
    tag: Object.prototype.toString.call(doc),
    URL: safe(() => doc.URL),
    documentURI: safe(() => doc.documentURI),
    baseURI: safe(() => doc.baseURI),
    origin: safe(() => doc.origin),
    readyState: safe(() => doc.readyState),
    visibility: safe(() => doc.visibilityState + '/' + doc.hidden),
    contentType: safe(() => doc.contentType),
    compatMode: safe(() => doc.compatMode),
    characterSet: safe(() => doc.characterSet),
    defaultView: safe(() => String(doc.defaultView)),
    hasFocus: safe(() => doc.hasFocus()),
    location: safe(() => String(doc.location)),
    domain: safe(() => doc.domain),
    cookie: safe(() => typeof doc.cookie + ':' + doc.cookie.length),
    referrer: safe(() => doc.referrer),
    title: safe(() => doc.title),
    lastModifiedType: safe(() => typeof doc.lastModified),
    doctype: safe(() => String(doc.doctype && doc.doctype.name)),
    documentElement: safe(() => String(doc.documentElement && doc.documentElement.nodeName)),
    head: safe(() => String(doc.head)),
    body: safe(() => String(doc.body)),
    childNodes: safe(() => doc.childNodes.length),
    implementationSame: safe(() => doc.implementation === document.implementation),
    designMode: safe(() => doc.designMode),
    dir: safe(() => doc.dir),
    fonts: safe(() => typeof doc.fonts),
    timelineType: safe(() => doc.timeline && doc.timeline.constructor.name),
    scrollingElement: safe(() => String(doc.scrollingElement)),
    activeElement: safe(() => String(doc.activeElement)),
    fullscreenEnabled: safe(() => doc.fullscreenEnabled),
    pictureInPictureEnabled: safe(() => doc.pictureInPictureEnabled),
    styleSheets: safe(() => doc.styleSheets.length),
    images: safe(() => doc.images.length),
    all: safe(() => doc.all.length),
    ownerDocument: safe(() => String(doc.ownerDocument)),
    protoChain: (() => { const r = []; let p = Object.getPrototypeOf(doc); while (p) { r.push(p.constructor.name); p = Object.getPrototypeOf(p); } return r.join('>'); })(),
  });
  out.inert = fields(d);
  out.page = { URL: document.URL, readyState: document.readyState, ctor: document.constructor.name };

  // identity: one inert document per page document
  const tpl2 = document.createElement('template');
  out.sameInertForTwoTemplates = tpl2.content.ownerDocument === d;
  const parsed = document.createElement('div');
  parsed.innerHTML = '<template><b>y</b></template>';
  out.sameInertForParsedTemplate = parsed.firstChild.content.ownerDocument === d;
  out.inertOfInertSame = (() => { const t = d.createElement('template'); return t.content.ownerDocument === d; })();
  out.templateElementOwner = tpl.ownerDocument === document;
  out.contentNodeOwner = tpl.content.firstChild.ownerDocument === d;
  out.contentChildCount = tpl.content.childNodes.length;

  // template in a document with no browsing context gets its own inert doc?
  const hd = document.implementation.createHTMLDocument('');
  const ht = hd.createElement('template');
  out.detachedDocTemplateOwnerIsDetached = ht.content.ownerDocument === hd;
  out.detachedDocTemplateOwnerIsPageInert = ht.content.ownerDocument === d;
  const dp = new DOMParser().parseFromString('<template><i>z</i></template>', 'text/html');
  const dpt = dp.querySelector('template');
  out.domparserTemplateOwnerIsItsDoc = dpt.content.ownerDocument === dp;

  // inertness, read before anything copies the content into the page: a page
  // document's <img> fetches its src even while disconnected
  await new Promise((r) => setTimeout(r, 200));
  out.scriptRan = window.__tplRan === 1;
  out.imgRequested = performance.getEntriesByType('resource').some((e) => e.name.includes('inert-img.png'));
  out.imgComplete = safe(() => tpl.content.querySelector('img').complete);

  // a node removed from the content keeps the inert document
  const removed = tpl.content.querySelector('script');
  removed.remove();
  out.removedFromContentOwnerIsInert = removed.ownerDocument === d;
  out.removedFromContentIsConnected = removed.isConnected;

  // template in an XML document
  const xd = document.implementation.createDocument(null, 'r');
  const xt = xd.createElementNS('http://www.w3.org/1999/xhtml', 'template');
  const xi = xt.content.ownerDocument;
  out.xmlInert = { isXd: xi === xd, isPageInert: xi === d, ctor: xi.constructor.name, contentType: xi.contentType, URL: xi.URL, characterSet: xi.characterSet, visibility: xi.visibilityState };
  out.htmlDocInert = (() => { const i = ht.content.ownerDocument; return { ctor: i.constructor.name, contentType: i.contentType, URL: i.URL, characterSet: i.characterSet, sameForSecond: hd.createElement('template').content.ownerDocument === i }; })();

  // a template adopted from another document: its content follows into the
  // new document's inert document
  const dpTpl = dp.querySelector('template');
  const dpInert = dpTpl.content.ownerDocument;
  document.body.appendChild(dpTpl);
  out.adoptedTemplateContentOwnerIsPageInert = dpTpl.content.ownerDocument === d;
  out.adoptedTemplateContentOwnerIsOldInert = dpTpl.content.ownerDocument === dpInert;
  out.adoptedTemplateChildOwnerIsPageInert = dpTpl.content.firstChild.ownerDocument === d;
  dpTpl.remove();

  // clone / import / adopt
  const clone = tpl.content.cloneNode(true);
  out.cloneOwnerIsInert = clone.ownerDocument === d;
  const imported = document.importNode(tpl.content, true);
  out.importOwnerIsPage = imported.ownerDocument === document;
  const tclone = tpl.cloneNode(true);
  out.templateCloneContentOwnerIsInert = tclone.content.ownerDocument === d;
  out.templateCloneContentCount = tclone.content.childNodes.length;
  const p = tpl.content.querySelector('p').cloneNode(true);
  document.body.appendChild(p);
  out.appendedCloneOwnerIsPage = p.ownerDocument === document;
  p.remove();
  const moved = tpl.content.querySelector('a');
  out.anchorHrefInInert = moved.href;
  document.body.appendChild(moved);
  out.adoptedOnAppendOwnerIsPage = moved.ownerDocument === document;
  out.anchorHrefAfterAdopt = moved.href;
  moved.remove();
  const adoptTarget = document.adoptNode(tpl.content.querySelector('p'));
  out.adoptNodeOwnerIsPage = adoptTarget.ownerDocument === document;

  // createElement in inert doc
  const ie = d.createElement('img');
  ie.src = '/inert-img2.png';
  await new Promise((r) => setTimeout(r, 200));
  out.inertCreatedImgRequested = performance.getEntriesByType('resource').some((e) => e.name.includes('inert-img2'));
  out.inertCreatedImgSrc = ie.src;

  // node in template content: isConnected, getRootNode
  out.contentIsConnected = tpl.content.firstChild ? tpl.content.firstChild.isConnected : 'none';
  out.inertGetElementById = safe(() => String(d.getElementById('a')));
  // copies of nodes from other documents
  const hdP = hd.createElement('p');
  out.cloneOfDetachedOwnerIsItsDoc = hdP.cloneNode(true).ownerDocument === hd;
  out.importIntoDetachedOwnerIsTarget = hd.importNode(document.createElement('p'), true).ownerDocument === hd;
  out.removedFromDomparserOwnerIsIt = (() => { const i = dp.createElement('i'); dp.body.appendChild(i); const b = dp.body.firstElementChild; b.remove(); return b.ownerDocument === dp; })();
  return out;
})()
