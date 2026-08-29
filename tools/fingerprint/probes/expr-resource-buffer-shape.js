// What does the resource timing buffer hold after a page with three
// subresources? cf-scrapingcourse opens on this arm as soon as the widget's
// frame makes a burst of its own requests, and an empty or short buffer is the
// simplest thing that a burst would repair.
(() => {
  const out = {};
  try {
    const p = performance;
    out.hasGetEntries = typeof p.getEntries === 'function';
    out.hasGetEntriesByType = typeof p.getEntriesByType === 'function';
    const res = p.getEntriesByType ? p.getEntriesByType('resource') : [];
    out.resourceCount = res.length;
    out.resourceNames = res.map((e) => String(e.name).replace(/^https?:\/\/[^/]+/, '')).sort();
    out.navCount = p.getEntriesByType ? p.getEntriesByType('navigation').length : -1;
    out.allCount = p.getEntries ? p.getEntries().length : -1;
    out.allTypes = p.getEntries ? [...new Set(p.getEntries().map((e) => e.entryType))].sort() : [];
    const one = res[0];
    out.firstEntryFields = one ? Object.keys(one.toJSON ? one.toJSON() : one).sort() : [];
    out.firstEntry = one && one.toJSON ? one.toJSON() : null;
    out.bufferSize = typeof p.setResourceTimingBufferSize === 'function' ? 'settable' : 'absent';
    out.timeOrigin = typeof p.timeOrigin;
  } catch (e) { out.threw = String(e); }
  return out;
})()
