/* Run: bun run verify-form-draft.js
 *
 * Draft preservation, tightened per the conductor (2026-10-29): bound to a
 * semantic schema (question text, options, field set) AND the request's own
 * identity, never form id + field names alone; fails closed on any mismatch;
 * sensitive/hidden fields excluded; restoring needs a visible note PLUS a
 * manual click, no silent migration; survives an ACTUAL new-id restart, not
 * just a same-page reload. Pulls the ACTUAL <script> text out of
 * formserve.py's SHIM and hub.py's HUB_SUBMIT_SHIM (both serve the same
 * contract on different origins) and runs it against a hand-rolled
 * DOM/sessionStorage/fetch stub -- no jsdom, no network, per the
 * no-install constraint for this check. A real browser pass is done
 * separately via CDP (conductor, post-commit).
 */
import { readFileSync } from "fs";

var fails = 0;
function ok(name, cond) { console.log((cond ? "ok   " : "FAIL ") + name); if (!cond) fails++; }

function extractScripts(src, varMarker, placeholders) {
  var m = src.match(new RegExp(varMarker + ' = """([\\s\\S]*?)"""'));
  if (!m) throw new Error("could not find " + varMarker + " in source");
  var text = m[1];
  for (var k in placeholders) text = text.split(k).join(placeholders[k]);
  var scripts = [];
  var re = /<script>([\s\S]*?)<\/script>/g, sm;
  while ((sm = re.exec(text))) scripts.push(sm[1]);
  return scripts;
}

function buildScripts(requestId) {
  var formservePy = readFileSync("formserve.py", "utf8");
  var hubPy = readFileSync("hub.py", "utf8");
  var formserveScripts = extractScripts(formservePy, "SHIM", {
    "{{FORMSERVE_TOKEN}}": "test-token", "{{FORMSERVE_REQUEST_ID}}": requestId,
  });
  var hubScripts = extractScripts(hubPy, "HUB_SUBMIT_SHIM", {
    "%(token)s": "test-token", "%(form_id)s": requestId, "%(action)s": "/decisions/x/submit",
  });
  return { formserve: formserveScripts, hub: hubScripts };
}

var probe = buildScripts("TEST_FORM");
ok("formserve.py SHIM has both scripts (submit + draft)", probe.formserve.length === 2);
ok("hub.py HUB_SUBMIT_SHIM has both scripts (submit + draft)", probe.hub.length === 2);

// ── minimal DOM/sessionStorage/fetch stub ──────────────────────────────────
function makeEl(tag, opts) {
  opts = opts || {};
  return Object.assign({
    tagName: tag, value: "", checked: false, disabled: false, listeners: {}, textContent: "",
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    dispatch(type) { (this.listeners[type] || []).forEach((fn) => fn.call(this)); },
    setAttribute(k, v) { this[k] = v; },
    style: {}, appendChild(el) { (this.children = this.children || []).push(el); }, insertBefore() {},
  }, opts);
}

var sharedSessionStorage; // persists ACROSS "process restarts" within one scenario -- the whole point

function buildPage(heading, fieldSpecs, extraSpecs) {
  var elements = [
    makeEl("h1", { tagName: "h1", textContent: heading }),
    makeEl("input", { type: "hidden", id: "__formserve_token", value: "test-token" }),
    makeEl("input", { type: "hidden", id: "__formserve_request_id" }), // value set by caller via document
  ];
  fieldSpecs.forEach((spec) => elements.push(makeEl("input", spec)));
  // Decorative schema elements: labels and options, which schemaOf() reads
  // but fields()/isSensitive() never touch (not input/textarea/select).
  (extraSpecs || []).forEach((spec) => elements.push(makeEl(spec.tagName, spec)));
  var domReadyCbs = [];
  var body = {
    children: [],
    appendChild(el) { this.children.push(el); },
    insertBefore(el) { this.children.unshift(el); },
    firstChild: null,
  };
  var document_ = {
    getElementById: (id) => elements.find((e) => e.id === id) || null,
    querySelectorAll: (sel) => {
      var parts = sel.split(",").map((s) => s.trim());
      return elements.filter((e) => parts.some((p) => {
        if (p.indexOf("[type=") !== -1) {
          var tag = p.slice(0, p.indexOf("["));
          var want = p.match(/\[type=(\w+)\]/)[1];
          return e.tagName === tag && e.type === want;
        }
        return e.tagName === p;
      }));
    },
    createElement: (tag) => makeEl(tag),
    body: body,
    addEventListener: (ev, cb) => { if (ev === "DOMContentLoaded") domReadyCbs.push(cb); },
  };
  return { document: document_, elements, body, domReadyCbs, fire: () => domReadyCbs.forEach((cb) => cb()) };
}

function runRequest(label, requestId, heading, fieldSpecs, extraSpecs) {
  var scripts = buildScripts(requestId)[label];
  var fetchCalls = 0;
  global.window = {};
  global.fetch = () => { fetchCalls++; return Promise.resolve({ ok: true, text: () => Promise.resolve(JSON.stringify({ answers: {} })) }); };

  function evalInto(page) {
    global.document = page.document;
    global.sessionStorage = sharedSessionStorage;
    scripts.forEach((s) => eval(s));
    page.fire();
  }

  // "Process 1" -- the first run that ever served this request.
  var page1 = buildPage(heading, fieldSpecs, extraSpecs);
  page1.elements.find((e) => e.id === "__formserve_request_id").value = requestId;
  evalInto(page1);
  var q1a = page1.elements.find((e) => e.name === "q1"), notesA = page1.elements.find((e) => e.name === "notes");
  var secretA = page1.elements.find((e) => e.name === "secret"), apiKeyA = page1.elements.find((e) => e.name === "api_key");
  var hidden1A = page1.elements.find((e) => e.name === "hidden1");
  q1a.value = "draft answer"; q1a.dispatch("input");
  notesA.value = "some notes"; notesA.dispatch("input");
  if (secretA) { secretA.value = "shh"; secretA.dispatch("input"); }
  if (apiKeyA) { apiKeyA.value = "sk-xyz"; apiKeyA.dispatch("input"); }
  if (hidden1A) { hidden1A.value = "h"; hidden1A.dispatch("input"); }
  ok(label + ": typing never auto-submits", fetchCalls === 0);
  var key = Object.keys(sharedSessionStorage.data)[0];
  ok(label + ": a draft key was written, scoped to this request+schema",
    !!key && key.indexOf("herdr-form-draft:" + requestId + ":") === 0);
  var saved = JSON.parse(sharedSessionStorage.data[key] || "{}");
  ok(label + ": saved draft has the typed fields", saved.q1 === "draft answer" && saved.notes === "some notes");
  ok(label + ": saved draft excludes the password field", !("secret" in saved));
  ok(label + ": saved draft excludes a name-sensitive field even though its type is text", !("api_key" in saved));
  ok(label + ": saved draft excludes the hidden field", !("hidden1" in saved));

  return { page1, key, fetchCalls: () => fetchCalls, evalInto, scripts };
}

function restartAndCheck(label, requestId, heading, fieldSpecs, expectOffer, extraSpecs) {
  // "Process 2" -- an ACTUAL new-id restart: brand new DOM, brand new eval
  // of the extracted scripts, same browser-tab sessionStorage (same origin
  // surviving a restart/navigation -- the only way any of this persists).
  var scripts = buildScripts(requestId)[label];
  global.window = {};
  var fetchCalls = 0;
  global.fetch = () => { fetchCalls++; return Promise.resolve({ ok: true, text: () => Promise.resolve(JSON.stringify({ answers: {} })) }); };
  var page2 = buildPage(heading, fieldSpecs, extraSpecs);
  page2.elements.find((e) => e.id === "__formserve_request_id").value = requestId;
  global.document = page2.document;
  global.sessionStorage = sharedSessionStorage;
  scripts.forEach((s) => eval(s));
  page2.fire();

  var q1b = page2.elements.find((e) => e.name === "q1"), notesB = page2.elements.find((e) => e.name === "notes");
  var secretB = page2.elements.find((e) => e.name === "secret"), apiKeyB = page2.elements.find((e) => e.name === "api_key");
  var hidden1B = page2.elements.find((e) => e.name === "hidden1");
  var restoreBtn = (page2.body.children || []).flatMap((el) => [el].concat(el.children || []))
    .find((el) => el.tagName === "button");

  ok(label + ": restart never auto-submits", fetchCalls === 0);
  ok(label + ": " + (expectOffer ? "a restore offer is shown" : "no restore offer is shown (fail closed)"),
    !!restoreBtn === expectOffer);
  ok(label + ": nothing is silently applied before a manual click", q1b.value === "" && notesB.value === "");

  if (!expectOffer) return { fetchCalls: () => fetchCalls };

  restoreBtn.dispatch("click");
  ok(label + ": clicking Restore applies the saved value", q1b.value === "draft answer" && notesB.value === "some notes");
  ok(label + ": the password field is never restored, even after the click", !secretB || secretB.value === "");
  ok(label + ": the sensitive-named field is never restored, even after the click", !apiKeyB || apiKeyB.value === "");
  ok(label + ": the hidden field is never restored, even after the click", !hidden1B || hidden1B.value === "");

  return global.window.submitAnswers({ q1: q1b.value, notes: notesB.value }).then(() => {
    ok(label + ": explicit submit fetches exactly once", fetchCalls === 1);
  });
}

var QUESTION = { heading: "Approve the deploy?", fields: [
  { type: "text", name: "q1", id: "q1" },
  { type: "textarea", name: "notes", id: "notes" },
  { type: "password", name: "secret", id: "secret" },
  { type: "text", name: "api_key", id: "api_key" }, // sensitive by NAME, not type
  { type: "hidden", name: "hidden1", id: "hidden1" },
], extras: [
  { tagName: "label", textContent: "Pick an outcome" },
  { tagName: "option", value: "approve", textContent: "Yes, ship it" },
] };

function scenario(label) {
  runRequest(label, "ff-pilot-form", QUESTION.heading, QUESTION.fields, QUESTION.extras);

  // Same request, same question, genuinely new process/page -- must offer, not auto-apply.
  return restartAndCheck(label, "ff-pilot-form", QUESTION.heading, QUESTION.fields, true, QUESTION.extras)
    .then(() => {
      // Draft cleared by the prior submit -- reseed for the negative cases below.
      sharedSessionStorage.data = {};
      runRequest(label, "ff-pilot-form", QUESTION.heading, QUESTION.fields, QUESTION.extras);
      // Different request identity (a different source form) -- must fail closed.
      return restartAndCheck(label, "a-totally-different-form", QUESTION.heading, QUESTION.fields, false, QUESTION.extras);
    })
    .then(() => {
      // Same request, but the question text changed -- must fail closed too.
      return restartAndCheck(label, "ff-pilot-form", "A DIFFERENT question entirely", QUESTION.fields, false, QUESTION.extras);
    })
    .then(() => {
      // Same request, same heading, but a field was added -- schema changed -- fail closed.
      var changedFields = QUESTION.fields.concat([{ type: "text", name: "q2", id: "q2" }]);
      return restartAndCheck(label, "ff-pilot-form", QUESTION.heading, changedFields, false, QUESTION.extras);
    })
    .then(() => {
      // Same request, same heading, same fields -- only a LABEL's wording
      // changed. name/type/value of every real field is untouched; only the
      // human-readable question moved. Independent audit, 2026-10-29: this
      // used to restore anyway.
      var changedLabel = [
        { tagName: "label", textContent: "Pick a DIFFERENT outcome entirely" },
        { tagName: "option", value: "approve", textContent: "Yes, ship it" },
      ];
      return restartAndCheck(label, "ff-pilot-form", QUESTION.heading, QUESTION.fields, false, changedLabel);
    })
    .then(() => {
      // Same request, same heading, same fields, same label -- only an
      // OPTION's visible text changed; its value is still "approve". A
      // stale draft must not silently answer a reworded choice.
      var changedOptionLabel = [
        { tagName: "label", textContent: "Pick an outcome" },
        { tagName: "option", value: "approve", textContent: "Yes, but only after security review" },
      ];
      return restartAndCheck(label, "ff-pilot-form", QUESTION.heading, QUESTION.fields, false, changedOptionLabel);
    });
}

sharedSessionStorage = {
  data: {},
  getItem(k) { return k in this.data ? this.data[k] : null; },
  setItem(k, v) { this.data[k] = v; },
  removeItem(k) { delete this.data[k]; },
};

scenario("formserve")
  .then(() => { sharedSessionStorage.data = {}; return scenario("hub"); })
  .then(() => {
    console.log(fails === 0 ? "ALL PASS" : (fails + " FAILED"));
    process.exit(fails === 0 ? 0 : 1);
  });
