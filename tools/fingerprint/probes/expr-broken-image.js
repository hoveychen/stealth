// bot.sannysoft.com's "Broken Image Dimensions" row: an <img> pointed at a URL
// that cannot load. A real Chrome still lays out the broken-image icon, so the
// element reports 16x16 and the intrinsic size stays 0x0. An engine that draws
// nothing reports 0x0 for both, which is the signal that row exists to catch.
(async () => {
    const img = document.createElement('img');
    img.src = 'data:image/png;base64,AAAAAAAAAAAAAAAAAAA';
    document.body.appendChild(img);
    await new Promise((r) => {
        img.onerror = r;
        img.onload = r;
        setTimeout(r, 1500);
    });
    const out = {
        width: img.width,
        height: img.height,
        naturalWidth: img.naturalWidth,
        naturalHeight: img.naturalHeight,
        offsetWidth: img.offsetWidth,
        offsetHeight: img.offsetHeight,
        complete: img.complete,
        rect: (({ width, height }) => ({ width, height }))(img.getBoundingClientRect()),
    };
    img.remove();
    return JSON.stringify(out);
})()
