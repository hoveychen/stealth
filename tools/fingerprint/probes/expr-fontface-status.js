// What a FontFace's status does around load(), and what load() answers with.
//
// Companion to expr-fontface-local.js, which showed this engine resolving
// `local()` for families no machine has. Before changing load(), this pins the
// three things the change has to get right: the status a fresh face carries,
// what the promise resolves TO, and what the failure looks like.
(async () => {
    const out = {};
    const face = (n) => new FontFace('probe-status', 'local("' + n + '")');

    {
        const f = face('Geneva');
        out.freshStatus = f.status;
        const settled = await f.load();
        out.resolvesWithSelf = settled === f;
        out.statusAfterLoad = f.status;
        out.loadedIsSameObject = (await f.loaded) === f;
        // A second load() on an already-loaded face.
        out.secondLoad = (await f.load()) === f;
    }

    {
        const f = face('NoSuchFamilyQZX');
        out.absentFreshStatus = f.status;
        // status while the load is in flight, read synchronously after the call
        const p = f.load();
        out.absentStatusWhileLoading = f.status;
        try {
            await p;
            out.absentLoad = 'resolved';
        } catch (e) {
            out.absentLoad = e.name + ': ' + e.message;
            out.absentIsDomException = e instanceof DOMException;
        }
        out.absentStatusAfterLoad = f.status;
        try {
            await f.loaded;
            out.absentLoadedPromise = 'resolved';
        } catch (e) {
            out.absentLoadedPromise = e.name;
        }
    }

    {
        // A face built from a url() source is not something this engine
        // fetches; recorded so the change does not accidentally reject it.
        const f = new FontFace('probe-url', 'url(https://example.invalid/f.woff2)');
        out.urlFreshStatus = f.status;
    }

    {
        // Two names in one src: Chrome takes the first that resolves.
        const f = new FontFace('probe-list', 'local("NoSuchFamilyQZX"), local("Geneva")');
        try {
            await f.load();
            out.listLoad = 'resolved:' + f.status;
        } catch (e) {
            out.listLoad = 'rejected:' + e.name;
        }
    }

    return out;
})()
