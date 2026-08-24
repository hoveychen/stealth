(() => {
  const html = document.documentElement ? document.documentElement.outerHTML : '';
  const text = (document.body && document.body.innerText) || '';
  const srcs = Array.from(document.querySelectorAll('script[src], iframe[src]'))
    .map((e) => e.getAttribute('src') || '');
  const has = (sel) => !!document.querySelector(sel);
  return {
    title: document.title,
    href: location.href,
    ready: document.readyState,
    nodes: document.getElementsByTagName('*').length,
    textLength: text.length,
    text: text.slice(0, 1200),
    cf: {
      chlOpt: typeof window._cf_chl_opt !== 'undefined',
      platformScript: srcs.some((s) => s.includes('/cdn-cgi/challenge-platform/')),
      challengeDom: has('#challenge-form') || has('#challenge-running') || has('#cf-chl-widget') || has('#challenge-stage'),
      justAMoment: /just a moment|un momento|checking your browser|\u60a8\u7684\u8bf7\u6c42/i.test(document.title + ' ' + text.slice(0, 400)),
      blocked: /sorry, you have been blocked|error 1020|cloudflare ray id/i.test(text),
      turnstileWidget: srcs.some((s) => s.includes('challenges.cloudflare.com/turnstile')),
      rayId: (html.match(/[Rr]ay ID:?\s*<?[a-z]*>?\s*([0-9a-f]{16})/) || [])[1] || null,
    },
    dd: {
      captchaDelivery: srcs.some((s) => s.includes('captcha-delivery.com')) || /captcha-delivery\.com/.test(html),
      blockText: /vous avez \u00e9t\u00e9 bloqu|you have been blocked|blocked by datadome|enable javascript and cookies to continue/i.test(text),
    },
    // PerimeterX. Its interstitial is the "Press & Hold" human challenge, which
    // answers 200 once the widget has loaded and so is invisible to the status
    // rule -- a headless Chrome at zillow scored a clean pass on it before this
    // mark existed. The reference id is what separates the challenge page from
    // an ordinary page that happens to use the words.
    px: {
      pressAndHold: /press (?:&|and) hold to confirm you are a human/i.test(text),
      deniedTitle: /access to this page has been denied/i.test(document.title),
      refId: /reference id:?\s*[0-9a-f-]{8,}/i.test(text),
      captchaDom: has('#px-captcha') || has('[id^="px-captcha"]'),
      appId: typeof window._pxAppId !== 'undefined' || typeof window._pxAction !== 'undefined',
    },
    // Akamai's own denial page, which names no vendor and carries a dotted
    // reference. Recorded rather than judged: it arrives as a bare 4xx, which
    // the status rule already refuses, and the mark is here so a 200-cloaked one
    // does not read as a pass.
    akamai: {
      accessDenied: /^access denied$/i.test(document.title.trim()) ||
        /you don't have permission to access this page/i.test(text),
      reference: /reference #?\s*[0-9a-f.]{10,}/i.test(text),
    },
    // Any guard's last resort: an empty document with nothing on it.
    empty: text.trim().length === 0,
  };
})()