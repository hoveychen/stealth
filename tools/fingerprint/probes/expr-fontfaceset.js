(() => {
  const out = {};
  const put = (k, f) => { try { const v = f(); out[k] = v === undefined ? 'undefined' : String(v); } catch (e) { out[k] = 'throw: ' + (e && e.name) + ': ' + (e && e.message); } };
  const fs = document.fonts;
  put('proto.names', () => Object.getOwnPropertyNames(FontFaceSet.prototype).sort().join(','));
  put('proto.symbols', () => Object.getOwnPropertySymbols(FontFaceSet.prototype).map(String).sort().join(','));
  put('iterator.is.values', () => fs[Symbol.iterator] === fs.values);
  put('size', () => fs.size);
  put('forOf', () => { let n = 0; for (const f of fs) n++; return 'ok:' + n; });
  put('spread', () => [...fs].length);
  put('entries.tag', () => Object.prototype.toString.call(fs.entries()));
  put('keys.is.values', () => fs.keys === fs.values);
  put('forEach.len', () => fs.forEach.length);
  put('has.nonface', () => fs.has({}));
  put('status', () => fs.status);
  put('ready.tag', () => Object.prototype.toString.call(fs.ready));
  put('add.returns', () => { const ff = new FontFace('X', 'url(data:,)'); return fs.add(ff) === fs ? 'self' : String(fs.add(ff)); });
  put('sizeAfterAdd', () => fs.size);
  put('forOfAfterAdd', () => { const names = []; for (const f of fs) names.push(f.family + ':' + f.status); return names.join(','); });
  put('entriesAfterAdd', () => { const e = []; for (const pair of fs.entries()) e.push(Array.isArray(pair) ? (pair[0] === pair[1] ? 'same-pair' : 'diff-pair') : 'not-array'); return e.join(','); });
  put('forEachArgs', () => { let rec = ''; fs.forEach((a, b, c) => { rec = `${a && a.family}|${b && b.family}|${c === fs}`; }); return rec; });
  put('deleteReturns', () => { const ff = [...fs][0]; return String(fs.delete(ff)); });
  put('sizeAfterDelete', () => fs.size);
  put('clearThenSize', () => { fs.clear(); return fs.size; });
  put('check', () => fs.check('16px sans-serif'));
  return JSON.stringify(out);
})()
