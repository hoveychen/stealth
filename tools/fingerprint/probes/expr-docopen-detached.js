// document.open/write/close on a document with no browsing context
// (createHTMLDocument, DOMParser), run while the host page parses or after it
// loaded: does the host page keep its listeners, readyState, load count, URL
// and title, and what does the written document end up holding? The page and
// its readings come from docopen-detached-server.py:
//
//   python3 tools/fingerprint/probes/docopen-detached-server.py 18766 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-docopen-detached.js \
//     --headed --profile-dir <warm profile> --url 'http://127.0.0.1:18766/p?when=load&kind=chd'
//
// when=parse|load, kind=chd|dp, op=open|write (write = no explicit open()).
window.__done
