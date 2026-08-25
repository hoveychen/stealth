// The order the three scripts of async-order-page.mjs ran in.
//
// An `async` script's execution is a task, so it cannot run inside the parser --
// which only becomes observable when its fetch lands while a parser-blocking
// script is still running. See async-order-page.mjs for why that takes three
// variants, and tools/fingerprint/README.md for the readings.
({
    order: (window.__o || []).join(','),
    readyState: document.readyState,
})
