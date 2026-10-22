// Where a <base href> and a <meta name=referrer> take effect: parsed into a
// detached document or subtree (DOMParser, innerHTML, <template>,
// createHTMLDocument, createContextualFragment) versus inserted into, moved
// within and removed from the page's own document. Each step reads
// document.baseURI, a relative a.href, and the Referer of a same-origin fetch.
//
// The case is the URL fragment; the page needs the /echo endpoint of
// echo-referer-server.py next to this file:
//
//   python3 tools/fingerprint/probes/echo-referer-server.py 18765 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-detached-base-referrer.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:18765/p/page.html#domparser'
//
// Cases: domparser innerhtml-detached innerhtml-connected template
// createhtmldoc contextual dynamic meta-dynamic insertadjacent
// docparser-then-write move-to-other-doc.
(async () => {
  const HTML = '<head><base href="https://evil.example/d/"><meta name="referrer" content="no-referrer"></head><body><a href="rel">x</a></body>';
  const FRAG = '<base href="https://evil.example/d/"><meta name="referrer" content="no-referrer"><a href="rel">x</a>';
  const read = async (tag) => {
    const a = document.createElement('a'); a.href = 'x/y';
    const r = await fetch(location.origin + '/echo?' + tag, {cache: 'no-store'}).then(r => r.json()).catch(e => ({err: String(e)}));
    return {baseURI: document.baseURI, aHref: a.href, referer: r.referer ?? null, err: r.err};
  };
  const out = {case: location.hash.slice(1)};
  out.before = await read('before');
  const host = document.getElementById('host');
  switch (out.case) {
    case 'domparser': {
      const d = new DOMParser().parseFromString(HTML, 'text/html');
      out.after = await read('after');
      out.docBaseURI = d.baseURI; out.docA = d.querySelector('a').href;
      out.docBaseHref = d.querySelector('base').href;
      out.docURL = d.URL;
      // adopt base + meta into the live head
      document.head.append(document.adoptNode(d.querySelector('base')), document.adoptNode(d.querySelector('meta')));
      out.afterAdopt = await read('adopt');
      break;
    }
    case 'innerhtml-detached': {
      const div = document.createElement('div'); div.innerHTML = FRAG;
      out.after = await read('after');
      out.fragA = div.querySelector('a').href;
      host.appendChild(div);
      out.afterInsert = await read('insert');
      div.remove();
      out.afterRemove = await read('remove');
      break;
    }
    case 'innerhtml-connected': {
      host.innerHTML = FRAG;
      out.after = await read('after');
      out.hostA = host.querySelector('a').href;
      host.innerHTML = '';
      out.afterRemove = await read('remove');
      break;
    }
    case 'template': {
      const t = document.createElement('template'); t.innerHTML = FRAG;
      out.after = await read('after');
      out.tplA = t.content.querySelector('a').href;
      out.tplBaseURI = t.content.firstChild.baseURI;
      document.head.appendChild(t);
      out.afterTplInHead = await read('tplhead');
      document.head.appendChild(t.content.cloneNode(true));
      out.afterCloneInsert = await read('clone');
      break;
    }
    case 'createhtmldoc': {
      const d = document.implementation.createHTMLDocument('');
      d.head.innerHTML = '<base href="https://evil.example/d/"><meta name="referrer" content="no-referrer">';
      d.body.innerHTML = '<a href="rel">x</a>';
      out.after = await read('after');
      out.docBaseURI = d.baseURI; out.docA = d.querySelector('a').href; out.docURL = d.URL;
      const d2 = document.implementation.createHTMLDocument('');
      d2.body.innerHTML = '<a href="rel">x</a>';
      out.noBaseDocBaseURI = d2.baseURI; out.noBaseDocA = d2.querySelector('a').href;
      break;
    }
    case 'contextual': {
      const r = document.createRange(); r.selectNode(host);
      const f = r.createContextualFragment(FRAG);
      out.after = await read('after');
      host.appendChild(f);
      out.afterInsert = await read('insert');
      break;
    }
    case 'dynamic': {
      const b1 = document.createElement('base'); b1.href = 'https://one.example/a/';
      out.detachedBaseHref = b1.href;
      out.afterCreate = await read('create');
      document.body.appendChild(b1);
      out.afterBodyBase = await read('bodybase');
      const b2 = document.createElement('base'); b2.setAttribute('href', 'https://two.example/b/');
      document.head.prepend(b2);
      out.afterHeadBase = await read('headbase');
      b2.setAttribute('href', 'https://three.example/c/');
      out.afterSetAttr = await read('setattr');
      b2.removeAttribute('href');
      out.afterRemoveAttr = await read('rmattr');
      b1.remove();
      out.afterRemoveB1 = await read('rmb1');
      b2.href = 'https://four.example/';
      out.afterB2Href = await read('b2href');
      b2.remove();
      out.afterRemoveAll = await read('rmall');
      break;
    }
    case 'meta-dynamic': {
      const m = document.createElement('meta'); m.name = 'referrer'; m.content = 'no-referrer';
      out.afterCreate = await read('create');
      document.body.appendChild(m);
      out.afterBodyInsert = await read('bodyinsert');
      m.content = 'unsafe-url';
      out.afterContentChange = await read('content');
      m.remove();
      out.afterRemove = await read('remove');
      const m2 = document.createElement('meta'); document.head.appendChild(m2);
      m2.content = 'origin'; out.afterContentNoName = await read('noname');
      m2.name = 'referrer'; out.afterNameSet = await read('nameset');
      break;
    }
    case 'insertadjacent': {
      host.insertAdjacentHTML('beforeend', FRAG);
      out.after = await read('after');
      break;
    }
    case 'move-to-other-doc': {
      const b3 = document.createElement('base'); b3.href = 'https://six.example/';
      document.head.appendChild(b3);
      out.afterInsert = await read('insert');
      const other = new DOMParser().parseFromString('<p>', 'text/html');
      other.head.appendChild(b3);
      out.afterMove = await read('move');
      out.otherBaseURI = other.baseURI;
      const m = document.createElement('meta'); m.name = 'referrer'; m.content = 'no-referrer';
      other.head.appendChild(m);
      out.afterMetaInOther = await read('metaother');
      document.head.appendChild(m);
      out.afterMetaAdoptedIn = await read('metain');
      break;
    }
    case 'docparser-then-write': {
      const d = document.implementation.createHTMLDocument('');
      d.open(); d.write(HTML); d.close();
      out.after = await read('after');
      out.docBaseURI = d.baseURI;
      break;
    }
  }
  return out;
})()
