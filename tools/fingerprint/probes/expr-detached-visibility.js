// visibilityState / hidden of documents with no browsing context, next to the
// page's own. Chrome answers from the document's own frame, so the question is
// what a document with none answers.
//
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-detached-visibility.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:18765/p/page.html'
(() => {
  const v = (d) => d.visibilityState + '/' + d.hidden + '/' + (typeof d.webkitVisibilityState === 'undefined' ? '-' : d.webkitVisibilityState + '/' + d.webkitHidden);
  const p = new DOMParser();
  const tpl = document.createElement('template');
  return {
    page: v(document),
    domparserHtml: v(p.parseFromString('<p>x</p>', 'text/html')),
    domparserXml: v(p.parseFromString('<a/>', 'application/xml')),
    createHTMLDocument: v(document.implementation.createHTMLDocument('')),
    createDocument: v(document.implementation.createDocument(null, 'a')),
    newDocument: v(new Document()),
    templateContent: v(tpl.content.ownerDocument),
  };
})()
