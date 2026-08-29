// A blob worker whose URL is revoked right after construction.
//
// B60 measured the Cloudflare challenge making a 13-byte text/javascript blob
// worker before its real one: Chrome runs it without a sound, this engine fires
// `error` with message "Abort" on every run, in both documents, and the
// challenge then builds a third worker Chrome never builds. A live run with the
// report-worker-source knob caught the source -- `"you"==="bot"`, 13 bytes --
// and running that on a plain page is silent on both arms, so the source is not
// what does it. What is left is the revoke: per the File API a blob URL stays
// resolvable for a fetch that has already started, and a Worker captures its
// script URL at construction, so revoking straight afterwards must not stop it.
(() => {
    const src = '"you"==="bot"';
    const results = {};
    const waits = [];
    const run = (key, revoke) => {
        const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        let w;
        try {
            w = new Worker(url);
        } catch (e) {
            results[key] = 'threw:' + e.name;
            return;
        }
        results[key] = 'silent';
        w.addEventListener('error', (e) => {
            results[key] = 'error:' + String((e && e.message) || '');
        });
        waits.push(w);
        revoke(url);
    };

    run('kept', () => {});
    run('revoked-immediately', (url) => URL.revokeObjectURL(url));
    run('revoked-next-tick', (url) => setTimeout(() => URL.revokeObjectURL(url), 0));
    run('revoked-after-100ms', (url) => setTimeout(() => URL.revokeObjectURL(url), 100));

    // ...and the same for the shape the second worker has, which does answer.
    {
        const url = URL.createObjectURL(new Blob(['self.onmessage=(e)=>postMessage(e.data)'],
            { type: 'text/javascript' }));
        const w = new Worker(url);
        URL.revokeObjectURL(url);
        results['answering-revoked'] = 'no-answer';
        w.addEventListener('error', (e) => {
            results['answering-revoked'] = 'error:' + String((e && e.message) || '');
        });
        w.addEventListener('message', (e) => {
            results['answering-revoked'] = 'answered:' + e.data;
        });
        w.postMessage('ping');
        waits.push(w);
    }

    return new Promise((resolve) => {
        setTimeout(() => {
            for (const w of waits) w.terminate();
            resolve(results);
        }, 900);
    });
})()
