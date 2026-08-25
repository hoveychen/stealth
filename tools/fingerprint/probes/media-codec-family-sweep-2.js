// Second pass over the codec families: the AVC profiles Chrome's parser lists
// that the first sweep did not ask about, what a list mixing an ambiguous codec
// with a supported one answers, and the codec set of the mpegurl containers.
(() => {
    const out = {};
    const v = document.createElement('video');
    const ask = (t) => [v.canPlayType(t), MediaSource.isTypeSupported(t), MediaRecorder.isTypeSupported(t)].join('|');

    for (const k of [
        'avc1.53001E', 'avc1.56001E', 'avc1.76001E', 'avc1.80001E', 'avc1.4D001E',
        'avc1.63001E', 'avc1.65001E', 'avc1.6D001E', 'avc1.79001E', 'avc1.F3001E',
    ]) out['profile ' + k] = ask('video/mp4;codecs=' + k);

    // A list is only as good as its worst member -- but is an ambiguous member
    // enough to pull a supported one down to "maybe"?
    for (const t of [
        'video/mp4; codecs="avc1.42E0FF, mp4a.40.2"',
        'video/mp4; codecs="avc1.42E01E, mp4a.40.2"',
        'video/mp4; codecs="avc1.7A001E, mp4a.40.2"',
        'video/mp4; codecs="avc1.42E01E, avc1.42E0FF"',
    ]) out['list ' + t] = ask(t);

    for (const c of ['audio/x-mpegurl', 'audio/mpegurl', 'application/x-mpegurl']) {
        for (const k of ['mp3', 'mp4a.40.2', 'avc1.42E01E', 'avc1.64003E', 'hvc1.1.6.L186.B0', 'vorbis']) {
            out['mpegurl ' + c + ' ' + k] = ask(c + '; codecs="' + k + '"');
        }
    }
    return out;
})()
