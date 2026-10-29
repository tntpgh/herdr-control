// Acceptance check for the static board. Runs in macOS's bundled JavaScriptCore shell
// (no node/npm needed), from the worktree root:
//   /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc prototype/board/check.js
// Prints one line per check and a card->state table; throws (non-zero exit) on any failure.
var DIR = 'prototype/board/';
load(DIR + 'board.js');
var B = this.Board;
var failures = 0;
function ok(cond, msg) { print((cond ? 'ok   ' : 'FAIL ') + msg); if (!cond) failures++; }
function J(rel) { return JSON.parse(readFile(DIR + rel)); }
function walkStrings(v, fn, path) {
  path = path || '';
  if (typeof v === 'string') fn(v, path);
  else if (v && typeof v === 'object') Object.keys(v).forEach(function (k) { fn(k, path + '/' + k + '(key)'); walkStrings(v[k], fn, path + '/' + k); });
}

var board = J('fixtures/board.json'), decisions = J('fixtures/decisions.json'), jobs = J('fixtures/job-classes.json'),
  gbp = J('fixtures/gbp-drafts.json'), bounties = J('fixtures/bounties.json'),
  bebop = J('themes/bebop/theme.json'), plain = J('themes/plain/theme.json');
var NOW = Date.parse(board.generated_at);

// 1. inline copies in index.html match the JSON files (sync.py)
var html = readFile(DIR + 'index.html');
[['data-board', board], ['data-decisions', decisions], ['data-job-classes', jobs], ['data-gbp-drafts', gbp],
 ['data-bounties', bounties], ['data-theme-bebop', bebop], ['data-theme-plain', plain]].forEach(function (p) {
  var m = new RegExp('<script type="application/json" id="' + p[0] + '"[^>]*>([\\s\\S]*?)</script>').exec(html);
  ok(m && JSON.stringify(JSON.parse(m[1])) === JSON.stringify(p[1]), 'inline copy #' + p[0] + ' matches its JSON file');
});

// 2. exactly 13 job classes; unrecognized is not one
var ids = jobs.classes.map(function (c) { return c.id; });
ok(ids.length === 13 && B.JOB_CLASSES.length === 13, 'exactly 13 job classes (fixture ' + ids.length + ', board ' + B.JOB_CLASSES.length + ')');
ok(ids.slice().sort().join() === B.JOB_CLASSES.slice().sort().join(), 'fixture classes == board JOB_CLASSES');
ok(ids.indexOf('unrecognized') === -1 && jobs.unrecognized.is_class === false, "'unrecognized' is a fallback, not a class");
[['bebop', bebop], ['plain', plain]].forEach(function (t) {
  var keys = Object.keys(t[1].job_classes).sort().join();
  ok(keys === B.JOB_CLASSES.slice().sort().join(), t[0] + ' theme maps exactly the 13 classes');
  ok(!!t[1].unrecognized && !!t[1].unrecognized.badge, t[0] + ' theme has an unrecognized fallback badge');
  ok(B.jobInfo(t[1], 'triage').known === false, t[0] + ': unlisted job "triage" resolves to the fallback');
});

// 3. Bebop role assignment per SPEC
var want = { plan: 'jet', implement: 'ed', code: 'ed', design: 'ed', research: 'faye', explore: 'faye',
  review: 'vicious', 'deep-review': 'vicious', debug: 'spike' };
Object.keys(want).forEach(function (c) { ok(bebop.job_classes[c].character === want[c], 'bebop: ' + c + ' -> ' + want[c]); });
ok(bebop.job_classes.review.badge !== bebop.job_classes['deep-review'].badge, 'review and deep-review carry distinct badges');
var tier = {}; jobs.classes.forEach(function (c) { tier[c.id] = c.tier; });
ok(tier.review === 'standard-high' && tier['deep-review'] === 'deep', 'review = standard-high, deep-review = deep');
ok(bebop.function_badges.captain.character === 'jet' && bebop.function_badges.release_watch.character === 'jet', 'Jet carries captain + release-watch badges');
ok(bebop.function_badges.project_lead.character === 'spike' && bebop.function_badges.debugger.character === 'spike', 'Spike carries project-lead + debugger badges');
ok(['quick', 'mechanical'].every(function (c) { return bebop.job_classes[c].character === 'ein'; }), 'Ein carries QA/test (quick, mechanical)');
Object.keys(bebop.job_classes).forEach(function (c) {
  var ch = bebop.job_classes[c].character;
  ok(!!bebop.characters[ch], 'bebop: ' + c + ' character "' + ch + '" exists');
});

// 4. every required state is reachable from the fixtures; print the table
var seen = {}, lanes = 0, rows = [];
board.projects.forEach(function (p) {
  p.lanes.forEach(function (l) {
    lanes++;
    l.cards.forEach(function (c) {
      var s = B.deriveDisplay(c, NOW);
      seen[s] = (seen[s] || 0) + 1;
      rows.push(c.id + '\t' + c.job_class + '\t' + c.engine.kind + ':' + c.engine.state + '\t-> ' + s);
    });
  });
});
ok(lanes >= 4 && lanes <= 5, 'fixture has 4-5 lanes (' + lanes + ')');
B.REQUIRED_STATES.concat(['blocked', 'stalled', 'failed']).forEach(function (s) { ok(!!seen[s], 'fixtures cover state ' + s); });
ok(!seen.unknown, 'no fixture card falls through to unknown');
print('--- card -> display state ---'); rows.forEach(function (r) { print(r); });

// 5. stale rules: boundary, and stale is never animated
function runningAt(msAgo) { return { engine: { kind: 'task', state: 'running', updated_at: new Date(NOW - msAgo).toISOString() } }; }
ok(B.deriveDisplay(runningAt(B.STALE_AFTER_MS), NOW) === 'executing', 'running updated exactly 5 min ago -> executing');
ok(B.deriveDisplay(runningAt(B.STALE_AFTER_MS + 1000), NOW) === 'stale', 'running updated 5 min 1 s ago -> stale');
ok(B.deriveDisplay({ engine: { kind: 'task', state: 'running' } }, NOW) === 'stale', 'running with no timestamp -> stale');
Object.keys(B.STATES).forEach(function (s) {
  var anim = B.shouldAnimate(s, { reduce: false, plain: false });
  ok(anim === (s === 'executing'), 'only executing animates: ' + s + ' animate=' + anim);
});
ok(!B.shouldAnimate('executing', { reduce: true, plain: false }) && !B.shouldAnimate('executing', { reduce: false, plain: true }),
  'executing does not animate under reduced motion or plain mode');

// 6. timed-out / unanswered decisions are never approved
decisions.decisions.forEach(function (d) {
  var lit = B.decisionLiteral(d, NOW);
  ok(lit.approved === (d.status === 'answered' && d.answer === 'approve'), 'decision ' + d.id + ' (' + d.status + ') approved=' + lit.approved + ': ' + lit.text);
});
var lateOpen = { id: 'x', status: 'open', expires_at: new Date(NOW - 1000).toISOString() };
ok(B.decisionLiteral(lateOpen, NOW).key === 'timed_out' && !B.decisionLiteral(lateOpen, NOW).approved, 'open form past its deadline reads timed out, not approved');
['expired', 'gone', 'cancelled', 'weird'].forEach(function (st) {
  var lit = B.decisionLiteral({ id: 'x', status: st }, NOW);
  ok(!lit.approved && !/APPROVE\b/.test(lit.text), 'status ' + st + ' never reads as approved');
});
ok(B.deriveDisplay({ engine: { kind: 'task', state: 'completed', closure_reason: 'shipped', closure_proof: null } }, NOW) !== 'done_with_proof',
  'shipped without proof is never shown done');

// 7. state visuals: distinct labels + icons, each with a CSS rule
var css = readFile(DIR + 'board.css');
var labels = {}, icons = {};
Object.keys(B.STATES).forEach(function (s) {
  labels[B.STATES[s].label] = 1; icons[B.STATES[s].icon] = 1;
  ok(css.indexOf('.chip[data-state="' + s + '"]') !== -1 && css.indexOf('.card[data-state="' + s + '"]') !== -1, 'CSS styles state ' + s);
});
ok(Object.keys(labels).length === Object.keys(B.STATES).length, 'state labels are all distinct');
ok(Object.keys(icons).length === Object.keys(B.STATES).length, 'state icons are all distinct');
ok(/prefers-reduced-motion: reduce/.test(css) && /body\.plain \.sprite \{ display: none; \}/.test(css) && /max-width: 640px/.test(css),
  'CSS has reduced-motion, plain-mode and mobile rules');

// 8. GBP drafts (Faye) and bounties (Big Shot)
ok(gbp.drafts.length === 3, '3 GBP drafts');
var gl = {};
gbp.drafts.forEach(function (g) {
  gl[g.lane] = 1;
  ok(!!(g.title && g.copy && g.image && g.image.suggestion && g.image.rights_status && g.source && g.source.name &&
    g.source.freshness && g.source.freshness.result && g.source.freshness.checked_on && g.proposed_publish_date) &&
    !!B.GBP_STATUS[g.review_status], 'draft ' + g.id + ' has every field and a known review status (' + g.review_status + ')');
});
ok(gl.listing_story && gl.team_update && gl.guide, 'drafts cover listing story, team update, guide');
ok(bebop.panels.gbp_drafts === 'faye' && bebop.panels.bounties === 'bigshot', 'GBP panel = Faye, bounties = Big Shot');
ok(bounties.bounties.length === 2, '2 bounties');
bounties.bounties.forEach(function (b) {
  ok(['objective', 'owner', 'function', 'status', 'evidence_needed', 'verified_completion'].every(function (k) { return b[k] != null; }),
    'bounty ' + b.id + ' has objective/owner/function/status/evidence/verified');
});
var moneyHits = [];
walkStrings(bounties, function (s, path) {
  if (/\$|\breward|\bpayout|\bprize|\bpoints?\b|\brevenue|\bamount|\bprice|\busd\b/i.test(s) && !/No money, rewards, points or revenue/.test(s)) moneyHits.push(path);
});
ok(moneyHits.length === 0, 'bounty keys/text have no money/reward wording' + (moneyHits.length ? ' (found at ' + moneyHits.join(', ') + ')' : ''));
['bigshot', 'old-guys'].forEach(function (g) {
  ok(!!bebop.guests[g].sprite && !!plain.guests[g].plain_text && plain.guests[g].sprite === null, 'guest ' + g + ': sprite in bebop, text-only in plain');
});

// 9. sprites: every character and guest renders an SVG with a screen-reader label
Object.keys(bebop.characters).concat(Object.keys(bebop.guests)).forEach(function (id) {
  var p = B.findPerson(bebop, id);
  var svg = B.spriteSVG(p.sprite, bebop.sprite_style, { pose: 'rest', label: p.name + ' \u2014 ' + p.role });
  ok(/^<svg [^>]*role="img"[^>]*aria-label="[^"]+"/.test(svg) && (svg.match(/<svg/g) || []).length === (svg.match(/<\/svg>/g) || []).length,
    'sprite ' + id + ' renders (' + svg.length + ' chars) with role=img + aria-label');
});
ok(B.spriteSVG(null, null, { pose: 'rest', label: 'x' }) === '', 'no sprite (plain theme) renders nothing');

// 10. static page: no network, storage, forms, buttons or publish/approve wiring
var js = readFile(DIR + 'board.js');
var srcs = { 'board.js': js, 'index.html': html.replace(/<script type="application\/json"[\s\S]*?<\/script>/g, ''), 'board.css': css };
Object.keys(srcs).forEach(function (f) {
  var hits = ['fetch(', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon', 'localStorage', 'sessionStorage', 'indexedDB',
    'http://', 'https://', '<form', '<button', 'url(', '@import'].filter(function (n) { return srcs[f].indexOf(n) !== -1; });
  ok(hits.length === 0, f + ' has no network/storage/form/button/external-URL use' + (hits.length ? ' (found ' + hits.join(', ') + ')' : ''));
});
// 12. layouts: B (ship) is the default; every job class has exactly one station; every card lands somewhere
ok(/layout: 'ship'/.test(js) && /value="ship" checked/.test(html) && /<section id="overview"[^>]*hidden/.test(html),
  'layout B (ship) is the default; A (overview) starts hidden');
[['bebop', bebop], ['plain', plain]].forEach(function (t) {
  B.JOB_CLASSES.forEach(function (c) {
    var n = t[1].stations.filter(function (s) { return s.job_classes.indexOf(c) !== -1; }).length;
    if (n !== 1) ok(false, t[0] + ': ' + c + ' sits at ' + n + ' stations');
  });
  ok(true, t[0] + ': all 13 classes sit at exactly one station (failures listed above if any)');
  ok(t[1].stations.map(function (s) { return s.id; }).sort().join() === bebop.stations.map(function (s) { return s.id; }).sort().join(),
    t[0] + ': same station ids as bebop (layouts share structure across themes)');
  var placed = 0;
  board.projects.forEach(function (p) { p.lanes.forEach(function (l) { l.cards.forEach(function (c) { if (B.stationFor(t[1], c.job_class)) placed++; }); }); });
  ok(placed === rows.length, t[0] + ': all ' + rows.length + ' cards placed at a station (' + placed + ')');
  ok(B.stationFor(t[1], 'triage') === 'cargo', t[0] + ': unrecognized job class lands in the cargo hold');
  ok(t[1].stations.some(function (s) { return s.guest === 'bigshot' && s.shows.indexOf('bounties') !== -1; }), t[0] + ': ship has the Big Shot bounty board station');
});

// 13. dark only + WCAG AA text contrast in both themes
function lum(hex) {
  var h = hex.replace('#', ''); if (h.length === 3) h = h.replace(/./g, '$&$&');
  return [0, 2, 4].map(function (i) { var c = parseInt(h.substr(i, 2), 16) / 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); })
    .reduce(function (s, c, i) { return s + c * [0.2126, 0.7152, 0.0722][i]; }, 0);
}
function ratio(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
[['bebop', bebop.palette], ['plain', plain.palette]].forEach(function (t) {
  var P = t[1];
  ['--bg', '--surface', '--surface-2'].forEach(function (bgk) {
    ok(lum(P[bgk]) < 0.05, t[0] + ' ' + bgk + ' ' + P[bgk] + ' is dark (luminance ' + lum(P[bgk]).toFixed(3) + ')');
    ['--fg', '--muted', '--accent', '--brass', '--ok', '--warn', '--bad', '--info'].forEach(function (fgk) {
      var r = ratio(P[fgk], P[bgk]);
      ok(r >= 4.5, t[0] + ' ' + fgk + ' on ' + bgk + ' contrast ' + r.toFixed(2) + ' >= 4.5');
    });
  });
  ['--ok', '--bad'].forEach(function (k) {
    var r = ratio(P['--bg'], P[k]);
    ok(r >= 4.5, t[0] + ' filled chip text (--bg) on ' + k + ' contrast ' + r.toFixed(2) + ' >= 4.5');
  });
});
ok(/--bg: #0f1626/.test(css) && /color-scheme: dark/.test(css), 'CSS defaults are the dark palette with color-scheme: dark');

ok(/connect-src 'none'/.test(html) && /form-action 'none'/.test(html), "CSP blocks connections and form posts");

// 11. synthetic-data scan: no emails, phone numbers or street addresses in fixtures
['fixtures/board.json', 'fixtures/decisions.json', 'fixtures/gbp-drafts.json', 'fixtures/bounties.json'].forEach(function (rel) {
  var t = readFile(DIR + rel);
  var hit = /[\w.+-]+@[\w-]+\.[a-z]{2,}/i.exec(t) || /\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b/.exec(t) ||
    /\b\d{1,5}\s+[A-Z][a-z]+\s+(St|Street|Ave|Avenue|Rd|Road|Dr|Drive|Ln|Lane|Blvd|Way|Ct|Court)\b/.exec(t);
  ok(!hit, rel + ': no email/phone/street address' + (hit ? ' (found "' + hit[0] + '")' : ''));
});

// 14. render smoke: run board.js against a minimal stub DOM and inspect what it renders
var els = {}, FOCUS = null, winL = {}, docL = {};
function El(id) {
  this.id = id; this.innerHTML = ''; this.textContent = ''; this.hidden = false; this.checked = false; this.value = ''; this.L = {};
  this.classList = { set: {}, toggle: function (c, on) { this.set[c] = !!on; } };
  this.style = { props: {}, setProperty: function (k, v) { this.props[k] = v; } };
}
El.prototype.addEventListener = function (t, f) { this.L[t] = f; };
El.prototype.focus = function () { FOCUS = this.id; };
function el(id) {
  if (!els[id]) {
    els[id] = new El(id);
    var m = new RegExp('<script type="application/json" id="' + id + '"[^>]*>([\\s\\S]*?)</script>').exec(html);
    if (m) els[id].textContent = m[1];
  }
  return els[id];
}
var radios = ['ship', 'overview'].map(function (v) { var r = new El('layout-' + v); r.value = v; return r; });
var window = { matchMedia: function () { return { matches: false, addEventListener: function () {} }; }, addEventListener: function (t, f) { winL[t] = f; } };
var location = { hash: '' };
var document = { getElementById: el, querySelectorAll: function () { return radios; }, addEventListener: function (t, f) { docL[t] = f; },
  body: new El('body'), documentElement: new El('html') };
el('errors').hidden = true; // as in index.html
load(DIR + 'board.js');
function count(s, sub) { return s.split(sub).length - 1; }
function balanced(s) {
  return ['section', 'article', 'div', 'p', 'dl', 'ul', 'li', 'svg', 'header'].every(function (t) {
    return count(s, '<' + t + '>') + count(s, '<' + t + ' ') === count(s, '</' + t + '>');
  });
}
function rendered() { return Object.keys(els).filter(function (k) { return !/^data-/.test(k); }).map(function (k) { return els[k].innerHTML; }).join(''); }
var ship = el('ship-body').innerHTML;
ok(!el('ship').hidden && el('overview').hidden, 'smoke: boots into layout B (ship); A hidden');
ok(el('errors').hidden !== false, 'smoke: boot found no fixture/theme problems');
ok(count(ship, '<section class="room') === 8 && count(ship, 'class="room outside"') === 1, 'smoke: ship renders 8 stations, 1 outside the hull');
ok(count(ship, '<article class="card"') === 15, 'smoke: ship shows all 15 worker cards (' + count(ship, '<article class="card"') + ')');
ok(count(ship, '<article class="bounty"') === 2 && el('bounties').hidden, 'smoke: Big Shot board holds the 2 bounties inside the ship; standalone panel hidden');
ok(count(ship, ' anim"') === 1, 'smoke: exactly one animated figure (the station with executing workers): ' + count(ship, ' anim"'));
var hangar = ship.slice(ship.indexOf('data-area="hangar"'), ship.indexOf('data-area="cargo"'));
ok(/pose-alert"/.test(hangar) && hangar.indexOf(' anim"') === -1 && /data-state="stale"/.test(hangar),
  'smoke: hangar (only a stale worker) shows Spike in a still alert pose, not working');
ok(balanced(ship), 'smoke: ship markup tags balance');
ok(count(el('gbp-body').innerHTML, '<article class="gbp"') === 3 && /publishing is NOT wired/.test(el('gbp-body').innerHTML), 'smoke: 3 GBP drafts; approved-for-publish says NOT wired');
ok(document.documentElement.style.props['--bg'] === bebop.palette['--bg'], 'smoke: bebop palette applied');
el('opt-plain').checked = true; el('opt-plain').L.change();
ok(count(el('ship-body').innerHTML, '<svg') === 0 && document.body.classList.set.plain && document.documentElement.style.props['--bg'] === plain.palette['--bg'],
  'smoke: plain dark mode renders no sprites and applies the plain palette');
ok(/Unrecognized jobs and maintenance/.test(el('ship-body').innerHTML) && count(el('ship-body').innerHTML, '<article class="card"') === 15, 'smoke: plain ship keeps every card with text station names');
el('opt-plain').checked = false; el('opt-plain').L.change();
el('opt-reduce').checked = true; el('opt-reduce').L.change();
ok(count(el('ship-body').innerHTML, ' anim"') === 0 && document.body.classList.set.reduce, 'smoke: reduce motion removes every animated figure');
radios[1].checked = true; radios[1].L.change();
var ov = el('overview-body').innerHTML;
ok(el('ship').hidden && !el('overview').hidden && count(ov, '<li class="ov-row') === 3, 'smoke: layout A shows one line per project (3)');
ok(!el('bounties').hidden && count(el('bounties-body').innerHTML, '<article class="bounty"') === 2, 'smoke: layout A shows the standalone bounty board');
ok(balanced(ov) && balanced(el('bounties-body').innerHTML), 'smoke: overview + bounty markup tags balance');
location.hash = '#decision/d2'; winL.hashchange();
var dec = el('decision').innerHTML;
ok(!el('decision').hidden && FOCUS === 'decision-h' && /Timed out \u2014 still unanswered\. NOT approved/.test(dec) && dec.indexOf(B.esc(decisions.decisions[1].request_text)) !== -1,
  'smoke: decision d2 detail shows exact request text, literal timed-out state, focus moved');
docL.keydown({ key: 'Escape' });
ok(location.hash === 'project/lighthouse-docs', 'smoke: Escape from a decision returns to its project (' + location.hash + ')');
location.hash = '#project/lighthouse-docs'; winL.hashchange();
var dr = el('drawer').innerHTML;
ok(!el('drawer').hidden && FOCUS === 'drawer-h' && /Archive sweep/.test(dr) && /The three old guys/.test(dr) && count(dr, '<article class="card"') === 5,
  'smoke: project drawer shows lanes, 5 worker cards and the old-guys maintenance cameo');
ok(balanced(dr) && balanced(dec), 'smoke: drawer + decision markup tags balance');
var all = rendered();
ok(all.indexOf('<button') === -1 && all.indexOf('<form') === -1 && !/\son[a-z]+=/.test(all), 'smoke: no buttons, forms or inline handlers in any rendered markup');

print(failures ? failures + ' check(s) FAILED' : 'ALL CHECKS PASSED');
if (failures) throw new Error(failures + ' check(s) failed');
