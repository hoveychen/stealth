// btoa/atob are the WindowOrWorkerGlobalScope mixin, and Blink names the
// interface the call was made on -- so the worker copy says 'WorkerGlobalScope'
// where the page copy says 'Window'. Notably *not* 'DedicatedWorkerGlobalScope',
// even though that is what `self.constructor.name` reports here (measured
// against Chrome 151).
const out = { self_ctor: self.constructor.name };
const msg = (fn) => {
  try { return 'no throw: ' + fn(); } catch (e) { return `${e.name}: ${e.message}`; }
};

out.atob_not_encoded = msg(() => atob('a'));
out.atob_not_latin1 = msg(() => atob('Ā'));
out.btoa_not_latin1 = msg(() => btoa('Ā'));
out.btoa_coerced = msg(() => btoa(123));

postMessage(out);
