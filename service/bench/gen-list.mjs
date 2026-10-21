// Writes the benchmark's small page, site/list.{html,js,css}: a link
// aggregator's front page made up from a fixed seed, with the shape of one
// (a nested-table layout, 30 ranked items of seven links each, ~240 links in
// all, ~34 KB of HTML, one ~5 KB script that only defines helpers and a click
// handler, one ~7 KB stylesheet). Titles, sites and users are invented; sites
// are under the reserved example.* domains. Two titles carry an em dash, as
// real pages do: one character above U+00FF makes V8 keep the whole page as a
// two-byte string, which triples the service's cost of serialising the
// response (and was the one difference that showed against the snapshot this
// page replaced).
//
//   node service/bench/gen-list.mjs        # rewrites site/list.*
//
// The output is committed; rerunning it gives the same bytes.

import fs from 'node:fs';
import path from 'node:path';

const site = path.join(path.dirname(new URL(import.meta.url).pathname), 'site');

// mulberry32
let seed = 0x5eed1157;
const rand = () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (a) => a[Math.floor(rand() * a.length)];
const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

const WORDS = `amber anchor arc atlas beacon birch bolt bramble cache canal cedar cinder cobalt comet copper coral crane delta dune ember fable fern flint forge garnet glacier granite harbor hazel heron indigo iris jade juniper kelp lantern larch lattice ledger lumen maple marble meadow mesa mica nectar nimbus oak onyx orbit otter pebble pine plume prism quarry quartz raven reef ridge river saffron sage shale signal slate sorrel spruce summit tallow thistle tide timber topaz tundra umber vale velvet willow zephyr`.split(' ');
const VERBS = `Building Rethinking Measuring Shipping Debugging Profiling Porting Scaling Testing Rewriting Indexing Caching Parsing Rendering Compiling Sorting Tracing Packing`.split(' ');
const NOUNS = `compiler scheduler allocator protocol renderer database tokenizer linker garbage collector query planner file system network stack type checker build system text editor search engine`.split(/ (?=[a-z]+(?: [a-z]+)?(?: |$))/);
const TAIL = ['in 200 lines', 'from scratch', 'for fun', 'at scale', 'without locks', 'in the browser', 'on a microcontroller', 'the hard way', 'in production', 'twice', '', '', ''];
const PREFIX = ['', '', '', '', 'Show: ', 'Ask: ', 'Launch: '];
const TLD = ['com', 'org', 'net'];

const cap = (w) => w[0].toUpperCase() + w.slice(1);
const title = () => {
    const tail = pick(TAIL);
    return `${pick(PREFIX)}${pick(VERBS)} a ${pick(WORDS)} ${pick(NOUNS)}${tail ? ` ${tail}` : ''}`;
};
const user = () => `${pick(WORDS)}${pick(WORDS).slice(0, int(2, 4))}${rand() < 0.4 ? int(1, 99) : ''}`;
const host = () => `${pick(WORDS)}${rand() < 0.3 ? `-${pick(WORDS)}` : ''}.example.${pick(TLD)}`;

const NAV = ['newest', 'front', 'comments', 'ask', 'show', 'jobs'];
let html = `<html lang="en" op="list"><head><meta name="referrer" content="origin"><meta name="viewport" content="width=device-width, initial-scale=1.0"><link rel="icon" href="logo.svg"><link rel="stylesheet" type="text/css" href="list.css"><title>Link List</title></head><body><center><table id="main" border="0" cellpadding="0" cellspacing="0" width="85%" bgcolor="#f4f4ee"><tr><td bgcolor="#3b6ea5"><table border="0" cellpadding="0" cellspacing="0" width="100%" style="padding:2px"><tr><td style="width:18px;padding-right:4px"><a href="list.html"><img src="logo.svg" width="18" height="18" style="border:1px white solid; display:block"></a></td><td style="line-height:12pt; height:10px;"><span class="pagetop"><b class="sitename"><a href="list.html">Link List</a></b>${NAV.map((n) => `<a href="${n}">${n}</a>`).join(' | ')} | <a href="submit" rel="nofollow">submit</a></span></td><td style="text-align:right;padding-right:4px;"><span class="pagetop"><a href="login?goto=list">login</a></span></td></tr></table></td></tr><tr style='height:10px'/><tr id="bigbox"><td><table border="0" cellpadding="0" cellspacing="0">`;

let id = 41000000 + int(0, 99999);
for (let rank = 1; rank <= 30; rank++) {
    id += int(17, 4800);
    const h = host();
    const points = int(2, 900);
    const comments = int(0, 420);
    const hours = int(1, 23);
    const u = user();
    html += `<tr class="athing submission" id="${id}"><td align="right" valign="top" class="title"><span class="rank">${rank}.</span></td><td valign="top" class="votelinks"><center><a id='up_${id}' href='vote?id=${id}&amp;how=up&amp;goto=list'><div class='votearrow' title='upvote'></div></a></center></td><td class="title"><span class="titleline"><a href="https://${h}/${pick(WORDS)}/${pick(WORDS)}-${int(1, 999)}">${title()}${rank === 5 || rank === 17 ? ` \u2014 part ${int(2, 4)}` : ''}</a><span class="sitebit comhead"> (<a href="from?site=${h}"><span class="sitestr">${h}</span></a>)</span></span></td></tr>`;
    html += `<tr><td colspan="2"></td><td class="subtext"><span class="subline"><span class="score" id="score_${id}">${points} points</span> by <a href="user?id=${u}" class="hnuser">${u}</a> <span class="age" title="2026-10-21T${String(24 - hours).padStart(2, '0')}:${String(int(0, 59)).padStart(2, '0')}:${String(int(0, 59)).padStart(2, '0')}"><a href="item?id=${id}">${hours} hour${hours > 1 ? 's' : ''} ago</a></span> <span id="unv_${id}"></span> | <a href="hide?id=${id}&amp;goto=list" class="clicky">hide</a> | <a href="item?id=${id}">${comments ? `${comments}&nbsp;comments` : 'discuss'}</a></span></td></tr>`;
    html += `<tr class="spacer" style="height:5px"></tr>`;
}
html += `<tr class="morespace" style="height:10px"></tr><tr><td colspan="2"></td><td class="title"><a href="?p=2" class="morelink" rel="next">More</a></td></tr></table></td></tr><tr><td><img src="s.gif" height="10" width="0"><table width="100%" cellspacing="0" cellpadding="1"><tr><td bgcolor="#3b6ea5"></td></tr></table><br><center><span class="yclinks">${['guidelines', 'faq', 'lists', 'api', 'security', 'legal', 'contact'].map((n) => `<a href="${n}.html">${cap(n)}</a>`).join(' | ')}</span><br><br><form method="get" action="search">Search: <input type="text" name="q" size="17" autocorrect="off" spellcheck="false" autocapitalize="off" autocomplete="off"></form></center></td></tr></table></center><script type="text/javascript" src="list.js"></script></body></html>\n`;

// Helpers in the style of such a page's script; nothing runs at load except
// adding the click listener.
let js = `function $ (id) { return document.getElementById(id); }
function byClass (el, cl) { return el ? el.getElementsByClassName(cl) : [] }
function byTag (el, tg) { return el ? el.getElementsByTagName(tg) : [] }
function allof (cl) { return byClass(document, cl) }
function classes (el) { return (el && el.className && el.className.split(' ')) || []; }
function hasClass (el, cl) { return afind(cl, classes(el)) }
function addClass (el, cl) { if (el) { var a = classes(el); if (!afind(cl, a)) { a.unshift(cl); el.className = a.join(' ')}} }
function remClass (el, cl) { if (el) { var a = classes(el); arem(a, cl); el.className = a.join(' ') } }
function uptil (el, f) { if (el) return f(el) ? el : uptil(el.parentNode, f) }
function upclass (el, cl) { return uptil(el, function (x) { return hasClass(x, cl) }) }
function html (el) { return el ? el.innerHTML : null; }
function attr (el, name) { return el.getAttribute(name) }
function tonum (x) { var n = parseFloat(x); return isNaN(n) ? null : n }
function remEl (el) { if (el) el.parentNode.removeChild(el) }
function afind (x, a) { var i = a.indexOf(x); return i == -1 ? null : x; }
function arem (a, x) { var i = a.indexOf(x); if (i != -1) a.splice(i, 1); }
function alast (a) { return a[a.length - 1] }
function aeach (fn, a) { return Array.prototype.forEach.call(a, fn) }
function apos (x, a) { return (typeof a == 'string') ? a.indexOf(x) : Array.prototype.indexOf.call(a, x) }
function amap (fn, a) { return Array.prototype.map.call(a, fn) }
function afilter (fn, a) { return Array.prototype.filter.call(a, fn) }
function vis (el, on) { if (el) { (on ? remClass : addClass)(el, 'nosee') } }
function setshow (el, on) { (on ? remClass : addClass)(el, 'noshow') }
function noshow (el) { setshow(el, false) }
function elShow (el) { setshow(el, true) }
function ind (el) { return (byTag(el, 'img')[0] || {}).width }
function onop () { return attr(document.documentElement, 'op') }
function ranknum (el) { var s = html(el) || ''; var a = s.match(/[0-9]+/); return a ? tonum(a[0]) : null }
var n1 = ranknum(allof('rank')[0]) || 1;

function fixranks () {
  var rks = allof('rank');
  aeach(function (rk) { rk.innerHTML = (apos(rk, rks) + n1) + '.' }, rks);
}

function moreurl () { var m = allof('morelink')[0]; return m ? m.href : '' }
function morenext () { return tonum(moreurl().split('p=')[1]) }

function score (id) {
  var el = $('score_' + id);
  return el ? tonum(html(el)) : null;
}

function setscore (id, n) {
  var el = $('score_' + id);
  if (el) el.innerHTML = n + (n == 1 ? ' point' : ' points');
}

function vote (id, how) {
  var up = $('up_' + id);
  var n = score(id);
  if (n !== null) setscore(id, how == 'up' ? n + 1 : n - 1);
  vis(up, how == 'un');
  var unv = $('unv_' + id);
  if (unv) unv.innerHTML = how == 'un' ? '' : ' | <a class="clicky" href="vote?id=' + id + '&amp;how=un&amp;goto=' + onop() + '">unvote</a>';
  new Image().src = 'vote?id=' + id + '&how=' + how + '&js=t';
}

function hidestory (el, id) {
  for (var i = 0; i < 2; i++) { remEl($(id).nextSibling) }
  remEl($(id));
  fixranks();
  var url = el.href.replace('hide', 'snip').replace('goto', 'onop');
  fetch(url + '&next=' + (morenext() || 1)).then(function (r) { return r.json() }).then(newstory, function () {});
}

function newstory (pair) {
  if (pair && pair[0]) {
    var sp = alast(allof('spacer'));
    sp.insertAdjacentHTML('afterend', pair[0] + sp.outerHTML);
    fixranks();
  }
}

function kidsof (id) {
  var row = $(id), out = [];
  var n = row ? ind(row) : 0;
  for (var x = row && row.nextElementSibling; x && ind(x) > n; x = x.nextElementSibling) out.push(x);
  return out;
}

function stamp (el) {
  var t = attr(el, 'title');
  if (!t) return null;
  var d = new Date(t + 'Z');
  return isNaN(d) ? null : d;
}

function ages () {
  var now = Date.now();
  aeach(function (el) {
    var d = stamp(el);
    if (!d) return;
    var h = Math.max(1, Math.round((now - d) / 3600000));
    var a = byTag(el, 'a')[0];
    if (a) a.innerHTML = h + (h == 1 ? ' hour ago' : ' hours ago');
  }, allof('age'));
}

function sitecounts () {
  var seen = {};
  aeach(function (el) { var s = html(el); seen[s] = (seen[s] || 0) + 1 }, allof('sitestr'));
  return seen;
}

function collapsed (el) { return hasClass(el, 'coll') }
function toggle (id) {
  var row = $(id);
  if (!row) return;
  (collapsed(row) ? remClass : addClass)(row, 'coll');
  aeach(function (x) { setshow(x, !collapsed(row)) }, byClass(row, 'toggled'));
}

function onclick (ev) {
  var el = upclass(ev.target, 'clicky');
  if (el) {
    var u = new URL(el.href, location);
    var p = u.searchParams;
    if (u.pathname.endsWith('/vote')) {
      vote(p.get('id'), p.get('how'));
    } else if (u.pathname.endsWith('/hide')) {
      hidestory(el, p.get('id'));
    } else if (hasClass(el, 'togg')) {
      toggle(attr(el, 'id'));
    }
    ev.stopPropagation();
    ev.preventDefault();
    return false;
  }
}

document.addEventListener("click", onclick);
`;

const fonts = 'Verdana, Geneva, sans-serif';
let css = `body  { font-family:${fonts}; font-size:10pt; color:#7a7a7a; }
td    { font-family:${fonts}; font-size:10pt; color:#7a7a7a; }

.admin td   { font-family:${fonts}; font-size:8.5pt; color:#000000; }
.subtext td { font-family:${fonts}; font-size:  7pt; color:#7a7a7a; }

input    { font-family:monospace; font-size:10pt; }
input[type='submit'] { font-family:${fonts}; }
input[readonly] { color:#7a7a7a; background-color:#f4f4ee; }
textarea { font-family:monospace; font-size:10pt; resize:both; }

a:link    { color:#000000; text-decoration:none; }
a:visited { color:#7a7a7a; text-decoration:none; }

.default { font-family:${fonts}; font-size: 10pt; color:#7a7a7a; }
.admin   { font-family:${fonts}; font-size:8.5pt; color:#000000; }
.title   { font-family:${fonts}; font-size: 10pt; color:#7a7a7a; overflow:hidden; }
.subtext { font-family:${fonts}; font-size:  7pt; color:#7a7a7a; }
.yclinks { font-family:${fonts}; font-size:  8pt; color:#7a7a7a; }
.pagetop { font-family:${fonts}; font-size: 10pt; color:#222222; line-height:12px; }
.comhead { font-family:${fonts}; font-size:  8pt; color:#7a7a7a; }
.hnname  { margin-right: 5px; }
.sitename { margin-right: 5px; }
.logo { display:block; width:16px; height:16px; border:1px solid white; color:white; font-weight:bold; text-align:center; line-height:16px; }

.titleline { display:inline; }
.titleline > a { font-size:10pt; }
.sitestr { color:#7a7a7a; }
.rank { color:#7a7a7a; }
.score { color:#7a7a7a; }
.age a { color:#7a7a7a; }
.hnuser { color:#7a7a7a; }
.morelink { color:#000000; }
.votearrow { width:10px; height:10px; border:0px; margin:3px 2px 6px; background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10'%3E%3Cpath d='M5 1 L9 9 L1 9 Z' fill='%23999'/%3E%3C/svg%3E"); background-size:10px; background-repeat:no-repeat; }
.votelinks.nosee div.votearrow.rotate180 { display:none; }
.nosee { visibility:hidden; pointer-events:none; cursor:default; }
.noshow { display:none; }
.coll .togg { color:#000; }
.spacer { height:5px; }
.morespace { height:10px; }

#main { min-width:796px; }
`;
// Per-breakpoint and per-state rules, as such stylesheets accumulate.
const SEL = ['.title', '.subtext', '.comhead', '.pagetop', '.yclinks', '.rank', '.score', '.age', '.sitestr', '.hnuser', '.titleline', '.votelinks', '.morelink', '.sitename'];
for (const w of [1200, 960, 750, 600, 480, 360]) {
    css += `\n@media only screen and (max-width: ${w}px) {\n`;
    for (const s of SEL) css += `  ${s} { font-size:${(7 + (w / 1200) * 3).toFixed(1)}pt; padding:${int(0, 4)}px ${int(0, 6)}px; }\n`;
    css += `  #main { width:100%; min-width:0; }\n}\n`;
}
for (const s of SEL) css += `${s}:hover { color:#${int(0, 0xffffff).toString(16).padStart(6, '0')}; }\n`;
css += `\n@media print { .votelinks, .yclinks, form { display:none; } }\n`;

fs.writeFileSync(path.join(site, 'list.html'), html);
fs.writeFileSync(path.join(site, 'list.js'), js);
fs.writeFileSync(path.join(site, 'list.css'), css);
const links = (html.match(/<a /g) || []).length;
console.log(`list.html ${html.length} B, ${links} links; list.js ${js.length} B; list.css ${css.length} B`);
