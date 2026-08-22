// The names on `window` itself, so a count difference can be read as a list.
// probe.js records only `window.ownPropertyNames.count`; when that count moves,
// this says which names moved with it.
JSON.stringify({
    own: Object.getOwnPropertyNames(window).sort(),
    proto: Object.getOwnPropertyNames(Object.getPrototypeOf(window)).sort(),
})
