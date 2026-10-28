/* hub_ui client: display prefs, crew emblems, Ship view (layout B on /).
 * Presentation only: no fetch, no form, no POST. Every status word it prints
 * comes from the server snapshot (#ship-data); the theme supplies drawings
 * and place names. Exported as HubUI for check.js (no DOM needed). */
(function (root) {
  'use strict';
  var KEY = 'hub.ui';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function col(c, fallback) { return /^#[0-9a-fA-F]{3,8}$/.test(c || '') ? c : fallback; }
  function num(n, fallback) { return typeof n === 'number' && isFinite(n) ? n : fallback; }
  function fmtSpan(ms) {
    if (ms == null || isNaN(ms)) return 'an unknown time';
    var m = Math.floor(Math.abs(ms) / 60000);
    if (m < 1) return 'under a minute';
    if (m < 60) return m + ' min';
    if (m < 48 * 60) return Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
    return Math.floor(m / 1440) + ' days';
  }
  function ago(iso, nowMs) {
    var t = typeof iso === 'number' ? iso : Date.parse(iso);
    return isNaN(t) ? 'at an unrecorded time' : fmtSpan(nowMs - t) + ' ago';
  }

  // ---------- sprites (same drawing code as prototype/board/board.js) ----------
  function human(sp, a, r, cx, pose) {
    var hair = col(sp.hair_color, '#333'), skin = col(sp.skin, '#d8b08c'), coat = col(sp.coat, '#445'),
      shirt = col(sp.shirt, '#eee'), acc = col(sp.accent, '#b08d57'), facial = col(sp.facial, hair);
    var bw = { broad: 34, tall: 26, slim: 24, thin: 22 }[sp.build] || 28;
    var L = cx - bw / 2, R = cx + bw / 2, ex = sp.extras || [], has = function (x) { return ex.indexOf(x) !== -1; };
    var p = [];
    if (has('katana')) p.push('<line x1="6" y1="54" x2="42" y2="22" stroke="#c9ccd1" stroke-width="1.6"/><line x1="6" y1="54" x2="13" y2="48" stroke="#2a1a12" stroke-width="3"/>');
    if (sp.hair === 'long') p.push('<path d="M' + (cx - r - 2) + ' 15 Q' + cx + ' 2 ' + (cx + r + 2) + ' 15 L' + (cx + r + 4) + ' 46 L' + (cx - r - 4) + ' 46 Z" fill="' + hair + '"' + a + '/>');
    p.push('<path d="M' + L + ' 56 L' + (L + 2) + ' 34 Q' + cx + ' 28 ' + (R - 2) + ' 34 L' + R + ' 56 Z" fill="' + coat + '"' + a + '/>');
    p.push('<path d="M' + (cx - 5) + ' 31 L' + cx + ' 42 L' + (cx + 5) + ' 31 Z" fill="' + shirt + '"/>');
    if (has('tie')) p.push('<path d="M' + (cx - 1) + ' 32 L' + (cx + 1) + ' 32 L' + (cx + 1.5) + ' 44 L' + cx + ' 46 L' + (cx - 1.5) + ' 44 Z" fill="' + acc + '"/>');
    if (has('red_trim')) p.push('<path d="M' + (L + 3) + ' 36 L' + (L + 2) + ' 56 M' + (R - 3) + ' 36 L' + (R - 2) + ' 56" stroke="#c0392b" stroke-width="2.5"/>');
    p.push('<rect x="' + (L - 3) + '" y="35" width="5" height="17" rx="2" fill="' + coat + '"' + a + '/>');
    var armFill = has('metal_arm') ? acc : coat;
    if (pose === 'wait') {
      p.push('<rect x="' + (R - 2) + '" y="13" width="5" height="22" rx="2" fill="' + armFill + '"' + a + '/><circle cx="' + (R + 0.5) + '" cy="11" r="3" fill="' + skin + '"' + a + '/>');
    } else {
      p.push('<rect x="' + (R - 2) + '" y="35" width="5" height="17" rx="2" fill="' + armFill + '"' + a + '/>');
      if (has('metal_arm')) p.push('<path d="M' + (R - 2) + ' 41 h5 M' + (R - 2) + ' 46 h5" stroke="#5d6670" stroke-width="1"/>');
    }
    if (pose === 'read') p.push('<rect x="' + (cx - 8) + '" y="38" width="16" height="11" fill="#f7f3ea"' + a + '/><path d="M' + (cx - 5) + ' 42 h10 M' + (cx - 5) + ' 45 h8" stroke="#555" stroke-width="1"/>');
    p.push('<rect x="' + (cx - 3) + '" y="25" width="6" height="7" fill="' + skin + '"/>');
    p.push('<circle cx="' + cx + '" cy="19" r="' + r + '" fill="' + skin + '"' + a + '/>');
    p.push('<circle cx="' + (cx - 3) + '" cy="19.5" r="1.1" fill="#161616"/><circle cx="' + (cx + 3) + '" cy="19.5" r="1.1" fill="#161616"/>');
    p.push('<path d="M' + (cx - 2) + ' 24 h4" stroke="#6b3b2b" stroke-width="1"/>');
    if (has('beard')) p.push('<path d="M' + (cx - r + 1) + ' 20 Q' + (cx - r + 1) + ' 30 ' + cx + ' 30.5 Q' + (cx + r - 1) + ' 30 ' + (cx + r - 1) + ' 20 Q' + cx + ' 26.5 ' + (cx - r + 1) + ' 20 Z" fill="' + facial + '"/>');
    if (has('mustache')) p.push('<path d="M' + (cx - 6) + ' 24 Q' + cx + ' 19.5 ' + (cx + 6) + ' 24 Q' + cx + ' 22.5 ' + (cx - 6) + ' 24 Z" fill="' + facial + '"/>');
    switch (sp.hair) {
      case 'fluffy':
        p.push('<g fill="' + hair + '"' + a + '><circle cx="' + (cx - 7) + '" cy="13" r="5"/><circle cx="' + (cx - 2) + '" cy="9.5" r="6"/><circle cx="' + (cx + 4) + '" cy="9.5" r="6"/><circle cx="' + (cx + 8.5) + '" cy="13.5" r="5"/><circle cx="' + (cx - 9.5) + '" cy="17" r="3.5"/></g>');
        p.push('<path d="M' + (cx - 1) + ' 11 Q' + (cx + 3) + ' 22 ' + (cx + 7) + ' 21 Q' + (cx + 6) + ' 14 ' + (cx + 3) + ' 11 Z" fill="' + hair + '"/>');
        break;
      case 'bob':
        p.push('<path d="M' + (cx - r - 1.5) + ' 25 L' + (cx - r - 1.5) + ' 17 Q' + (cx - r) + ' 7.5 ' + cx + ' 7.5 Q' + (cx + r) + ' 7.5 ' + (cx + r + 1.5) + ' 17 L' + (cx + r + 1.5) + ' 25 L' + (cx + r - 2) + ' 25 L' + (cx + r - 2) + ' 16 L' + (cx - r + 2) + ' 16 L' + (cx - r + 2) + ' 25 Z" fill="' + hair + '"' + a + '/>');
        break;
      case 'spiky':
        p.push('<path d="M' + (cx - r - 1) + ' 18 L' + (cx - r - 5) + ' 9 L' + (cx - 5) + ' 11 L' + (cx - 3) + ' 2 L' + (cx + 1) + ' 10 L' + (cx + 6) + ' 2 L' + (cx + 6) + ' 10 L' + (cx + r + 5) + ' 8 L' + (cx + r + 1) + ' 18 Q' + cx + ' 9 ' + (cx - r - 1) + ' 18 Z" fill="' + hair + '"' + a + '/>');
        break;
      case 'long':
        p.push('<path d="M' + (cx - r - 1) + ' 17 Q' + (cx - r) + ' 8 ' + cx + ' 8.5 Q' + (cx + r) + ' 8 ' + (cx + r + 1) + ' 17 Q' + (cx + 4) + ' 11 ' + cx + ' 13 Q' + (cx - 4) + ' 11 ' + (cx - r - 1) + ' 17 Z" fill="' + hair + '"' + a + '/>');
        p.push('<path d="M' + (cx - r - 1) + ' 15 L' + (cx - r + 2.5) + ' 15 L' + (cx - r + 2) + ' 30 L' + (cx - r - 2) + ' 30 Z M' + (cx + r + 1) + ' 15 L' + (cx + r - 2.5) + ' 15 L' + (cx + r - 2) + ' 30 L' + (cx + r + 2) + ' 30 Z" fill="' + hair + '"' + a + '/>');
        break;
      case 'cowboy_hat':
        p.push('<ellipse cx="' + cx + '" cy="12" rx="' + (r + 8) + '" ry="2.6" fill="' + hair + '"' + a + '/><path d="M' + (cx - 6) + ' 12 L' + (cx - 5) + ' 3 Q' + cx + ' 0.5 ' + (cx + 5) + ' 3 L' + (cx + 6) + ' 12 Z" fill="' + hair + '"' + a + '/><rect x="' + (cx - 6) + '" y="9" width="12" height="2" fill="' + acc + '"/>');
        break;
      case 'cap':
        p.push('<path d="M' + (cx - r) + ' 16 Q' + cx + ' 5 ' + (cx + r) + ' 16 Z" fill="' + hair + '"' + a + '/><path d="M' + (cx - r - 2) + ' 16 h' + (2 * r + 4) + '" stroke="' + hair + '" stroke-width="2"/>');
        break;
    }
    if (has('headband')) p.push('<rect x="' + (cx - r) + '" y="11.5" width="' + (2 * r) + '" height="2.6" rx="1" fill="' + acc + '"/>');
    if (has('goggles')) p.push('<path d="M' + (cx - r) + ' 12 h' + (2 * r) + '" stroke="#333" stroke-width="1.4"/><circle cx="' + (cx - 4) + '" cy="12" r="3" fill="' + acc + '"' + a + '/><circle cx="' + (cx + 4) + '" cy="12" r="3" fill="' + acc + '"' + a + '/>');
    if (has('crow')) p.push('<path d="M' + (R - 6) + ' 31 Q' + (R - 2) + ' 24 ' + (R + 3) + ' 27 L' + (R + 7) + ' 26 L' + (R + 3) + ' 29 Q' + (R + 1) + ' 33 ' + (R - 5) + ' 33 Z" fill="#0d0d10" stroke="#3a3a44" stroke-width="0.6"/><circle cx="' + (R + 2) + '" cy="27.5" r="0.7" fill="#d33"/>');
    return p.join('');
  }
  function dog(sp, a) {
    var fur = col(sp.hair_color, '#c98a3e'), white = col(sp.coat, '#f7f0e2'), acc = col(sp.accent, '#c0392b');
    return '<rect x="13" y="46" width="4" height="7" fill="' + fur + '"' + a + '/><rect x="33" y="46" width="4" height="7" fill="' + fur + '"' + a + '/>' +
      '<ellipse cx="27" cy="42" rx="16" ry="8" fill="' + fur + '"' + a + '/><ellipse cx="22" cy="45" rx="8" ry="4.5" fill="' + white + '"/>' +
      '<path d="M8 25 L7 10 L15 20 Z M20 20 L26 9 L25 25 Z" fill="' + fur + '"' + a + '/><path d="M9.5 21 L9 14 L13 19 Z M21.5 20 L24.5 13 L24 21 Z" fill="#e8a8a0"/>' +
      '<circle cx="16" cy="29" r="9" fill="' + fur + '"' + a + '/><ellipse cx="16" cy="33" rx="5.5" ry="4" fill="' + white + '"/>' +
      '<circle cx="12.5" cy="27" r="1.1" fill="#161616"/><circle cx="19.5" cy="27" r="1.1" fill="#161616"/><ellipse cx="16" cy="31" rx="1.6" ry="1.1" fill="#161616"/>' +
      '<rect x="10" y="36.5" width="12" height="2.4" rx="1" fill="' + acc + '"/><path d="M42 38 Q46 34 44 31" stroke="' + fur + '" stroke-width="3" fill="none"/>';
  }
  function trio(sp, a) {
    var out = [], xs = [10, 24, 38];
    for (var i = 0; i < 3; i++) {
      var cx = xs[i], hair = col(sp.hair_color, '#555'), skin = col(sp.skin, '#c9a27e'), coat = col(sp.coat, '#6b6255'), beard = col(sp.accent, '#e8e4dc');
      out.push('<path d="M' + (cx - 6) + ' 56 L' + (cx - 5) + ' 36 Q' + cx + ' 32 ' + (cx + 5) + ' 36 L' + (cx + 6) + ' 56 Z" fill="' + coat + '"' + a + '/>');
      out.push('<circle cx="' + cx + '" cy="27" r="5.5" fill="' + skin + '"' + a + '/>');
      out.push('<circle cx="' + (cx - 2) + '" cy="27" r="0.8" fill="#161616"/><circle cx="' + (cx + 2) + '" cy="27" r="0.8" fill="#161616"/>');
      if (i === 1) out.push('<path d="M' + (cx - 5) + ' 28 Q' + cx + ' 37 ' + (cx + 5) + ' 28 Q' + cx + ' 32 ' + (cx - 5) + ' 28 Z" fill="' + beard + '"/>');
      else out.push('<path d="M' + (cx - 3) + ' 30 Q' + cx + ' 28 ' + (cx + 3) + ' 30" stroke="' + beard + '" stroke-width="1.6" fill="none"/>');
      out.push('<path d="M' + (cx - 6) + ' 24 Q' + cx + ' 15 ' + (cx + 6) + ' 24 Z" fill="' + hair + '"' + a + '/><path d="M' + (cx - 7.5) + ' 24 h15" stroke="' + hair + '" stroke-width="1.6"/>');
    }
    return out.join('');
  }
  function spriteSVG(sp, style, opt) {
    if (!sp) return '';
    style = style || {};
    var a = ' stroke="' + col(style.outline, '#0b1222') + '" stroke-width="' + num(style.outline_width, 1.5) + '"';
    var size = opt.size || 48;
    var fig = sp.body === 'dog' ? dog(sp, a) : sp.body === 'trio' ? trio(sp, a) : human(sp, a, num(style.head_radius, 9), 24, opt.pose);
    return '<svg class="sprite pose-' + esc(opt.pose || 'rest') + (opt.animate ? ' anim' : '') + '" viewBox="0 0 48 56" width="' + size + '" height="' + Math.round(size * 56 / 48) +
      '" role="img" aria-label="' + esc(opt.label) + '"><title>' + esc(opt.label) + '</title>' +
      '<rect x="1" y="1" width="46" height="54" rx="' + num(style.corner_radius, 4) + '" fill="' + col(style.frame_fill, '#26365a') + '" stroke="' + col(style.frame, '#b08d57') + '" stroke-width="1.5"/>' +
      '<g class="sp-fig">' + fig + '</g>' +
      (opt.pose === 'alert' ? '<text x="39" y="13" font-size="13" font-weight="700" fill="#ff7a6b">!</text>' : '') +
      '</svg>';
  }

  // ---------- Ship (layout B): pure, so check.js can run it without a DOM ----------
  function avatar(theme, who, pose, animate, size) {
    var c = who && theme && theme.characters && theme.characters[who];
    if (!c || !c.sprite) return '';
    return spriteSVG(c.sprite, theme.sprite_style, { pose: pose, size: size, animate: animate,
      label: c.name + ' \u2014 ' + c.role + (c.look ? ' (' + c.look + ')' : '') });
  }
  function flavourLine(theme, who, seed) {
    var c = who && theme && theme.characters && theme.characters[who];
    if (!c || !c.flavour || !c.flavour.length) return '';
    return '<p class="flavour">\u201C' + esc(c.flavour[seed % c.flavour.length]) + '\u201D</p>';
  }
  function stChip(S, key) {
    var d = S.display[key] || S.display.unknown;
    return '<span class="st" data-d="' + esc(key) + '"><span aria-hidden="true">' + esc(d.icon) + '</span> ' + esc(d.label) + '</span>';
  }
  // r19 fix (tmp/in/r19/R19-BOUNTY-MOTION.md section A, amended by
  // tmp/in/r19/R19-AMEND-SPA.md): "core crew = recurring work; occasional
  // jobs = BOUNTIES". The real, already-flowing signal for "occasional"
  // is station: __init__.py's station_of() maps every known JOB_CLASSES
  // entry to one of the 5 crew rooms, so a row with station===null is a
  // task whose job class has no assigned crew room at all -- exactly
  // "occasional", not "core crew's regular work". `card()` already drew
  // every field this needs (label/state/job/repo/pane/updated_at); the
  // one real field missing was closure_proof, which herdr_data() already
  // joins per task (hub.py's own comment, ~line 930) but ship_snapshot()
  // never copied past its row loop until this round. A bounty is
  // "Cleared" only when display is done_with_proof (closure_proof
  // present AND the registry's own completed transition recorded it --
  // display_of()'s own rule, not a new one invented here); anything else
  // is "Open", and "Proof: unverified" when there is truly no
  // closure_proof on file, never invented.
  function card(S, r, nowMs) {
    var d = S.display[r.display] || S.display.unknown;
    var bounty = r.station === null;
    var cleared = r.display === 'done_with_proof';
    return '<article class="wcard' + (bounty ? ' bounty-card' : '') + '" data-d="' + esc(r.display) + '" aria-label="' + esc(r.label + ' \u2014 ' + d.label) + '">' +
      '<h4>' + esc(r.label) + '</h4>' +
      '<p>' + stChip(S, r.display) + ' <span class="badge' + (r.job === 'unrecognized' ? ' unrec' : '') + '">' + esc(r.job_label) + '</span>' +
      (bounty ? ' <span class="badge ' + (cleared ? 'cleared' : 'open') + '">' + (cleared ? 'Cleared' : 'Open') + '</span>' : '') +
      (r.state_stale ? ' <span class="badge stale">Stale</span>' : '') + '</p>' +
      '<p>' + esc(r.words) + '</p>' +
      (bounty ? '<p class="wmeta">Owner: ' + esc(r.project) + ' \u00B7 Proof: ' + (r.closure_proof ? esc(r.closure_proof) : 'unverified') + '</p>' : '') +
      '<p class="wmeta">' + esc(r.repo) + ' \u00B7 pane ' + esc(r.pane || '\u2014') + ' \u00B7 updated ' + esc(ago(r.updated_at, nowMs)) +
      ' \u00B7 <a href="/herdr?repo=' + encodeURIComponent(r.repo) + '">herdr</a></p>' +
      escalationLine(r) + '</article>';
  }
  // r19 amendment 2 (tmp/in/r19/R19-AMEND-ESCALATION.md): "current model,
  // attempt count, escalation reason, last verified progress, real hold"
  // per task card. Source is the read-only state file the feat/loop-
  // escalation lane is defining -- schema lives in ITS OWN PROOF, not
  // shipped anywhere this repo can read yet (no field on any herdr_data()
  // row today carries it). "Model shown only if read from real state":
  // there is no real state, so no model is ever shown here -- showing
  // "not enabled" is the honest fact, not a placeholder standing in for
  // data. No <details> wrapper: an expand arrow over a single fixed
  // sentence with nothing behind it would itself be a placeholder that
  // looks live. Once that source ships, this is the one function to
  // change -- read r.escalation here instead of this fixed string.
  function escalationLine(r) {
    return '<p class="wmeta dim">Escalation: tracking not enabled</p>';
  }
  function extra(S, kind, nowMs) {
    var dec = S.decisions, out;
    switch (kind) {
      case 'decisions':
        out = '<div class="room-extra"><p><strong>Open decisions: ' + dec.open.length + '</strong>' +
          (dec.open.length ? ' \u2014 answer them on <a href="/decisions">decisions</a>.' : '.') + '</p>';
        if (dec.open.length) out += '<ul>' + dec.open.map(function (f) {
          var exp = typeof f.expires_at === 'number' ? f.expires_at : Date.parse(f.expires_at);
          return '<li>' + esc(f.title) + ' <span class="dim">\u00B7 served ' + esc(ago(f.created_at, nowMs)) +
            (isNaN(exp) || exp == null ? '' : ' \u00B7 ' + (exp > nowMs ? 'expires in ' + esc(fmtSpan(exp - nowMs)) : 'past its deadline, still unanswered')) + '</span></li>';
        }).join('') + '</ul>';
        if (dec.expired_recent) out += '<p>' + dec.expired_recent + ' recent form(s) expired or went away unanswered \u2014 not approved, not declined.</p>';
        if (dec.portal_error) out += '<p><span class="pill bad">legacy portal unreadable</span></p>';
        else if (dec.portal_open) out += '<p>' + dec.portal_open + ' stray legacy-portal row(s) \u2014 listed on <a href="/decisions">decisions</a>.</p>';
        return out + '</div>';
      case 'projects':
        if (!S.projects.length) return '<p class="room-extra dim">No projects with tasks in view.</p>';
        return '<div class="room-extra"><p>Projects in view (<a href="/projects">all projects</a>):</p><ul>' + S.projects.map(function (p) {
          return '<li>' + esc(p.name) + ' \u2014 ' + p.tasks + ' task(s)' + (p.attention ? ', <strong>' + p.attention + ' need a look</strong>' : ', nothing needs you') + '</li>';
        }).join('') + '</ul></div>';
    }
    return '';
  }
  function sideCard(title, kindLabel, text, statusWords) {
    return '<article class="sidecard">' +
      '<h4>' + (kindLabel ? '<span class="pill">' + esc(kindLabel) + '</span> ' : '') + esc(title) + '</h4>' +
      (text ? '<p>' + esc(text) + '</p>' : '') +
      (statusWords ? '<p class="dim">' + esc(statusWords) + '</p>' : '') + '</article>';
  }
  function bigShotPanel(S, theme) {
    var c = theme && theme.characters && theme.characters.bigshot;
    var head = '<h3>' + (c ? esc(c.name) + ' \u2014 ' : '') + 'Suggestions (proposal-only)</h3>';
    if (!S.suggestions.length) {
      return '<div class="side-panel">' + head + '<p class="dim">Nothing suggested. Loops: ' +
        (S.loops.total - S.loops.bad.length) + '/' + S.loops.total + ' healthy.</p></div>';
    }
    return '<div class="side-panel">' + head +
      '<p class="dim">Proposal-only. Nothing is dispatched from here; decide on <a href="/loops">loops</a>.</p>' +
      S.suggestions.map(function (s) { return sideCard(s.text, s.kind, '', s.status); }).join('') + '</div>';
  }
  // r19 fix (tmp/in/r19/R19-BOUNTY-MOTION.md section A + R19-AMEND-SPA.md):
  // replaces the old sidebar "Maintenance log" (same S.unrecognized data,
  // same rows, same card()) with an inline Bounty Board section on the
  // main page -- T's amendment explicitly said inline, not a tab, and
  // showing the same rows in two different panels would be the "fake/
  // duplicated" presentation the spec warns against, not two real
  // sources. Source cited in the page itself, not just here: hub.py's
  // herdr_data() tasks, joined through __init__.py's job_of()/
  // station_of() (station===null = job class with no assigned crew
  // room). Read-only -- ship_snapshot() only ever reads this, nothing in
  // the bounty board writes anything.
  function bountyBoard(S, theme, nowMs) {
    var c = theme && theme.characters && theme.characters['old-guys'];
    var rows = S.unrecognized;
    var portrait = c && c.sprite ? avatar(theme, 'old-guys', 'rest', false, 32) : '';
    var head = '<h3>' + (portrait ? '<span class="bounty-portrait">' + portrait + '</span>' : '') +
      'Bounty board' + (c ? ' \u2014 ' + esc(c.name) : '') + '</h3>';
    var sourceLine = '<p class="dim">Source: herdr task registry, tasks with no assigned crew station' +
      (S.synthetic ? ' (synthetic preview)' : '') + ' \u00B7 checked ' + esc(ago(S.generated_at, nowMs)) + '</p>';
    if (!rows.length) {
      return '<section class="bounty-board" aria-label="Bounty board">' + head + sourceLine +
        '<p class="dim">No open bounties \u2014 nothing in the registry falls outside the five crew stations right now.</p></section>';
    }
    var cleared = rows.filter(function (r) { return r.display === 'done_with_proof'; });
    var openN = rows.length - cleared.length;
    var summary = '<p>' + openN + (openN === 1 ? ' open bounty' : ' open bounties') + ', ' +
      cleared.length + (cleared.length === 1 ? ' cleared' : ' cleared') + ' (proof on file).</p>';
    return '<section class="bounty-board" aria-label="Bounty board">' + head + sourceLine + summary +
      '<details class="bounty-list"><summary>' + rows.length + (rows.length === 1 ? ' bounty' : ' bounties') +
      ' \u2014 show</summary><div class="wcards">' + rows.map(function (r) { return card(S, r, nowMs); }).join('') +
      '</div></details></section>';
  }
  // r12 addendum (tmp/in/ITERATE-r12-ADDENDUM.md items 5-7, T 21:26
  // "more reactive... feed of things... expanding and collapsing
  // cleanly"): compact, collapsed-by-default feeds built only from S --
  // the same live snapshot every other panel already reads, nothing new
  // tracked. <details>/<summary> is used instead of a literal <button>:
  // check.js's 'no approve/deny/dispatch control in Ship' assertion is a
  // blanket ban on <form|button|input> anywhere in Ship (prototype/
  // hub-preview/check.js:43), predating this round and still in force --
  // <summary> is natively keyboard-operable (Enter/Space, real Tab stop)
  // with no JS required for the toggle itself; aria-expanded is kept in
  // sync by a 'toggle' listener (DOM wiring section below) since
  // <details> doesn't set that attribute on its own. Each feed shows every
  // task's own real display chip (stChip) -- the same executing/
  // unconfirmed distinction the rest of the page already uses, so a stale
  // registry-only "running" row never reads as live running work here
  // either.
  var DONE_DISPLAY = { done_with_proof: 1, closed: 1, cancelled: 1, failed: 1, lost: 1 };
  function feedList(items) {
    return '<ul class="feed-list">' + items.map(function (i) {
      return '<li><span class="feed-label">' + esc(i.label) + '</span> ' + (i.chip || '') +
        '<span class="feed-meta dim">' + esc(i.meta) + '</span></li>';
    }).join('') + '</ul>';
  }
  function feedPanel(id, title, items, cap, nowMs, S, emptyText, source) {
    var shown = items.slice(0, cap), more = items.length - shown.length;
    var stale = S.live_connected ? '' : ' \u00B7 herdr disconnected, times are registry copies';
    var bodyId = 'feed-' + id + '-body';
    // r14b fix (tmp/in/FIX-r14b.md item 5): each feed now names its real
    // source (never just a generic title), on top of the "as of" timestamp
    // already shown.
    return '<details class="feed-panel" id="feed-' + id + '"><summary aria-expanded="false" aria-controls="' + bodyId + '">' +
      esc(title) + ' <span class="feed-count">' + items.length + '</span>' +
      '<span class="dim"> \u00B7 as of ' + esc(ago(S.generated_at, nowMs)) + esc(stale) + '</span></summary>' +
      '<div id="' + bodyId + '"><p class="feed-source dim">Source: ' + esc(source) + '</p>' +
      (items.length ? feedList(shown) + (more ? '<p class="dim">' + more + ' more not shown.</p>' : '')
                    : '<p class="dim">' + esc(emptyText) + '</p>') +
      '</div></details>';
  }

  function renderShip(S, theme, prefs) {
    var nowMs = Date.parse(S.generated_at);
    if (S.error) return '<p class="ship-alert">Registry unavailable: ' + esc(S.error) + '. Nothing below would be true, so nothing is drawn.</p>';
    var counts = {}, attn = [];
    S.tasks.forEach(function (r) { counts[r.display] = (counts[r.display] || 0) + 1; });
    Object.keys(S.display).forEach(function (k) {
      if (counts[k] && S.display[k].attention) attn.push(counts[k] + ' ' + S.display[k].label.toLowerCase());
    });
    var moving = S.live_connected && !prefs.reduce;
    // r14b fix (tmp/in/FIX-r14b.md item 4): S.synthetic is hub.py's
    // PREVIEW_SYNTHETIC, true only under prototype/hub-preview/preview.py
    // fixture data -- never true against the live registry. A prominent,
    // always-visible banner (not behind any details) so a screenshot or a
    // demo session can never be mistaken for the real board.
    var synthBanner = S.synthetic ?
      '<p class="ship-alert synthetic-banner" role="status"><strong>SYNTHETIC / DEMO DATA</strong> \u2014 preview fixtures, not the live herdr registry.</p>' : '';
    var alert = S.live_connected ? '' :
      '<p class="ship-alert" role="status">herdr subscription down: \u201Crunning\u201D rows are registry copies, unconfirmed, and nothing animates.</p>';
    var tStations = (theme && theme.stations) || {};
    var hasArt = !!(theme && theme.ship_image);
    // r16 fix (tmp/in/FIX-r16.md item 1, conductor real-Chromium measure
    // of e2e53c8): the r15 full-width hero was sharp (the pixelation
    // complaint was fixed) but still showed the same Bridge + Project
    // Deck strip .ship-art shows directly below it, now ALSO carrying
    // baked fake task cards ("Navigation check and crew sync / Working")
    // that read as live status -- a second, worse flavour of the same
    // duplication bug r14 first flagged. The conductor's own fix is
    // structural, not another crop: delete the separate hero element
    // entirely and put the real BEBOP title/tagline directly onto
    // .ship-art's own top ~12% (base.css's .ship-art-title comment has
    // the exact math) -- one image on the page instead of two competing
    // crops of the same asset. There is nothing left named `hero`; see
    // the hull var below for where the title text now lives.
    var seed = 0;
    // r6/r7 review (tmp/in/REVIEW-r6.md, REVIEW-r7.md, real Chromium
    // renders): the full room card used to be absolutely positioned on top
    // of the art, and all 5 overlapped each other and the baked-in
    // illustration (r6). Moving them into a sibling .room-list fixed the
    // overlap but exposed a second bug: .ship-art and .room-list were BOTH
    // direct children of .ship's 2-column grid, so grid auto-placement put
    // .room-list in the 35% column meant for the side rail, and the side
    // rail wrapped below everything (r7 item 1). Both now live inside one
    // .hull wrapper, .ship's only two children are .hull (left) and
    // .side-rail (right), restoring the 65/35 split.
    //
    // r7 item 3: showing all 5 full cards stacked (1198px tall) is still
    // "lots of info on screen" even without overlap. Only one room's full
    // card is visible at a time now -- the one with the most attention by
    // default (ties broken by task count, then station order) -- and a pin
    // click switches via the URL fragment (:target), no JS/input needed.
    function roomInfoFor(st) {
      var mine = S.tasks.filter(function (r) { return r.station === st.id; });
      var executing = mine.some(function (r) { return r.display === 'executing'; });
      var urgentN = mine.filter(function (r) { return (S.display[r.display] || {}).attention; }).length;
      return { st: st, mine: mine, executing: executing, urgentN: urgentN, urgent: urgentN > 0, n: mine.length };
    }
    function roomHtml(info, isDefault) {
      var st = info.st, mine = info.mine, executing = info.executing, urgent = info.urgent;
      var ts = tStations[st.id] || {}, who = ts.who || null;
      var person = who && theme.characters && theme.characters[who];
      var pic = hasArt ? '' : avatar(theme, who, executing ? 'active' : urgent ? 'alert' : 'rest', executing && moving, 48);
      var tally = {};
      mine.forEach(function (r) { tally[r.display] = (tally[r.display] || 0) + 1; });
      var status = mine.length ? mine.length + (mine.length === 1 ? ' task: ' : ' tasks: ') +
        Object.keys(tally).map(function (k) { return tally[k] + ' ' + (S.display[k] || S.display.unknown).label.toLowerCase(); }).join(', ')
        : (st.jobs.length ? 'No tasks here.' : '');
      var place = [ts.place, person && !hasArt ? person.name : ''].filter(Boolean).join(' \u00B7 ');
      return '<section id="room-' + esc(st.id) + '" data-station="' + esc(st.id) + '" class="room' + (isDefault ? ' selected' : '') + '" tabindex="-1" aria-label="' + esc(st.label) + '">' +
        '<header class="room-head">' + pic + '<div><h3>' + esc(st.label) + '</h3>' +
        (place ? '<p class="room-place">' + esc(place) + '</p>' : '') +
        (hasArt ? '' : flavourLine(theme, who, seed++)) + '</div></header>' +
        (status ? '<p class="room-status' + (mine.length ? '' : ' dim') + '">' + esc(status) + '</p>' : '') +
        (mine.length ? '<details class="room-cards"><summary>' + mine.length + (mine.length === 1 ? ' task' : ' tasks') +
          ' \u2014 show</summary><div class="wcards">' + mine.map(function (r) { return card(S, r, nowMs); }).join('') + '</div></details>' : '') +
        (st.shows || []).map(function (k) { return extra(S, k, nowMs); }).join('') +
        '</section>';
    }
    // r18b fix (tmp/in/r18b/MEASURE-f5c8422.md item 1): .pin-label used to
    // be the pin's only always-visible text (the count was conditional on
    // info.n); base.css now hides .pin-label (sr-only -- the <a>'s own
    // aria-label already carries the full accessible text) and shows just
    // a small round count badge instead, so the count can no longer be
    // conditional -- an empty circle with nothing in it reads as broken,
    // not as "no tasks".
    function pin(info) {
      var st = info.st;
      return '<a data-station="' + esc(st.id) + '" class="room-pin' + (info.urgent ? ' urgent' : '') + (hasArt && info.executing && moving ? ' anim' : '') + '"' +
        (info.executing ? ' data-d="executing"' : '') +
        ' href="#room-' + esc(st.id) + '"' +
        ' aria-label="' + esc(st.label) + ': ' + info.n + (info.n === 1 ? ' task' : ' tasks') + (info.urgent ? ', needs attention' : '') + '">' +
        '<span class="pin-label">' + esc(st.label) + '</span>' +
        '<span class="pin-count">' + info.n + '</span></a>';
    }
    var roomInfo = S.stations.map(roomInfoFor);
    var defaultIdx = 0;
    roomInfo.forEach(function (r, i) {
      var cur = roomInfo[defaultIdx];
      if (r.urgentN > cur.urgentN || (r.urgentN === cur.urgentN && r.n > cur.n)) defaultIdx = i;
    });
    var rooms = roomInfo.map(function (r, i) { return roomHtml(r, i === defaultIdx); }).join('');
    var shipLabel = [theme.name, theme.tagline].filter(Boolean).join('. ');
    var hull = hasArt
      ? '<div class="hull"><div class="ship-art" role="img"' +
        (shipLabel ? ' aria-label="' + esc(shipLabel) + '"' : '') +
        ' style="background-image:url(' + esc(theme.ship_image) + ')">' +
        // r19 motion fix (tmp/in/r19/MOTION-SPEC.md: "ambient art layers --
        // starfield drift, console glow, optional scanline... Art is one
        // raster (ship.png); no per-character motion unless separable
        // layers exist. No Faye/art edits" -- the override on
        // MOTION-SPEC.md itself). ship.png stays untouched; these are
        // decorative CSS-only layers drawn OVER it, not edits to the art
        // asset. aria-hidden + pointer-events:none (base.css): carries no
        // information, never intercepts clicks on room pins underneath.
        '<div class="ship-ambient" aria-hidden="true"></div>' +
        '<div class="ship-scanline" aria-hidden="true"></div>' +
        roomInfo.map(pin).join('') +
        '</div><div class="room-list">' + rooms + '</div></div>'
      : '<div class="hull">' + rooms + '</div>';
    var sortedTasks = S.tasks.slice().sort(function (a, b) { return (Date.parse(b.updated_at) || 0) - (Date.parse(a.updated_at) || 0); });
    function taskFeedItem(r) { return { label: r.label, chip: stChip(S, r.display), meta: ago(r.updated_at, nowMs) }; }
    var decisionItems = S.decisions.open.map(function (f) {
      return { label: f.title, chip: '<span class="pill">open</span>', meta: 'served ' + ago(f.created_at, nowMs) };
    }).concat((S.decisions.recent_closed || []).map(function (f) {
      return { label: f.title, chip: '<span class="pill dim">' + esc(f.status) + '</span>', meta: ago(f.answered_at || f.created_at, nowMs) };
    }));
    var feeds = feedPanel('recent', 'Recent work', sortedTasks.map(taskFeedItem), 6, nowMs, S, 'No tasks in view.', 'herdr task registry') +
      feedPanel('completed', 'Completed outcomes', sortedTasks.filter(function (r) { return DONE_DISPLAY[r.display]; }).map(taskFeedItem), 6, nowMs, S, 'Nothing finished recently.', 'herdr task registry') +
      feedPanel('blockers', 'Blockers', sortedTasks.filter(function (r) { return (S.display[r.display] || {}).attention; }).map(taskFeedItem), 6, nowMs, S, 'Nothing blocked right now.', 'herdr task registry') +
      feedPanel('decisions', 'Decisions', decisionItems, 6, nowMs, S, 'No open or recent decisions.', 'formserve decision records');
    // r14b fix (tmp/in/FIX-r14b.md item 7): suggestions used to render
    // inline above the four feeds, crowding the primary route. <details>
    // again, not <button> (check.js:45's form/button/input ban).
    //
    // r19 fix (tmp/in/r19/R19-BOUNTY-MOTION.md + R19-AMEND-SPA.md):
    // maintenancePanel() (same S.unrecognized rows) moved out of this
    // "More" disclosure into its own inline bountyBoard() section below --
    // showing the same rows here too would be the page showing the same
    // data twice, not two real sources.
    var sideRail = '<div class="side-rail">' + feeds +
      '<details class="side-more"><summary>More (suggestions)</summary>' +
      bigShotPanel(S, theme) + '</details></div>';
    // r4 review (tmp/in/REVIEW-r4.md item 3.3): the reference's bottom bar
    // carries exactly 4 items (Needs Your Call / View Evidence / Overview /
    // Reduce Motion). Reduce Motion is intentionally not duplicated here --
    // it already lives in the header's Display menu, and a second control
    // bound to the same id would be invalid markup. Every other count this
    // bar used to carry (shown/hidden/capped/working/unconfirmed/loop
    // health) moves behind a closed-by-default details, not deleted.
    //
    // r5 review (tmp/in/REVIEW-r5.md item 3): the headline used to count
    // ONLY open decisions, so a blocked/stalled/failed/lost task with zero
    // open decisions rendered "Needs your call: 0 -- nothing needs you,"
    // which was false. The headline now counts open decisions PLUS tasks in
    // an attention-worthy display state, and names the attention states
    // right next to the number -- not only inside ship-more.
    var decN = S.decisions.open.length;
    var taskAttnN = S.tasks.filter(function (r) { return (S.display[r.display] || {}).attention; }).length;
    var callN = decN + taskAttnN;
    var reasonBits = [];
    if (decN) reasonBits.push(decN + (decN === 1 ? ' decision' : ' decisions'));
    if (taskAttnN) reasonBits.push(esc(attn.join(', ')));
    // r12 iteration (tmp/in/ITERATE-r12.md item 2, "obvious Needs Your
    // Call action"): the headline used to be plain inline text with an
    // inline link; call-chip/call-btn give it the same visual weight as
    // the reference's red alert icon + bordered button, still just a <p>
    // and <a> -- no new control, same markup kind check.js already allows.
    var bottom = '<p class="ship-bottom"><span class="call-chip' + (callN ? ' urgent' : '') + '">' +
      '<strong>Needs your call: ' + callN + '</strong>' +
      (callN ? ' \u2014 ' + reasonBits.join(' \u00B7 ') + '.' : ' \u2014 nothing needs you.') + '</span>' +
      ' <a class="call-btn" href="/decisions">view evidence</a>' +
      ' \u00B7 <a href="/?view=overview">Overview</a></p>' +
      '<details class="ship-more"><summary>More ship detail</summary><p class="room-extra">' +
      S.tasks.length + ' task(s) shown' +
      (S.hidden_finished ? ' (' + S.hidden_finished + ' finished more than a day ago not shown)' : '') +
      (S.capped ? ' (' + S.capped + ' more over the cap \u2014 see <a href="/herdr">herdr</a>)' : '') +
      ' \u00B7 ' + (counts.executing || 0) + ' working' +
      (S.synthetic ? ' (synthetic preview)' : S.live_connected ? ' (herdr live)' : ' (registry copy, unconfirmed)') +
      (counts.unconfirmed ? ' \u00B7 ' + counts.unconfirmed + ' running? unconfirmed' : '') +
      (S.loops.bad.length ? ' \u00B7 loops not healthy: ' + esc(S.loops.bad.join(', ')) : '') +
      '. Handoff debt, deploy drift and spend are on <a href="/?view=overview">Overview</a>.</p></details>';
    return synthBanner + alert + '<div class="ship">' + hull + sideRail + '</div>' +
      bountyBoard(S, theme, nowMs) + bottom;
  }
  function emblem(theme, panel) {
    var who = theme && theme.panels && theme.panels[panel];
    var c = who && theme.characters && theme.characters[who];
    if (!c || !c.sprite) return '';
    return avatar(theme, who, 'rest', false, 40) + '<span>' + esc(c.name) + ' \u00B7 ' + esc(c.role) + flavourLine(theme, who, 0) + '</span>';
  }

  root.HubUI = { esc: esc, spriteSVG: spriteSVG, renderShip: renderShip, emblem: emblem, fmtSpan: fmtSpan };
  if (typeof document === 'undefined' || !document.getElementById) return;

  // ---------- DOM wiring ----------
  var html = document.documentElement;
  var THEMES = JSON.parse(document.getElementById('hub-themes').textContent);
  var shipEl = document.getElementById('ship-data');
  var SHIP = shipEl ? JSON.parse(shipEl.textContent) : null;
  var mql = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function load() { try { return JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { return {}; } }
  function save(p) { try { localStorage.setItem(KEY, JSON.stringify(p)); } catch (e) { /* private mode: prefs last this page only */ } }
  var prefs = load();
  // ?view= is a link-level choice; keep it, because the meta refresh drops the query.
  try {
    var qv = new URLSearchParams(location.search).get('view');
    if (qv === 'ship' || qv === 'overview') { prefs.view = qv; save(prefs); }
  } catch (e) { /* old browser: the stored pref still applies */ }
  function themeId() { var t = html.getAttribute('data-theme'); return THEMES[t] ? t : Object.keys(THEMES)[0]; }
  // r12 addendum (tmp/in/ITERATE-r12-ADDENDUM.md item 6): "open-panel ...
  // state stable across the hub auto-refresh" -- the page's <meta
  // refresh> is a full navigation, and apply() itself replaces
  // #ship-body's innerHTML on every pref change too, so a plain <details
  // open> attribute wouldn't survive either. Same localStorage pattern as
  // `prefs` above, scoped to just which feed ids are open.
  var FEEDS_KEY = 'hub.feeds';
  function loadFeeds() { try { return JSON.parse(localStorage.getItem(FEEDS_KEY) || '{}') || {}; } catch (e) { return {}; } }
  function saveFeeds(s) { try { localStorage.setItem(FEEDS_KEY, JSON.stringify(s)); } catch (e) { /* private mode: state lasts this page only */ } }
  function wireFeedPanels() {
    var state = loadFeeds();
    Array.prototype.forEach.call(document.querySelectorAll('.feed-panel'), function (d) {
      var id = d.id, summary = d.querySelector('summary');
      if (state[id]) d.open = true;
      if (summary) summary.setAttribute('aria-expanded', d.open ? 'true' : 'false');
      d.addEventListener('toggle', function () {
        if (summary) summary.setAttribute('aria-expanded', d.open ? 'true' : 'false');
        var s = loadFeeds(); s[id] = d.open; saveFeeds(s);
      });
    });
  }
  // r19 motion fix (MOTION-SPEC.md "Pause offscreen/hidden-tab via
  // observers"): .ship-art is a fresh DOM node every apply() (host's
  // innerHTML is replaced wholesale), so this re-attaches after each
  // render rather than once at load -- the same reason wireFeedPanels()
  // above is called per-apply(), not just once.
  var motionObserver = null;
  function wireMotionPause() {
    var art = document.querySelector('.ship-art');
    if (motionObserver) { motionObserver.disconnect(); motionObserver = null; }
    if (!art || !window.IntersectionObserver) return;
    motionObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { art.classList.toggle('offscreen', !e.isIntersecting); });
    }, { threshold: 0 });
    motionObserver.observe(art);
  }
  function apply() {
    if (THEMES[prefs.theme]) html.setAttribute('data-theme', prefs.theme);
    if (prefs.reduce) html.setAttribute('data-reduce', '1'); else html.removeAttribute('data-reduce');
    if (prefs.flavour) html.setAttribute('data-flavour', '1'); else html.removeAttribute('data-flavour');
    var theme = THEMES[themeId()];
    var slot = document.querySelector('.crew-slot');
    if (slot) slot.innerHTML = emblem(theme, slot.getAttribute('data-panel'));
    var host = document.getElementById('ship-body');
    if (host && SHIP) { host.innerHTML = renderShip(SHIP, theme, { reduce: !!prefs.reduce || !!(mql && mql.matches) }); wireFeedPanels(); wireMotionPause(); }
  }
  var sel = document.getElementById('pref-theme');
  if (sel) {
    sel.value = themeId();
    sel.addEventListener('change', function () { prefs.theme = sel.value; save(prefs); apply(); });
  }
  [['pref-reduce', 'reduce'], ['pref-flavour', 'flavour']].forEach(function (pair) {
    var el = document.getElementById(pair[0]);
    if (!el) return;
    el.checked = !!prefs[pair[1]];
    el.addEventListener('change', function () { prefs[pair[1]] = el.checked; save(prefs); apply(); });
  });
  Array.prototype.forEach.call(document.querySelectorAll('input[name="hub-view"]'), function (el) {
    el.checked = el.value === html.getAttribute('data-view');
    el.addEventListener('change', function () {
      if (!el.checked) return;
      prefs.view = el.value; save(prefs);
      html.setAttribute('data-view', el.value);
    });
  });
  // An anchor into the Overview (e.g. #deploy-drift) must be reachable from Ship.
  function revealAnchor() {
    var id = location.hash.slice(1), t = id && document.getElementById(id);
    var ov = document.getElementById('overview-view');
    if (t && ov && ov.contains(t)) { html.setAttribute('data-view', 'overview'); t.scrollIntoView(); }
  }
  window.addEventListener('hashchange', revealAnchor);
  // r19 motion fix (MOTION-SPEC.md "Pause offscreen/hidden-tab via
  // observers"): document-level, so attached once -- unlike
  // wireMotionPause() above, document itself is never replaced.
  if (document.addEventListener) {
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) html.setAttribute('data-hidden', '1'); else html.removeAttribute('data-hidden');
    });
  }
  if (mql && mql.addEventListener) mql.addEventListener('change', apply);
  apply();
  revealAnchor();
  // r12 addendum (tmp/in/ITERATE-r12-ADDENDUM.md item 6): "... and scroll
  // state stable across the hub auto-refresh" -- the page does a <meta
  // http-equiv=refresh> full navigation every 15s; sessionStorage (not
  // localStorage: a scroll offset from a stale earlier tab/visit should
  // not resurrect itself) survives that same-tab reload. Skipped when a
  // URL hash is present -- revealAnchor()'s scrollIntoView already has a
  // more specific target and should win.
  if (!location.hash) {
    try {
      var savedY = sessionStorage.getItem('hub.scrollY');
      if (savedY != null) window.scrollTo(0, parseInt(savedY, 10) || 0);
    } catch (e) { /* private mode: scroll position resets this reload only */ }
  }
  window.addEventListener('beforeunload', function () {
    try { sessionStorage.setItem('hub.scrollY', String(window.scrollY)); } catch (e) { /* private mode */ }
  });
})(this);
