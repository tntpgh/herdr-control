/* herdr-control-board — static prototype.
 * Synthetic fixtures only. No network, no storage, no approve/deny/dispatch/publish
 * path: the page renders state and nothing else. Pure logic is exported as
 * `Board` so check.js can exercise it without a DOM. */
(function (root) {
  'use strict';

  // inventory D "critical rule": a row whose last update is older than this is
  // never animated and never called executing, whatever the engine says.
  var STALE_AFTER_MS = 5 * 60 * 1000;

  // lib/agent-profiles.sh:135 KNOWN_JOB_CLASSES. 'unrecognized' is NOT a class.
  var JOB_CLASSES = ['plan', 'architect', 'design', 'deep-review', 'implement', 'debug',
    'code', 'docs', 'review', 'explore', 'quick', 'mechanical', 'research'];

  // Canonical display states: identical in every theme; a theme cannot redefine them.
  var STATES = {
    executing:           { label: 'Executing',                     icon: '\u25B6', pose: 'active', animate: true },
    starting:            { label: 'Starting',                      icon: '\u25CB', pose: 'rest' },
    queued:              { label: 'Queued',                        icon: '\u2026', pose: 'rest' },
    hold:                { label: 'On hold (on purpose)',          icon: '\u2016', pose: 'rest' },
    blocked:             { label: 'Waiting on a decision',         icon: '?',      pose: 'wait' },
    denied:              { label: 'Denied',                        icon: '\u2297', pose: 'alert' },
    timed_out:           { label: 'Timed out \u2014 NOT approved', icon: '\u25F7', pose: 'static' },
    stale:               { label: 'Stale \u2014 no recent update', icon: '\u25CC', pose: 'static' },
    stalled:             { label: 'Stalled \u2014 owes an action', icon: '\u25B3', pose: 'alert' },
    in_review:           { label: 'In review',                     icon: '\u25C9', pose: 'read' },
    deployed_unverified: { label: 'Deployed \u2014 NOT verified',  icon: '\u25D0', pose: 'wait' },
    done_with_proof:     { label: 'Done \u2014 proof on file',     icon: '\u2714', pose: 'rest' },
    closed:              { label: 'Closed \u2014 no ship claimed', icon: '\u25A0', pose: 'rest' },
    failed:              { label: 'Failed',                        icon: '\u2716', pose: 'alert' },
    cancelled:           { label: 'Cancelled',                     icon: '\u2298', pose: 'rest' },
    lost:                { label: 'Lost \u2014 worker gone',       icon: '\u2205', pose: 'static' },
    unknown:             { label: 'Unrecognized engine state',     icon: '\u00BF', pose: 'static' }
  };
  var REQUIRED_STATES = ['executing', 'queued', 'hold', 'denied', 'timed_out', 'stale',
    'in_review', 'deployed_unverified', 'done_with_proof'];
  var ATTENTION_STATES = ['blocked', 'denied', 'timed_out', 'stalled', 'in_review',
    'deployed_unverified', 'failed', 'stale', 'unknown'];

  var GBP_STATUS = {
    draft:                { label: 'Draft', words: 'Draft \u2014 not reviewed.' },
    needs_review:         { label: 'Needs review', words: 'Needs review \u2014 not approved.' },
    approved_for_publish: { label: 'Approved for publish (not wired)', words: 'Approved for publish \u2014 publishing is NOT wired; nothing will post from here.' },
    published_unverified: { label: 'Published \u2014 NOT verified', words: 'Marked published \u2014 nobody has confirmed it is live.' }
  };
  var GBP_LANES = { listing_story: 'Listing story', team_update: 'Team update', guide: 'Guide' };
  var RIGHTS = {
    owned:         'Rights: owned.',
    needs_release: 'Rights: NOT cleared \u2014 needs a signed photo release.',
    unconfirmed:   'Rights: NOT confirmed \u2014 licence unknown.'
  };
  var BOUNTY_STATUS = {
    open: 'Open \u2014 nobody on it yet.',
    in_progress: 'In progress.',
    awaiting_evidence: 'Awaiting evidence check.',
    verified: 'Verified complete.'
  };

  // ---------- pure helpers ----------
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function col(c, fallback) { return /^#[0-9a-fA-F]{3,8}$/.test(c || '') ? c : fallback; }
  function num(n, fallback) { return typeof n === 'number' && isFinite(n) ? n : fallback; }
  function ageMs(iso, nowMs) { var t = Date.parse(iso); return isNaN(t) ? null : nowMs - t; }
  function fmtAge(ms) {
    if (ms == null) return 'an unknown time';
    var m = Math.floor(ms / 60000);
    if (m < 1) return 'under a minute';
    if (m < 60) return m + ' min';
    return Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
  }
  function fmtTime(iso) { return iso ? iso.replace('T', ' ').replace(/:\d\dZ$/, ' UTC') : '\u2014'; }
  function usd(n) { return '$' + Number(n).toFixed(2); }

  function deriveDisplay(card, nowMs) {
    var e = (card && card.engine) || {};
    var age = ageMs(e.updated_at, nowMs);
    var fresh = age !== null && age <= STALE_AFTER_MS;
    if (e.kind === 'task') {
      switch (e.state) {
        case 'running': return fresh ? 'executing' : 'stale';
        case 'starting': return 'starting';
        case 'blocked': return 'blocked';
        case 'stalled': return 'stalled';
        case 'ready_review': return 'in_review';
        case 'completed':
          if (e.closure_reason === 'shipped') {
            if (!e.closure_proof) return 'unknown'; // the registry refuses this; never call it done
            var d = card.deploy;
            return d && d.required && !d.verified ? 'deployed_unverified' : 'done_with_proof';
          }
          return 'closed';
        case 'failed': case 'cancelled': case 'lost': return e.state;
      }
      return 'unknown';
    }
    if (e.kind === 'owner_request') {
      switch (e.state) {
        case 'queued': return 'queued';
        case 'held': return 'hold';
        case 'blocked': return 'blocked';
        case 'delivering': return fresh ? 'executing' : 'stale';
        case 'timeout': return 'timed_out';
        case 'stale': return 'stale';
        case 'cancelled': return 'cancelled';
      }
      return 'unknown';
    }
    if (e.kind === 'dispatch_auth' && e.state === 'denied') return 'denied';
    return 'unknown';
  }

  function shouldAnimate(state, prefs) {
    return !!(STATES[state] && STATES[state].animate) && !prefs.reduce && !prefs.plain;
  }

  function engineLiteral(card, nowMs) {
    var e = card.engine || {};
    var kind = { task: 'task', owner_request: 'owner request', dispatch_auth: 'dispatch authorization' }[e.kind] || String(e.kind);
    var bits = ['engine: ' + kind + ' \u00B7 ' + e.state];
    if (e.source) bits.push(e.source);
    bits.push('updated ' + fmtAge(ageMs(e.updated_at, nowMs)) + ' ago');
    if (e.closure_reason) bits.push('closure: ' + e.closure_reason);
    return bits.join(' \u00B7 ');
  }

  function decisionLiteral(d, nowMs) {
    if (!d) return { key: 'none', approved: false, text: 'No decision on file.' };
    var exp = Date.parse(d.expires_at);
    switch (d.status) {
      case 'open':
        if (!isNaN(exp) && nowMs > exp) return { key: 'timed_out', approved: false, text: 'Timed out \u2014 still unanswered. NOT approved, NOT declined.' };
        return { key: 'pending', approved: false, text: 'Pending \u2014 no answer yet. NOT approved.' };
      case 'answered':
        if (d.answer === 'approve') return { key: 'approved', approved: true, text: 'Answer recorded: APPROVE (via ' + d.answered_via + ', ' + fmtTime(d.answered_at) + ').' };
        if (d.answer === 'deny') return { key: 'denied', approved: false, text: 'Answer recorded: DENY (via ' + d.answered_via + ', ' + fmtTime(d.answered_at) + ').' };
        return { key: 'unknown', approved: false, text: 'Answer recorded but not approve/deny ("' + d.answer + '") \u2014 treated as NOT approved.' };
      case 'expired': return { key: 'timed_out', approved: false, text: 'Timed out \u2014 still unanswered. NOT approved, NOT declined.' };
      case 'cancelled': return { key: 'cancelled', approved: false, text: 'Cancelled \u2014 no approval was given.' };
      case 'gone': return { key: 'gone', approved: false, text: 'Form server gone without an answer \u2014 still unanswered. NOT approved.' };
    }
    return { key: 'unknown', approved: false, text: 'Unrecognized status "' + d.status + '" \u2014 treated as NOT approved.' };
  }

  function closureWords(reason) {
    if (!reason) return 'no reason recorded';
    if (reason.indexOf('handed_off_to:') === 0) return 'handed off to ' + reason.slice(14);
    if (reason.indexOf('blocked_on:') === 0) return 'blocked on ' + reason.slice(11);
    return reason;
  }

  function stateWords(card, state, decision, nowMs) {
    var e = card.engine || {};
    var age = fmtAge(ageMs(e.updated_at, nowMs));
    switch (state) {
      case 'executing': return 'Working now. Last update ' + age + ' ago.';
      case 'starting': return 'Launching. No work reported yet.';
      case 'queued': return 'Waiting in the queue' + (card.queue_position ? ' (position ' + card.queue_position + ')' : '') + '. Not started.';
      case 'hold': return 'Held on purpose by ' + ((card.hold && card.hold.by) || 'someone unrecorded') + '. ' + ((card.hold && card.hold.reason) || '') + ' Will not run until released.';
      case 'blocked': return 'Waiting on a human decision' + (decision ? ' (' + decision.id + ')' : '') + '. Nothing runs until it is answered.';
      case 'denied': return 'Denied' + (decision && decision.answer_note ? ': ' + decision.answer_note : '.') + ' The refused action did not run.';
      case 'timed_out': return 'No answer before the deadline' + (decision ? ' (' + fmtTime(decision.expires_at) + ')' : '') + '. Still unanswered \u2014 treated as NOT approved.';
      case 'stale': return e.kind === 'owner_request' ? 'The request went stale before delivery.' : 'Engine last said "' + e.state + '", but nothing for ' + age + '. Not known to be working.';
      case 'stalled': return card.owes || 'Idle while owing the conductor an action.';
      case 'in_review': return 'Finished; waiting on review' + (card.review_of ? ' of ' + card.review_of : '') + '.';
      case 'deployed_unverified': return ((card.deploy && card.deploy.note) || 'Deployed.') + ' Not done until a live check passes.';
      case 'done_with_proof': return 'Shipped. Proof: ' + e.closure_proof + '.' + (card.deploy && card.deploy.note ? ' ' + card.deploy.note : '');
      case 'closed': return 'Closed: ' + closureWords(e.closure_reason) + '. No ship or proof claimed.';
      case 'failed': return 'Failed: ' + (card.failure || 'no failure detail recorded.');
      case 'cancelled': return 'Cancelled (' + closureWords(e.closure_reason) + '). Nothing further will run.';
      case 'lost': return 'Lost: the worker disappeared without a result.';
    }
    if (e.kind === 'task' && e.state === 'completed' && e.closure_reason === 'shipped') {
      return 'Claims "shipped" with no proof. The registry refuses that, so the board will not call it done.';
    }
    return 'Engine reported "' + e.kind + ':' + e.state + '". The board will not guess what that means.';
  }

  function jobInfo(theme, jobClass) {
    var known = JOB_CLASSES.indexOf(jobClass) !== -1;
    var m = known ? theme.job_classes[jobClass] : theme.unrecognized;
    return { known: known, jobClass: jobClass, character: (m && m.character) || null, badge: (m && m.badge) || jobClass };
  }

  function findPerson(theme, id) {
    return (theme.characters && theme.characters[id]) || (theme.guests && theme.guests[id]) || null;
  }

  // Layout B: which ship station shows a job class. Unlisted classes go to the
  // station that declares it shows 'unrecognized'; never silently dropped.
  function stationFor(theme, jobClass) {
    var st = theme.stations || [], i;
    for (i = 0; i < st.length; i++) if ((st[i].job_classes || []).indexOf(jobClass) !== -1) return st[i].id;
    for (i = 0; i < st.length; i++) if ((st[i].shows || []).indexOf('unrecognized') !== -1) return st[i].id;
    return null;
  }

  // ---------- sprites: simple SVG built from theme params ----------
  function human(sp, a, r, cx, pose) {
    var hair = col(sp.hair_color, '#333'), skin = col(sp.skin, '#d8b08c'), coat = col(sp.coat, '#445'),
      shirt = col(sp.shirt, '#eee'), acc = col(sp.accent, '#b08d57'), facial = col(sp.facial, hair);
    var bw = { broad: 34, tall: 26, slim: 24, thin: 22 }[sp.build] || 28;
    var L = cx - bw / 2, R = cx + bw / 2, ex = sp.extras || [], has = function (x) { return ex.indexOf(x) !== -1; };
    var p = [];
    if (has('katana')) p.push('<line x1="6" y1="54" x2="42" y2="22" stroke="#c9ccd1" stroke-width="1.6"/><line x1="6" y1="54" x2="13" y2="48" stroke="#2a1a12" stroke-width="3"/>');
    if (sp.hair === 'long') p.push('<path d="M' + (cx - r - 2) + ' 15 Q' + cx + ' 2 ' + (cx + r + 2) + ' 15 L' + (cx + r + 4) + ' 46 L' + (cx - r - 4) + ' 46 Z" fill="' + hair + '"' + a + '/>');
    // body, shirt, arms
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
    // head
    p.push('<rect x="' + (cx - 3) + '" y="25" width="6" height="7" fill="' + skin + '"/>');
    p.push('<circle cx="' + cx + '" cy="19" r="' + r + '" fill="' + skin + '"' + a + '/>');
    p.push('<circle cx="' + (cx - 3) + '" cy="19.5" r="1.1" fill="#161616"/><circle cx="' + (cx + 3) + '" cy="19.5" r="1.1" fill="#161616"/>');
    p.push('<path d="M' + (cx - 2) + ' 24 h4" stroke="#6b3b2b" stroke-width="1"/>');
    if (has('beard')) p.push('<path d="M' + (cx - r + 1) + ' 20 Q' + (cx - r + 1) + ' 30 ' + cx + ' 30.5 Q' + (cx + r - 1) + ' 30 ' + (cx + r - 1) + ' 20 Q' + cx + ' 26.5 ' + (cx - r + 1) + ' 20 Z" fill="' + facial + '"/>');
    if (has('mustache')) p.push('<path d="M' + (cx - 6) + ' 24 Q' + cx + ' 19.5 ' + (cx + 6) + ' 24 Q' + cx + ' 22.5 ' + (cx - 6) + ' 24 Z" fill="' + facial + '"/>');
    // hair / hats (front)
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
        // crown with a centre parting plus two side curtains; the face stays visible
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

  var api = {
    STALE_AFTER_MS: STALE_AFTER_MS, JOB_CLASSES: JOB_CLASSES, STATES: STATES,
    REQUIRED_STATES: REQUIRED_STATES, ATTENTION_STATES: ATTENTION_STATES, GBP_STATUS: GBP_STATUS,
    deriveDisplay: deriveDisplay, shouldAnimate: shouldAnimate, decisionLiteral: decisionLiteral,
    stateWords: stateWords, engineLiteral: engineLiteral, jobInfo: jobInfo, spriteSVG: spriteSVG,
    findPerson: findPerson, stationFor: stationFor, esc: esc
  };
  root.Board = api;
  if (typeof document === 'undefined' || !document.getElementById) return;

  // ---------- DOM rendering ----------
  function inline(id) { return JSON.parse(document.getElementById(id).textContent); }
  var D = {
    board: inline('data-board'), decisions: inline('data-decisions'), jobs: inline('data-job-classes'),
    gbp: inline('data-gbp-drafts'), bounties: inline('data-bounties'),
    themes: { bebop: inline('data-theme-bebop'), plain: inline('data-theme-plain') }
  };
  var NOW = Date.parse(D.board.generated_at);
  var mql = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  var prefs = {
    plain: !!(window.matchMedia && window.matchMedia('(prefers-contrast: more)').matches),
    reduce: !!(mql && mql.matches),
    flavour: false,
    layout: 'ship' // B (ship cutaway) is the default; 'overview' is A
  };
  var decisionsById = {};
  D.decisions.decisions.forEach(function (d) { decisionsById[d.id] = d; });
  var tierOf = {};
  D.jobs.classes.forEach(function (c) { tierOf[c.id] = c.tier; });

  function theme() { return prefs.plain ? D.themes.plain : D.themes.bebop; }

  function avatar(personId, pose, state, size) {
    var t = theme(), p = personId && findPerson(t, personId);
    if (!p || !p.sprite) return '';
    return spriteSVG(p.sprite, t.sprite_style, {
      pose: pose, size: size, animate: shouldAnimate(state, prefs),
      label: p.name + ' \u2014 ' + p.role + (p.look ? ' (' + p.look + ')' : '')
    });
  }
  function personName(personId) {
    var p = personId && findPerson(theme(), personId);
    return p ? p.name : '';
  }
  function flavour(personId, seed) {
    var p = personId && findPerson(theme(), personId);
    if (!p || !p.flavour || !p.flavour.length) return '';
    return '<p class="flavour">\u201C' + esc(p.flavour[seed % p.flavour.length]) + '\u201D <span class="sr-only">(flavour text)</span></p>';
  }
  function jobBadge(jobClass) {
    var j = jobInfo(theme(), jobClass);
    if (!j.known) {
      return '<span class="badge badge-unrecognized">' + esc(theme().unrecognized.badge) + ' \u201C' + esc(jobClass) +
        '\u201D \u2014 not one of the 13 classes; secrets withheld (fail-closed)</span>';
    }
    var tier = tierOf[jobClass];
    return '<span class="badge tier-' + esc(tier) + '">' + esc(j.badge) + ' <span class="tier">' + esc(jobClass) + ' \u00B7 ' + esc(tier) + '</span></span>';
  }
  function functionBadge(key) {
    var f = theme().function_badges[key];
    if (!f) return '';
    var who = personName(f.character);
    return '<span class="badge badge-fn">' + esc(f.badge) + (who ? ' <span class="tier">' + esc(who) + '</span>' : '') + '</span>';
  }
  function stateChip(state) {
    var s = STATES[state];
    return '<span class="chip" data-state="' + esc(state) + '"><span class="chip-icon" aria-hidden="true">' + esc(s.icon) + '</span> ' + esc(s.label) + '</span>';
  }
  function guestFor(tag) {
    var g = theme().guests || {};
    for (var id in g) if (g[id].appears_for && g[id].appears_for.indexOf(tag) !== -1) return id;
    return null;
  }
  function guestBlock(tag, size) {
    var id = guestFor(tag);
    if (!id) return '';
    var g = theme().guests[id];
    var pic = avatar(id, 'rest', 'none', size || 40);
    return '<div class="guest">' + pic + '<span class="guest-text">' + esc(pic ? g.name : g.plain_text) + '</span></div>';
  }

  function allCards(project) {
    var out = [];
    project.lanes.forEach(function (l) { l.cards.forEach(function (c) { out.push(c); }); });
    return out;
  }

  function renderOverview() {
    var t = theme(), host = document.getElementById('overview-body');
    var rows = D.board.projects.map(function (p) {
      var counts = {};
      allCards(p).forEach(function (c) { var s = deriveDisplay(c, NOW); counts[s] = (counts[s] || 0) + 1; });
      var attn = ATTENTION_STATES.filter(function (s) { return counts[s]; })
        .map(function (s) { return counts[s] + ' ' + STATES[s].label.toLowerCase(); });
      var calm = (counts.executing || 0) + ' executing';
      var cost = p.lanes.reduce(function (n, l) { return n + (l.cost_today_usd || 0); }, 0);
      return '<li class="ov-row' + (attn.length ? ' ov-attn' : '') + '"><a href="#project/' + esc(p.id) + '" class="ov-name">' + esc(p.name) + '</a>' +
        '<span class="ov-summary">' + esc(p.summary) + '</span>' +
        '<span class="ov-counts">' + esc(calm) + (attn.length ? ' \u00B7 <strong>needs a look: ' + esc(attn.join(', ')) + '</strong>' : ' \u00B7 nothing needs you') + '</span>' +
        '<span class="ov-cost">Model spend today: ' + usd(cost) + '</span></li>';
    });
    host.innerHTML =
      '<div class="ov-head">' + avatar(t.panels.overview, 'rest', 'none', 56) +
      '<p>' + functionBadge('captain') + ' One line per project. Open a project for lanes and workers.</p></div>' +
      '<ul class="ov-list">' + rows.join('') + '</ul>' +
      '<p class="ov-decisions">' + decisionsLine() + '</p>';
  }

  function decisionLink(d) { return '<a href="#decision/' + esc(d.id) + '">' + esc(d.id) + '</a>'; }
  function decisionsLine() {
    var open = D.decisions.decisions.filter(function (d) { return decisionLiteral(d, NOW).key === 'pending'; });
    return 'Decisions waiting on you: <strong>' + open.length + '</strong>' +
      (open.length ? ' \u2014 ' + open.map(decisionLink).join(', ') : '') +
      '. All decisions: ' + D.decisions.decisions.map(decisionLink).join(', ') + '.';
  }

  // `where` (ship layout): compact card — no per-card avatar (the crew member
  // sits at the station), plus a link to the card's project and lane.
  function renderCard(c, idx, where) {
    var state = deriveDisplay(c, NOW), s = STATES[state], j = jobInfo(theme(), c.job_class);
    var d = c.decision_id ? decisionsById[c.decision_id] : null;
    var fns = (c.function_badges || []).map(functionBadge).join(' ');
    var who = j.character ? personName(j.character) : '';
    var label = c.label + ' \u2014 ' + s.label + (who ? ' \u2014 ' + who : '');
    return '<article class="card" data-state="' + esc(state) + '" aria-label="' + esc(label) + '">' +
      '<div class="card-head">' + (where ? '' : avatar(j.character, s.pose, state, 44)) +
      '<div><h4 class="card-title">' + esc(c.label) + '</h4>' +
      '<p class="who">' + (who ? '<span class="who-name">' + esc(who) + '</span> ' : '') + jobBadge(c.job_class) + ' ' + fns + '</p></div></div>' +
      '<p class="card-state">' + stateChip(state) + '</p>' +
      '<p class="words">' + esc(stateWords(c, state, d, NOW)) + '</p>' +
      (where ? '<p class="proj"><a href="#project/' + esc(where.project.id) + '">' + esc(where.project.name) + ' \u00B7 ' + esc(where.lane.name) + '</a></p>' : '') +
      '<p class="engine">' + esc(engineLiteral(c, NOW)) + '</p>' +
      (c.cost_today_usd != null ? '<p class="cost">Model spend today: ' + usd(c.cost_today_usd) + '</p>' : '') +
      (d ? '<p class="card-decision"><a href="#decision/' + esc(d.id) + '">Decision ' + esc(d.id) + ': ' + esc(decisionLiteral(d, NOW).text) + '</a></p>' : '') +
      flavour(j.character, idx) +
      '</article>';
  }

  function shipExtra(kind, entries) {
    var t = theme();
    switch (kind) {
      case 'decisions':
        return '<p class="room-extra">Comms: ' + decisionsLine() + '</p>';
      case 'leads':
        return '<ul class="room-extra leads">' + D.board.projects.map(function (p) {
          var n = entries.filter(function (e) { return e.project === p && ATTENTION_STATES.indexOf(e.state) !== -1; }).length;
          return '<li>' + functionBadge('project_lead') + ' <a href="#project/' + esc(p.id) + '">' + esc(p.name) + '</a> \u2014 ' + esc(p.lead) +
            ' \u00B7 ' + (n ? '<strong>' + n + ' need a look</strong>' : 'nothing needs you') + '</li>';
        }).join('') + '</ul>';
      case 'gbp':
        var by = {};
        D.gbp.drafts.forEach(function (g) { by[g.review_status] = (by[g.review_status] || 0) + 1; });
        return '<p class="room-extra">Business Profile drafts: ' + D.gbp.drafts.length + ' \u2014 ' +
          Object.keys(by).map(function (k) { return by[k] + ' ' + ((GBP_STATUS[k] && GBP_STATUS[k].label) || k).toLowerCase(); }).join(', ') +
          '. <a href="#gbp-h">Read the drafts</a>. No publish control exists.</p>';
      case 'unrecognized':
        return '<p class="room-extra">Workers whose job class is not one of the 13 land here. \u201C' + esc(t.unrecognized.badge) + '\u201D is a fallback, not a class: secrets withheld.</p>';
      case 'maintenance':
        var lanes = [];
        D.board.projects.forEach(function (p) { p.lanes.forEach(function (l) { if (l.kind === 'maintenance') lanes.push({ p: p, l: l }); }); });
        return '<p class="room-extra">Maintenance and archive lanes: ' + (lanes.length ? lanes.map(function (x) {
          return '<a href="#project/' + esc(x.p.id) + '">' + esc(x.l.name) + '</a> (' + esc(x.p.name) + ', ' + x.l.cards.length + ' workers)';
        }).join('; ') : 'none') + '.</p>';
      case 'bounties':
        return bountiesHTML(true);
    }
    return '';
  }

  function renderShip() {
    var t = theme(), host = document.getElementById('ship-body'), entries = [], idx = 0;
    D.board.projects.forEach(function (p) {
      p.lanes.forEach(function (l) {
        l.cards.forEach(function (c) { entries.push({ card: c, project: p, lane: l, state: deriveDisplay(c, NOW) }); });
      });
    });
    var counts = {}, cost = 0;
    entries.forEach(function (e) { counts[e.state] = (counts[e.state] || 0) + 1; });
    D.board.projects.forEach(function (p) { p.lanes.forEach(function (l) { cost += l.cost_today_usd || 0; }); });
    var attn = ATTENTION_STATES.filter(function (s) { return counts[s]; })
      .map(function (s) { return counts[s] + ' ' + STATES[s].label.toLowerCase(); });
    function room(st) {
      var mine = entries.filter(function (e) { return stationFor(t, e.card.job_class) === st.id; });
      var executing = mine.some(function (e) { return e.state === 'executing'; });
      var urgent = mine.some(function (e) { return ATTENTION_STATES.indexOf(e.state) !== -1; });
      var who = st.character || st.guest || null, person = who && findPerson(t, who);
      // The figure only moves when the station has an executing worker; stale never animates.
      var pic = avatar(who, executing ? 'active' : urgent ? 'alert' : 'rest', executing ? 'executing' : 'none', 52);
      var tally = {};
      mine.forEach(function (e) { tally[e.state] = (tally[e.state] || 0) + 1; });
      var status = mine.length ? mine.length + (mine.length === 1 ? ' worker: ' : ' workers: ') +
        Object.keys(tally).map(function (s) { return tally[s] + ' ' + STATES[s].label.toLowerCase(); }).join(', ') : '';
      var area = /^[a-z]+$/.test(st.area || '') ? st.area : 'misc';
      return '<section class="room' + (st.outside ? ' outside' : '') + '" data-area="' + area + '" aria-labelledby="room-' + esc(st.id) + '">' +
        '<header class="room-head">' + pic + '<div><h3 id="room-' + esc(st.id) + '">' + esc(st.name) + '</h3>' +
        (person && person.sprite ? '<p class="who"><span class="who-name">' + esc(person.name) + '</span> ' + esc(person.role) + '</p>' : '') +
        ((st.function_badges || []).length ? '<p class="who">' + st.function_badges.map(functionBadge).join(' ') + '</p>' : '') +
        (st.note ? '<p class="muted room-note">' + esc(st.note) + '</p>' : '') + '</div></header>' +
        (status ? '<p class="room-status">' + esc(status) + '</p>' : (st.job_classes || []).length ? '<p class="room-status muted">No workers at this station.</p>' : '') +
        mine.map(function (e) { return renderCard(e.card, idx++, e); }).join('') +
        (st.shows || []).map(function (k) { return shipExtra(k, entries); }).join('') +
        '</section>';
    }
    var stations = t.stations || [];
    host.innerHTML =
      '<p class="ship-log">' + functionBadge('captain') + ' Ship\u2019s log: ' + D.board.projects.length + ' projects, ' + (counts.executing || 0) + ' executing' +
      (attn.length ? ' \u00B7 <strong>needs a look: ' + esc(attn.join(', ')) + '</strong>' : ' \u00B7 nothing needs you') +
      ' \u00B7 model spend today ' + usd(cost) + '.</p>' +
      '<div class="ship"><div class="hull">' + stations.filter(function (s) { return !s.outside; }).map(room).join('') + '</div>' +
      '<div class="outside-col">' + stations.filter(function (s) { return s.outside; }).map(room).join('') + '</div></div>';
  }

  function renderDrawer(projectId) {
    var p = D.board.projects.filter(function (x) { return x.id === projectId; })[0];
    var host = document.getElementById('drawer');
    if (!p) { host.hidden = true; return false; }
    var idx = 0;
    host.innerHTML =
      '<p class="back"><a href="#">\u2190 Back to overview</a></p>' +
      '<h2 id="drawer-h" tabindex="-1">' + esc(p.name) + '</h2>' +
      '<div class="lead">' + avatar(theme().function_badges.project_lead.character, 'rest', 'none', 48) +
      '<p>' + functionBadge('project_lead') + ' ' + esc(p.lead) + '<br><span class="muted">' + esc(p.summary) + '</span></p></div>' +
      '<div class="lanes">' + p.lanes.map(function (l) {
        return '<section class="lane" aria-labelledby="lane-' + esc(l.id) + '">' +
          '<header class="lane-head"><h3 id="lane-' + esc(l.id) + '">' + esc(l.name) + '</h3>' +
          (l.kind === 'maintenance' ? guestBlock('lane:maintenance', 36) : '') +
          (l.function_badges || []).map(functionBadge).join(' ') +
          '<p class="cost">Lane model spend today: ' + usd(l.cost_today_usd || 0) + '</p></header>' +
          l.cards.map(function (c) { return renderCard(c, idx++); }).join('') +
          '</section>';
      }).join('') + '</div>';
    host.hidden = false;
    return true;
  }

  function cardById(id) {
    var hit = null;
    D.board.projects.forEach(function (p) {
      allCards(p).forEach(function (c) { if (c.id === id) hit = { card: c, project: p }; });
    });
    return hit;
  }

  function renderDecision(id) {
    var d = decisionsById[id], host = document.getElementById('decision');
    if (!d) { host.hidden = true; return false; }
    var lit = decisionLiteral(d, NOW), ref = cardById(d.card_id);
    host.innerHTML =
      '<p class="back"><a href="' + (ref ? '#project/' + esc(ref.project.id) : '#') + '">\u2190 Back' + (ref ? ' to ' + esc(ref.project.name) : '') + '</a></p>' +
      '<h2 id="decision-h" tabindex="-1">Decision ' + esc(d.id) + '</h2>' +
      (ref ? '<p>For worker <strong>' + esc(ref.card.label) + '</strong> in ' + esc(ref.project.name) + '.</p>' : '') +
      '<p class="literal" data-decision="' + esc(lit.key) + '"><strong>' + esc(lit.text) + '</strong></p>' +
      '<h3>Exact request text</h3><pre class="request">' + esc(d.request_text) + '</pre>' +
      '<dl class="facts"><dt>Form status (engine)</dt><dd>' + esc(d.status) + '</dd>' +
      '<dt>Asked</dt><dd>' + esc(fmtTime(d.requested_at)) + '</dd>' +
      '<dt>Deadline</dt><dd>' + esc(fmtTime(d.expires_at)) + '</dd>' +
      '<dt>Answer</dt><dd>' + esc(d.answer || 'none') + '</dd>' +
      '<dt>Answered</dt><dd>' + esc(d.answered_at ? fmtTime(d.answered_at) + ' via ' + d.answered_via : 'not answered') + '</dd>' +
      (d.answer_note ? '<dt>Note</dt><dd>' + esc(d.answer_note) + '</dd>' : '') + '</dl>' +
      '<p class="notice">This board cannot answer decisions. The [Approve]/[Deny] text above is quoted from the request, not a control.</p>';
    host.hidden = false;
    return true;
  }

  function renderGbp() {
    var t = theme(), host = document.getElementById('gbp-body');
    host.innerHTML =
      '<div class="panel-head">' + avatar(t.panels.gbp_drafts, 'read', 'none', 48) +
      '<p>' + (t.panels.gbp_drafts ? esc(personName(t.panels.gbp_drafts)) + ' \u00B7 ' : '') + 'Opportunities. Drafts only \u2014 there is no publish control, and \u201Capproved for publish\u201D is not wired to anything.</p></div>' +
      '<ul class="gbp-legend">' + D.gbp.review_statuses.map(function (k) {
        return '<li><span class="gchip" data-gbp="' + esc(k) + '">' + esc(GBP_STATUS[k].label) + '</span> ' + esc(GBP_STATUS[k].words) + '</li>';
      }).join('') + '</ul>' +
      '<div class="gbp-grid">' + D.gbp.drafts.map(function (g) {
        var st = GBP_STATUS[g.review_status] || { label: 'Unrecognized status', words: 'Unrecognized status "' + g.review_status + '" \u2014 treated as not approved.' };
        var fr = g.source.freshness;
        var late = Date.parse(g.proposed_publish_date + 'T23:59:59Z') < NOW && g.review_status !== 'published_unverified';
        return '<article class="gbp" data-gbp="' + esc(g.review_status) + '" aria-label="' + esc(g.title + ' \u2014 ' + st.label) + '">' +
          '<p class="gbp-lane">' + esc(GBP_LANES[g.lane] || g.lane) + '</p>' +
          '<h3>' + esc(g.title) + '</h3>' +
          '<p><span class="gchip" data-gbp="' + esc(g.review_status) + '">' + esc(st.label) + '</span></p>' +
          '<p class="words">' + esc(st.words) + (g.published_note ? ' ' + esc(g.published_note) : '') + '</p>' +
          '<blockquote class="gbp-copy">' + esc(g.copy) + '</blockquote>' +
          '<dl class="facts">' +
          '<dt>Image</dt><dd>' + esc(g.image.suggestion) + '. <strong>' + esc(RIGHTS[g.image.rights_status] || 'Rights: unrecognized status \u201C' + g.image.rights_status + '\u201D \u2014 treat as NOT cleared.') + '</strong> ' + esc(g.image.rights_note) + '</dd>' +
          '<dt>Source</dt><dd>' + esc(g.source.name) + '</dd>' +
          '<dt>Freshness check</dt><dd data-fresh="' + esc(fr.result) + '"><strong>' + esc(fr.result.toUpperCase()) + '</strong> on ' + esc(fr.checked_on) + ' \u2014 ' + esc(fr.detail) + '</dd>' +
          '<dt>Proposed publish date</dt><dd>' + esc(g.proposed_publish_date) + (late ? ' <strong>(already passed)</strong>' : '') + '</dd>' +
          '</dl></article>';
      }).join('') + '</div>';
  }

  // inShip: rendered inside the ship's bounty station (whose header already shows the presenter).
  function bountiesHTML(inShip) {
    var t = theme(), presenter = guestFor('panel:bounties'), h = inShip ? 'h4' : 'h3';
    var g = presenter && t.guests[presenter];
    var intro = ' Bounties describe work and the evidence that closes it. No money, rewards or points; approving anything earns nothing.';
    return (inShip ? '<p class="room-extra">' + esc(intro.slice(1)) + '</p>' :
      '<div class="panel-head">' + avatar(presenter, 'wait', 'none', 48) +
      '<p>' + esc((g ? (g.sprite ? g.name + ' presents new bounty cards.' : g.plain_text + '.') : 'Bounty board.') + intro) + '</p></div>') +
      '<div class="bounty-grid">' + D.bounties.bounties.map(function (b) {
        var v = b.verified_completion || {};
        return '<article class="bounty" data-bounty="' + esc(b.status) + '" aria-label="' + esc('Bounty ' + b.id + ': ' + b.objective) + '">' +
          (b.kind === 'archive' ? guestBlock('bounty:archive', 32) : '') +
          '<' + h + '>' + esc(b.objective) + '</' + h + '><dl class="facts">' +
          '<dt>True project owner</dt><dd>' + esc(b.owner) + '</dd>' +
          '<dt>Function</dt><dd>' + jobBadge(b['function']) + '</dd>' +
          '<dt>Status</dt><dd>' + esc(BOUNTY_STATUS[b.status] || 'Unrecognized status \u201C' + b.status + '\u201D.') + '</dd>' +
          '<dt>Evidence needed</dt><dd>' + esc(b.evidence_needed) + '</dd>' +
          '<dt>Verified completion</dt><dd data-verified="' + (v.verified ? 'yes' : 'no') + '"><strong>' +
          (v.verified ? 'Verified by ' + esc(v.by) + ' \u2014 proof: ' + esc(v.proof) : 'NOT verified') + '</strong>' + (v.note ? ' \u2014 ' + esc(v.note) : '') + '</dd>' +
          '</dl></article>';
      }).join('') + '</div>';
  }
  function renderBounties() {
    var standalone = document.getElementById('bounties');
    standalone.hidden = prefs.layout === 'ship'; // B shows the board inside the ship
    document.getElementById('bounties-body').innerHTML = standalone.hidden ? '' : bountiesHTML(false);
  }

  function renderLegend() {
    var t = theme(), host = document.getElementById('legend-body');
    var jobRows = D.jobs.classes.map(function (c) {
      var j = jobInfo(t, c.id);
      return '<tr><th scope="row">' + esc(c.id) + '</th><td>' + esc(c.tier) + '</td><td>' + esc(personName(j.character) || '\u2014') + '</td><td>' + esc(j.badge) + '</td></tr>';
    }).join('') + '<tr class="not-a-class"><th scope="row">(anything else)</th><td>default row</td><td>\u2014</td><td>' + esc(t.unrecognized.badge) + ' \u2014 NOT a class; secrets withheld</td></tr>';
    var fnRows = Object.keys(t.function_badges).map(function (k) {
      var f = t.function_badges[k];
      return '<tr><th scope="row">' + esc(k) + '</th><td>' + esc(personName(f.character) || '\u2014') + '</td><td>' + esc(f.badge) + '</td></tr>';
    }).join('');
    var stateRows = Object.keys(STATES).map(function (k) {
      return '<tr><th scope="row">' + stateChip(k) + '</th><td>' + esc(k) + '</td><td>' + (STATES[k].animate ? 'animated (unless reduced motion / plain)' : 'still') + '</td></tr>';
    }).join('');
    host.innerHTML =
      '<h3>Dispatch badges (13 job classes)</h3><div class="scroll"><table><thead><tr><th scope="col">Job class</th><th scope="col">Tier</th><th scope="col">Character</th><th scope="col">Badge</th></tr></thead><tbody>' + jobRows + '</tbody></table></div>' +
      '<h3>Function badges</h3><div class="scroll"><table><thead><tr><th scope="col">Function</th><th scope="col">Character</th><th scope="col">Badge</th></tr></thead><tbody>' + fnRows + '</tbody></table></div>' +
      '<h3>States</h3><div class="scroll"><table><thead><tr><th scope="col">Looks like</th><th scope="col">Key</th><th scope="col">Motion</th></tr></thead><tbody>' + stateRows + '</tbody></table></div>';
  }

  function applyTheme() {
    var t = theme(), rs = document.documentElement.style;
    Object.keys(t.palette).forEach(function (k) { if (/^--[a-z0-9-]+$/.test(k)) rs.setProperty(k, col(t.palette[k], '#000')); });
    document.body.classList.toggle('plain', prefs.plain);
    document.body.classList.toggle('reduce', prefs.reduce);
    document.body.classList.toggle('flavour', prefs.flavour && !prefs.plain);
  }

  function route() {
    var h = location.hash.replace(/^#/, ''), m;
    var drawer = document.getElementById('drawer'), dec = document.getElementById('decision');
    drawer.hidden = true; dec.hidden = true;
    var focusId = null;
    if ((m = /^project\/(.+)$/.exec(h)) && renderDrawer(decodeURIComponent(m[1]))) focusId = 'drawer-h';
    else if ((m = /^decision\/(.+)$/.exec(h)) && renderDecision(decodeURIComponent(m[1]))) focusId = 'decision-h';
    if (focusId) document.getElementById(focusId).focus();
    return focusId;
  }

  function renderAll() {
    applyTheme();
    var ship = prefs.layout === 'ship';
    document.getElementById('ship').hidden = !ship;
    document.getElementById('overview').hidden = ship;
    if (ship) { renderShip(); document.getElementById('overview-body').innerHTML = ''; }
    else { renderOverview(); document.getElementById('ship-body').innerHTML = ''; }
    renderGbp(); renderBounties(); renderLegend();
    route();
  }

  function boot() {
    var problems = [];
    var fixtureIds = D.jobs.classes.map(function (c) { return c.id; });
    if (fixtureIds.slice().sort().join() !== JOB_CLASSES.slice().sort().join()) problems.push('job-classes.json does not match the 13 known classes');
    ['bebop', 'plain'].forEach(function (k) {
      JOB_CLASSES.forEach(function (c) { if (!D.themes[k].job_classes[c]) problems.push(k + ' theme has no mapping for ' + c); });
    });
    ['bebop', 'plain'].forEach(function (k) {
      JOB_CLASSES.forEach(function (c) {
        var n = (D.themes[k].stations || []).filter(function (s) { return (s.job_classes || []).indexOf(c) !== -1; }).length;
        if (n !== 1) problems.push(k + ' theme places ' + c + ' at ' + n + ' ship stations (need exactly 1)');
      });
    });
    if (problems.length) {
      var b = document.getElementById('errors');
      b.hidden = false;
      b.textContent = 'Fixture/theme problems: ' + problems.join('; ');
    }
    document.getElementById('asof').textContent = fmtTime(D.board.generated_at);
    var opts = { 'opt-plain': 'plain', 'opt-reduce': 'reduce', 'opt-flavour': 'flavour' };
    Object.keys(opts).forEach(function (id) {
      var el = document.getElementById(id);
      el.checked = prefs[opts[id]];
      el.addEventListener('change', function () { prefs[opts[id]] = el.checked; renderAll(); });
    });
    Array.prototype.forEach.call(document.querySelectorAll('input[name="layout"]'), function (el) {
      el.checked = el.value === prefs.layout;
      el.addEventListener('change', function () { if (el.checked) { prefs.layout = el.value; renderAll(); } });
    });
    if (mql && mql.addEventListener) mql.addEventListener('change', function () {
      prefs.reduce = mql.matches; document.getElementById('opt-reduce').checked = mql.matches; renderAll();
    });
    window.addEventListener('hashchange', route);
    document.addEventListener('keydown', function (ev) {
      if (ev.key !== 'Escape' || !location.hash || location.hash === '#') return;
      var m = /^#decision\/(.+)$/.exec(location.hash), d = m && decisionsById[decodeURIComponent(m[1])], ref = d && cardById(d.card_id);
      location.hash = ref ? 'project/' + ref.project.id : '';
      if (!location.hash || location.hash === '#') document.getElementById(prefs.layout === 'ship' ? 'ship-h' : 'overview-h').focus();
    });
    renderAll();
  }
  boot();
})(this);
