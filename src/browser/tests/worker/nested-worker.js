// A dedicated worker that starts another one. Chrome nests happily; this engine
// did not even have the constructor, and exposing it alone wedged the engine --
// which is what this test is here to keep fixed.
onmessage = function () {
  var report = { typeof_Worker: typeof Worker, nested: null, err: null };
  try {
    var inner = new Worker('./echo-worker.js');
    inner.onmessage = function (e) {
      report.nested = e.data && e.data.echo;
      postMessage(report);
    };
    inner.onerror = function (e) {
      report.err = 'inner: ' + String((e && e.message) || e);
      postMessage(report);
    };
    inner.postMessage('ping');
  } catch (e) {
    report.err = String((e && e.message) || e);
    postMessage(report);
  }
};
