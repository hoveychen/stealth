function $ (id) { return document.getElementById(id); }
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
