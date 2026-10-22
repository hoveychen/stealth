// Pages for the pagination tests (MCP agent run, /crawl paging recipes):
//
//   /links/1 .. /links/N   link pagination: each page is its own URL, with a
//                          "下一页" link to the next one; the last page has none.
//   /ajax                  ajax pagination: one URL; the "下一页" button fetches
//                          /api/items?page=n and swaps the list in place; on the
//                          last page the button is gone.
//   /slow?ms=n             answers after n ms (concurrency tests).
//   /whoami?tag=x          echoes the tag (session isolation tests).
//   /headers               the request headers as JSON.
//
// Every item is "<kind>-<page>-<i>" with a title, so a run can be checked for
// having collected exactly the expected set.
//
//   node paging-server.mjs [port]      # default 9800; LINK_PAGES, AJAX_PAGES, PER_PAGE
//
// or, from a test: `const { server, base } = await startPagingServer(host, urlHost)`.

import http from 'node:http';
import { fileURLToPath } from 'node:url';

const LINK_PAGES = Number(process.env.LINK_PAGES ?? 5);
const AJAX_PAGES = Number(process.env.AJAX_PAGES ?? 4);
const PER_PAGE = Number(process.env.PER_PAGE ?? 5);

const FRUITS = ['苹果', '香蕉', '橙子', '葡萄', '西瓜', '芒果', '草莓', '桃子', '梨', '樱桃', '菠萝', '柠檬'];
const item = (kind, page, i) => ({ id: `${kind}-${page}-${i}`, title: `${FRUITS[(page * PER_PAGE + i) % FRUITS.length]} 第${page}页第${i}项`, price: page * 10 + i });
const items = (kind, page) => Array.from({ length: PER_PAGE }, (_, i) => item(kind, page, i + 1));
const li = (it) => `<li class="item" data-id="${it.id}"><span class="title">${it.title}</span> <span class="price">¥${it.price}</span> <code>${it.id}</code></li>`;

function linksPage(p) {
    const pager = [];
    if (p > 1) pager.push(`<a href="/links/${p - 1}" class="prev">上一页</a>`);
    for (let i = 1; i <= LINK_PAGES; i++) pager.push(i === p ? `<span class="current">${i}</span>` : `<a href="/links/${i}">${i}</a>`);
    if (p < LINK_PAGES) pager.push(`<a href="/links/${p + 1}" class="next">下一页</a>`);
    return `<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>商品列表 - 第${p}页</title></head><body>
<h1>商品列表（链接翻页）</h1>
<ul id="list">${items('L', p).map(li).join('')}</ul>
<nav class="pager">${pager.join(' ')}</nav>
<footer>共 ${LINK_PAGES} 页</footer>
</body></html>`;
}

const AJAX_PAGE = `<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>商品列表（加载更多）</title></head><body>
<h1>商品列表（ajax 翻页）</h1>
<div id="status">第 1 页</div>
<ul id="list">${items('A', 1).map(li).join('')}</ul>
<div class="pager"><button id="next" type="button">下一页</button></div>
<script>
let page = 1;
const total = ${AJAX_PAGES};
const btn = document.getElementById('next');
btn.addEventListener('click', async () => {
  btn.disabled = true;
  const r = await fetch('/api/items?page=' + (page + 1));
  const data = await r.json();
  page = data.page;
  document.getElementById('list').innerHTML = data.items.map((it) =>
    '<li class="item" data-id="' + it.id + '"><span class="title">' + it.title + '</span> <span class="price">¥' + it.price + '</span> <code>' + it.id + '</code></li>').join('');
  document.getElementById('status').textContent = '第 ' + page + ' 页';
  if (page >= total) btn.remove(); else btn.disabled = false;
});
</script>
</body></html>`;

function send(res, status, type, body) {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(body);
}

// The ids a complete run over each kind must collect, in page order.
export const expectedIds = (kind) => Array.from({ length: kind === 'L' ? LINK_PAGES : AJAX_PAGES }, (_, p) => items(kind, p + 1).map((it) => it.id)).flat();
export const PAGES = { links: LINK_PAGES, ajax: AJAX_PAGES, perPage: PER_PAGE };

const handler = (req, res) => {
    const u = new URL(req.url, 'http://x');
    const m = /^\/links\/(\d+)$/.exec(u.pathname);
    if (m) {
        const p = Number(m[1]);
        if (p < 1 || p > LINK_PAGES) return send(res, 404, 'text/html; charset=utf-8', '<h1>没有这一页</h1>');
        return send(res, 200, 'text/html; charset=utf-8', linksPage(p));
    }
    if (u.pathname === '/ajax') return send(res, 200, 'text/html; charset=utf-8', AJAX_PAGE);
    if (u.pathname === '/api/items') {
        const p = Number(u.searchParams.get('page'));
        if (!(p >= 1 && p <= AJAX_PAGES)) return send(res, 404, 'application/json', '{"error":"no such page"}');
        // A little latency, so a recipe that does not wait for the swap fails.
        return setTimeout(() => send(res, 200, 'application/json', JSON.stringify({ page: p, total: AJAX_PAGES, items: items('A', p) })), 150);
    }
    if (u.pathname === '/slow') {
        const ms = Math.min(Number(u.searchParams.get('ms') ?? 3000), 60000);
        return setTimeout(() => send(res, 200, 'text/html; charset=utf-8', `<!doctype html><title>slow ${ms}</title><p id="slow">slept ${ms}ms</p>`), ms);
    }
    if (u.pathname === '/headers') return send(res, 200, 'application/json', JSON.stringify(req.headers));
    if (u.pathname === '/whoami') {
        const tag = (u.searchParams.get('tag') ?? '').replace(/[^\w-]/g, '');
        return send(res, 200, 'text/html; charset=utf-8', `<!doctype html><title>whoami ${tag}</title><p id="tag">${tag}</p>`);
    }
    if (u.pathname === '/') {
        return send(res, 200, 'text/html; charset=utf-8', `<!doctype html><title>paging fixtures</title><a href="/links/1">链接翻页</a> <a href="/ajax">ajax 翻页</a>`);
    }
    send(res, 404, 'text/plain', 'not found');
};

// host: where to listen; urlHost: how the crawler reaches it (a container).
export function startPagingServer(host = '127.0.0.1', urlHost = host, port = 0) {
    const server = http.createServer(handler);
    return new Promise((resolve) => server.listen(port, host, () => resolve({ server, base: `http://${urlHost}:${server.address().port}` })));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const port = Number(process.argv[2] ?? process.env.PORT ?? 9800);
    await startPagingServer('0.0.0.0', '0.0.0.0', port);
    console.log(`paging-server on :${port} (links ${LINK_PAGES} pages, ajax ${AJAX_PAGES} pages, ${PER_PAGE} per page)`);
}
