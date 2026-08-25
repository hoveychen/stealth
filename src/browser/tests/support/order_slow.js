// A parser-blocking script that is slow to *run*, not slow to arrive. That is
// the only situation in which "may a ready async script execute before the next
// parser-blocking script" has an observable answer: the busy loop gives the
// async script's fetch time to land while the parser is still inside this one.
window.__order.push('slow');
const until = Date.now() + 300;
while (Date.now() < until) { /* block the parser */ }
