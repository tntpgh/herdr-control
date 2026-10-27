/* Run by check.py from the repo root:
 *   jsc prototype/hub-preview/check.js
 * Exercises lib/hub_ui/ui.js's pure Ship renderer (no DOM) on the snapshots
 * check.py extracted from the preview. */
load('lib/hub_ui/ui.js');
var live = JSON.parse(readFile('tmp/hub-preview/ship-live.json'));
var down = JSON.parse(readFile('tmp/hub-preview/ship-down.json'));
var regerr = JSON.parse(readFile('tmp/hub-preview/ship-regerr.json'));
var themes = JSON.parse(readFile('tmp/hub-preview/themes.json'));
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
ok('bebop theme: crew drawn', (h.match(/<svg/g) || []).length >= 8);
var cargo = h.split('data-station="cargo"')[1].split('</section>')[0];
ok('unrecognized task sits in cargo', cargo.indexOf('hotfix-ad-hoc') !== -1);
ok('unrecognized badge shown', cargo.indexOf('badge unrec') !== -1);
ok('open decisions listed', live.decisions.open.every(function (f) { return h.indexOf(esc(f.title)) !== -1; }));
ok('expired forms never read as approved', h.indexOf('not approved, not declined') !== -1);
ok('suggestions are proposal-only', h.indexOf('Proposal-only. Nothing is dispatched from here') !== -1);
ok('hidden finished count shown', h.indexOf('finished more than a day ago not shown') !== -1);
ok('no approve/deny/dispatch control in Ship', !/<(form|button|input)\b/.test(h));
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
