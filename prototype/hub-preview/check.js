/* Run by check.py from the repo root:
 *   jsc prototype/hub-preview/check.js
 * Exercises lib/hub_ui/ui.js's pure Ship renderer (no DOM) on the snapshots
 * check.py extracted from the preview. */
load('lib/hub_ui/ui.js');
var live = JSON.parse(readFile('tmp/hub-preview/ship-live.json'));
var down = JSON.parse(readFile('tmp/hub-preview/ship-down.json'));
var regerr = JSON.parse(readFile('tmp/hub-preview/ship-regerr.json'));
var themes = JSON.parse(readFile('tmp/hub-preview/themes.json'));
var scoped = JSON.parse(readFile('tmp/hub-preview/ship-scoped.json'));
var fails = 0;
function ok(name, cond) { print((cond ? 'ok   ' : 'FAIL ') + name); if (!cond) fails++; }
var esc = HubUI.esc;

var h = HubUI.renderShip(live, themes.bebop, { reduce: false });
live.tasks.forEach(function (t) {
  ok('label shown: ' + t.label, h.indexOf(esc(t.label)) !== -1);
  ok('state words shown for ' + t.label, h.indexOf(esc(t.words)) !== -1);
  ok('state label shown for ' + t.label, h.indexOf(esc(live.display[t.display].label)) !== -1);
});
live.stations.forEach(function (s) { ok('station rendered: ' + s.id, h.indexOf('data-station="' + s.id + '"') !== -1); });
ok('station headings are the plain labels', live.stations.every(function (s) { return h.indexOf('>' + esc(s.label) + '</h3>') !== -1; }));
ok('executing + live animates', / anim"/.test(h));
ok('only stations with an executing task animate',
  h.split('data-station="').slice(1).every(function (sec) {
    return sec.indexOf(' anim"') === -1 || sec.indexOf('data-d="executing"') !== -1;
  }));
ok('reduce motion: nothing animates', !/ anim"/.test(HubUI.renderShip(live, themes.bebop, { reduce: true })));
var hd = HubUI.renderShip(down, themes.bebop, { reduce: false });
ok('herdr down: nothing animates', !/ anim"/.test(hd));
ok('herdr down: says so', hd.indexOf('herdr subscription down') !== -1);
var hp = HubUI.renderShip(live, themes.plain, { reduce: false });
ok('plain theme: no drawings', hp.indexOf('<svg') === -1);
ok('plain theme: same state labels', live.tasks.every(function (t) { return hp.indexOf(esc(live.display[t.display].label)) !== -1; }));
ok('bebop theme: ship art drawn (same-origin static route, not inlined)',
  h.indexOf('class="ship-art"') !== -1 &&
  /(<img src="\/static\/ship-[0-9a-f]{8}\.png"|background-image:url\(\/static\/ship-[0-9a-f]{8}\.png\))/.test(h) &&
  h.indexOf('data:image/png;base64') === -1);
// r19 fix (tmp/in/r19/R19-BOUNTY-MOTION.md + R19-AMEND-SPA.md): the old
// sidebar "Maintenance log" (same S.unrecognized rows) is now the inline
// "Bounty board" section instead -- same underlying data, real card()
// markup, now also carrying owner/proof/cleared-or-open per card.
var bounty = h.split('class="bounty-board"')[1] || '';
ok('unrecognized task sits in the bounty board', bounty.indexOf('hotfix-ad-hoc') !== -1);
ok('unrecognized badge shown', bounty.indexOf('badge unrec') !== -1);
ok('bounty board cites its real source', bounty.indexOf('Source: herdr task registry') !== -1);
ok('bounty cards show owner + proof-or-unverified', /Owner: .+ \u00B7 Proof: /.test(bounty));
// r19 amendment 2 (tmp/in/r19/R19-AMEND-ESCALATION.md): the real
// per-task escalation source (feat/loop-escalation's state file) is not
// shipped yet, so every task card says so honestly -- no invented
// model/attempt-count/hold values, same count as task cards overall.
ok('escalation honesty line present at least once', h.indexOf('Escalation: tracking not enabled') !== -1);
ok('no invented escalation model/attempt data anywhere', !/current model|attempt \d|escalation reason:/i.test(h));
// tmp/in/BRIEF.md (2026-10-28) / tmp/in/REVIEW-DASH.md (F1-F3): one-page
// Ship, workers/holds/escalation inline with anchor nav, built on hub_ui
// (not a parallel STYLE/render_overview surface).
ok('subnav reaches all three new sections',
  h.indexOf('<nav class="ship-subnav"') !== -1 && h.indexOf('href="#workers"') !== -1 &&
  h.indexOf('href="#holds"') !== -1 && h.indexOf('href="#escalation"') !== -1);
var workersHtml = (h.split('id="workers"')[1] || '').split('id="holds"')[0];
ok('every live worker pane is listed', live.workers.every(function (w) { return workersHtml.indexOf(esc(w.pane)) !== -1; }));
// F2: production's herdr_live.agent is the CLI KIND ("omp"), never a model
// id -- nothing upstream of this fixture invents one, and nothing here may
// either. The honesty line must say so, and no row may claim "model:".
ok('worker agent kind shown, exactly what herdr reports (never relabelled as a model)',
  live.workers.every(function (w) { return workersHtml.indexOf('>' + esc(w.agent) + '</td>') !== -1 || workersHtml.indexOf(esc(w.agent) + ' \u00B7') !== -1; }));
ok('model is said not-recorded, never shown as if known',
  workersHtml.indexOf('Model: not recorded') !== -1 && !/\bmodel\s*[:=]\s*"?(claude|gpt|opus|sonnet|haiku)/i.test(workersHtml));
ok('no row claims a model value it does not have', live.workers.every(function (w) { return !('model' in w); }));
// N1 (tmp/in/REVIEW-DASH.md round-2): /?repo=demo-app's real ship_snapshot()
// output (check.py's "ship-scoped" dump, NOT a hand-built fixture) must
// render only its own panes, state the hidden count, and never show a pane
// with no owning task -- the static HTML fetch can't prove this (renderShip
// runs client-side), so it is proven here against the real scoped data.
var scopedHtml = HubUI.renderShip(scoped, themes.bebop, { reduce: false });
var scopedWorkersHtml = (scopedHtml.split('id="workers"')[1] || '').split('id="holds"')[0];
ok('scoped workers section lists only this repo\'s panes',
  scoped.workers.length > 0 && scoped.workers.every(function (w) { return scopedWorkersHtml.indexOf(esc(w.pane)) !== -1; }));
ok('scoped workers section never shows a pane dropped by scope',
  scopedWorkersHtml.indexOf('w2:p1') === -1 && scopedWorkersHtml.indexOf('w3:p2') === -1);
ok('scoped workers section states the hidden count', scoped.workers_hidden === 2 &&
  scopedWorkersHtml.indexOf('2 pane(s) hidden by this scope') !== -1);
ok('scoped workers section never lists a pane with an empty task',
  scoped.workers.every(function (w) { return !!w.task; }));
var holdsHtml = (h.split('id="holds"')[1] || '').split('id="escalation"')[0];
ok('holds section lists every open decision', live.decisions.open.every(function (f) { return holdsHtml.indexOf(esc(f.title)) !== -1; }));
var escHtml = h.split('id="escalation"')[1] || '';
ok('escalation section honestly stubbed, no row data', escHtml.indexOf('Escalation tracking is not enabled') !== -1);
// F3: a row is highlighted ONLY the first time its id is rendered, never on
// every refresh of already-seen data.
var allPanes = live.workers.map(function (w) { return w.pane; });
var hNoneSeen = HubUI.renderShip(live, themes.bebop, { reduce: false, seenWorkers: [] });
ok('unseen-before worker rows get the new-row entrance', allPanes.length > 0 &&
  (hNoneSeen.split('id="workers"')[1] || '').split('id="holds"')[0].indexOf('class="row-new') !== -1);
var hAllSeen = HubUI.renderShip(live, themes.bebop, { reduce: false, seenWorkers: allPanes });
ok('already-seen worker rows never re-animate as new',
  (hAllSeen.split('id="workers"')[1] || '').split('id="holds"')[0].indexOf('row-new') === -1);
var allHoldIds = live.decisions.open.map(function (f, i) { return f.id || ('_idx' + i); });
var hdNoneSeen = HubUI.renderShip(live, themes.bebop, { reduce: false, seenHolds: [] });
ok('unseen-before hold rows get the new-row entrance', allHoldIds.length > 0 &&
  (hdNoneSeen.split('id="holds"')[1] || '').split('id="escalation"')[0].indexOf('class="row-new') !== -1);
var hdAllSeen = HubUI.renderShip(live, themes.bebop, { reduce: false, seenHolds: allHoldIds });
ok('already-seen hold rows never re-animate as new',
  (hdAllSeen.split('id="holds"')[1] || '').split('id="escalation"')[0].indexOf('row-new') === -1);
ok('open decisions listed', live.decisions.open.every(function (f) { return h.indexOf(esc(f.title)) !== -1; }));
ok('expired forms never read as approved', h.indexOf('not approved, not declined') !== -1);
ok('suggestions are proposal-only', h.indexOf('Proposal-only. Nothing is dispatched from here') !== -1);
ok('hidden finished count shown', h.indexOf('finished more than a day ago not shown') !== -1);
ok('no approve/deny/dispatch control in Ship', !/<(form|button|input)\b/.test(h));
// r5 review (tmp/in/REVIEW-r5.md item 3): the headline used to count ONLY
// open decisions, so "Needs your call: 0 -- nothing needs you" rendered
// even with a blocked task, if there were zero open decisions. Fails on
// cd1eb3d (headline is 0 even though live.json has 7 attention-worthy
// tasks), passes after.
var noDecisions = JSON.parse(JSON.stringify(live));
noDecisions.decisions.open = [];
var attnTaskCount = noDecisions.tasks.filter(function (t) { return (noDecisions.display[t.display] || {}).attention; }).length;
var hNoDec = HubUI.renderShip(noDecisions, themes.bebop, {});
var headline = (hNoDec.match(/<strong>Needs your call: (\d+)<\/strong>/) || [])[1];
ok('r5: zero open decisions but a blocked task still needs a call', attnTaskCount > 0 && headline === String(attnTaskCount));
ok('r5: headline never says "nothing needs you" while a task has attention', hNoDec.indexOf('nothing needs you') === -1);
ok('r5: attention states named next to the headline, not only behind ship-more',
  hNoDec.split('<details class="ship-more"')[0].indexOf('blocked') !== -1);
ok('registry error: nothing drawn, says why', HubUI.renderShip(regerr, themes.bebop, {}).indexOf('Registry unavailable') === 0 ||
  HubUI.renderShip(regerr, themes.bebop, {}).indexOf('Registry unavailable') > 0);
var evil = JSON.parse(JSON.stringify(live));
evil.tasks[0].label = '<img src=x onerror=alert(1)>';
evil.tasks[0].words = '"><script>alert(1)</script>';
evil.suggestions = [{ kind: '<b>', text: '<script>x</script>', status: 'No decision yet.' }];
var he = HubUI.renderShip(evil, themes.bebop, {});
ok('labels escaped', he.indexOf('<img src=x') === -1 && he.indexOf('&lt;img src=x') !== -1);
ok('words escaped', he.indexOf('<script>alert(1)') === -1);
ok('suggestions escaped', he.indexOf('<script>x') === -1);
ok('emblem drawn for overview (bebop)', HubUI.emblem(themes.bebop, 'overview').indexOf('<svg') === 0);
ok('no emblem in plain', HubUI.emblem(themes.plain, 'overview') === '');
print(fails ? fails + ' FAILED' : 'ALL CHECKS PASSED');
if (fails) throw new Error('check.js failed');
