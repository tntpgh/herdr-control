// check-no-sync-on-agent-start.mjs — static guard for the invariant PR #273
// established (2026-10-10, fix/omp-hook-nonblocking): onBeforeAgentStart does
// zero synchronous I/O, because it fires every turn, not once per session —
// a blocking call there freezes the whole omp UI event loop for its full
// timeout (384 ui.loop-blocked log entries/day before that fix).
//
// A source-text grep scoped to onBeforeAgentStart's OWN body is not enough:
// the round-4 regression this script exists to catch was `ensureHub()`
// calling `resolveHubPython()`, a *different* function, which called
// `spawnSync` — two hops from the handler, invisible to a single-function
// grep. This instead computes the full call-graph closure reachable from
// onBeforeAgentStart (BFS over every top-level `function name(...)` in the
// file, resolved by textual call-site matching) and checks EVERY function in
// that closure, at any depth, for spawnSync/execSync/execFileSync.
//
// Round 7 review (same-day correction): a reachable function can dispatch
// through a STORED function reference instead of a named call — e.g. push
// a closure into an array/variable from an unreachable function, then have
// a reachable function drain it generically (`for (const w of q) w()`).
// The callee `w` never textually names the real target, so the BFS above
// can never find it: a spawnSync buried in that closure is invisible, not
// merely indirect. Closes it by treating ANY bare-identifier call in a
// reachable function's body that is NEITHER a tracked top-level function
// NOR a known-safe global NOR declared locally within that same body as an
// "opaque call" — we cannot prove it is clean, so (fail-closed, matching
// this codebase's own house rule) it fails the check. See
// opaqueCalleesOf below and verify-check-no-sync-fixture.sh, which proves
// this extension actually fires on exactly that shape.
//
// Deliberately a plain regex/brace-balance walk, not a TS parser dependency:
// the codebase's house style always closes a function signature's type
// annotation with a bare `{` as the last non-whitespace token on its line
// (Prettier-formatted), which is what distinguishes the real body-opening
// brace from an inline return-type object literal's own (fully same-line-
// balanced) braces — see findBodyStart below.
//
// Usage: bun agent-hooks/check-no-sync-on-agent-start.mjs [file] [rootFn]
// Exit 0 and prints PASS, or exit 1 and prints FAIL plus the offending
// function names.
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const file = process.argv[2] ?? path.join(HERE, "omp-herdr-control.ts");
const root = process.argv[3] ?? "onBeforeAgentStart";
const src = readFileSync(file, "utf8");

function matchParenClose(s, openParenIdx) {
  let depth = 0;
  for (let i = openParenIdx; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

// The real function-body `{` is the first `{`, scanning forward from the end
// of the parameter list, that is the LAST non-whitespace character on its
// source line — an inline return-type object literal (e.g. a multi-line
// union return type) always closes its own braces on the same line it opens
// them, so it never qualifies.
function findBodyStart(s, fromIdx) {
  for (let i = fromIdx; i < s.length; i++) {
    if (s[i] !== "{") continue;
    let j = i + 1;
    while (j < s.length && (s[j] === " " || s[j] === "\t")) j++;
    if (s[j] === "\n" || s[j] === "\r") return i;
  }
  return -1;
}

function matchBraceClose(s, openBraceIdx) {
  let depth = 0;
  for (let i = openBraceIdx; i < s.length; i++) {
    if (s[i] === "{") depth++;
    else if (s[i] === "}") {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

const fnDeclRe = /^(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(/gm;
const bodies = {};
let m;
while ((m = fnDeclRe.exec(src))) {
  const name = m[1];
  const nameStart = m.index;
  const parenOpen = src.indexOf("(", m.index);
  const parenClose = matchParenClose(src, parenOpen);
  if (parenClose === -1) continue;
  const bodyStart = findBodyStart(src, parenClose);
  if (bodyStart === -1) continue;
  const bodyEnd = matchBraceClose(src, bodyStart);
  if (bodyEnd === -1) continue;
  bodies[name] = src.slice(nameStart, bodyEnd);
}

const names = Object.keys(bodies);
if (!bodies[root]) {
  console.error(`FAIL: root function "${root}" not found in ${file}`);
  process.exit(1);
}

function calleesOf(body) {
  const calls = new Set();
  for (const n of names) {
    if (new RegExp(`\\b${n.replace(/\$/g, "\\$")}\\s*\\(`).test(body)) calls.add(n);
  }
  return calls;
}

const visited = new Set([root]);
const queue = [root];
while (queue.length) {
  const cur = queue.shift();
  const body = bodies[cur];
  if (!body) continue;
  for (const callee of calleesOf(body)) {
    if (callee !== cur && !visited.has(callee)) {
      visited.add(callee);
      queue.push(callee);
    }
  }
}

const syncCallRe = /\b(spawnSync|execSync|execFileSync)\s*\(/;
const offenders = [...visited].filter((n) => bodies[n] && syncCallRe.test(bodies[n]));

// Every top-level `import { a, b as c } from "..."` binding is a KNOWN,
// readable declaration (never an opaque runtime-stored closure) — this
// also covers the module's own async `spawn` alongside sync fs helpers
// like `readFileSync`/`writeFileSync` that are a different, already-
// accepted category (small bounded local file I/O, not the process-spawn
// blocking this checker exists to catch) rather than something to
// hand-maintain in a safe-list.
const IMPORTED_NAMES = new Set();
const importRe = /^import\s+(?:type\s+)?\{([^}]*)\}\s*from/gm;
let im;
while ((im = importRe.exec(src))) {
  for (const part of im[1].split(",")) {
    const bound = part.trim().split(/\s+as\s+/).pop()?.trim();
    if (bound) IMPORTED_NAMES.add(bound.replace(/^type\s+/, ""));
  }
}
// A handful of true JS globals not worth importing to name.
const SAFE_GLOBAL_CALLEES = new Set([
  "Promise", "Array", "Object", "JSON", "Math", "Boolean", "Number", "String",
  "Symbol", "RegExp", "Error", "TypeError", "RangeError", "Map", "Set",
  "WeakMap", "WeakSet", "Date", "Proxy", "Reflect", "globalThis", "BigInt",
  "console", "setTimeout", "clearTimeout", "setInterval", "clearInterval",
  "setImmediate", "clearImmediate", "queueMicrotask", "structuredClone",
  "fetch", "parseInt", "parseFloat", "isNaN", "isFinite",
  "encodeURIComponent", "decodeURIComponent", "encodeURI", "decodeURI",
]);
// JS keywords the bare-call regex below also matches before their own `(`
// (`if (`, `for (`, `catch (`, …) — not calls at all.
const JS_KEYWORDS = new Set([
  "if", "for", "while", "switch", "catch", "do", "function", "async",
  "return", "typeof", "in", "of", "new", "yield", "await", "else", "delete",
  "void", "throw", "with",
]);
// Blanks out comments and string/template literal CONTENTS (never braces or
// code structure outside them) so prose like "task(s)" in a user-facing
// message or "zero (rather than …)" in a comment cannot be mistaken for a
// call. Applied only to the derived text opaqueCalleesOf scans — never to
// the raw `src`/`bodies` the proven brace-matching and syncCallRe logic
// above already depends on.
function stripNoise(s) {
  let out = "";
  let i = 0;
  while (i < s.length) {
    const c = s[i], c2 = s[i + 1];
    if (c === "/" && c2 === "/") {
      while (i < s.length && s[i] !== "\n") { out += " "; i++; }
      continue;
    }
    if (c === "/" && c2 === "*") {
      out += "  "; i += 2;
      while (i < s.length && !(s[i] === "*" && s[i + 1] === "/")) { out += s[i] === "\n" ? "\n" : " "; i++; }
      if (i < s.length) { out += "  "; i += 2; }
      continue;
    }
    if (c === "'" || c === '"' || c === "`") {
      const quote = c; out += " "; i++;
      while (i < s.length && s[i] !== quote) {
        if (s[i] === "\\" && i + 1 < s.length) { out += "  "; i += 2; continue; }
        out += s[i] === "\n" ? "\n" : " "; i++;
      }
      if (i < s.length) { out += " "; i++; }
      continue;
    }
    out += c; i++;
  }
  return out;
}
const bareCallRe = /(?:^|[^.\w$])([A-Za-z_$][\w$]*)\s*\(/g;
function hasLocalDecl(body, id) {
  return new RegExp(
    `\\b(?:function\\s+${id}\\b` +
    `|(?:const|let|var)\\s+${id}\\s*=` +
    `|(?:const|let|var)\\s*\\{[^}]*\\b${id}\\b[^}]*\\}\\s*=` +
    `|(?:const|let|var)\\s*\\[[^\\]]*\\b${id}\\b[^\\]]*\\]\\s*=)`,
  ).test(body);
}
// This function's OWN declared parameters (e.g. a callback argument like
// `cb` in `captureOutput(cmd, args, opts, cb)`): calling one is the normal,
// pervasive async idiom this file already uses everywhere, not the risk —
// the risk is a call to something declared OUTSIDE this function entirely.
function paramNamesOf(body) {
  const openParen = body.indexOf("(");
  if (openParen === -1) return new Set();
  const closeParen = matchParenClose(body, openParen);
  if (closeParen === -1) return new Set();
  const found = new Set();
  for (const seg of body.slice(openParen + 1, closeParen - 1).split(",")) {
    const mm = seg.trim().match(/^[{[]?\s*([A-Za-z_$][\w$]*)/);
    if (mm) found.add(mm[1]);
  }
  return found;
}
// Any bare call in a reachable function's body to an identifier that is
// NEITHER a tracked top-level function (already followed by the BFS above)
// NOR an imported/safe-global name NOR one of this function's own
// parameters NOR declared locally within that same body is an OPAQUE
// dispatch: the real callee could be any closure defined anywhere else in
// the file, including one holding spawnSync. Cannot be proven clean, so it
// fails the check rather than silently passing.
function opaqueCalleesOf(rawBody) {
  const body = stripNoise(rawBody);
  const params = paramNamesOf(body);
  const found = new Set();
  let mm;
  bareCallRe.lastIndex = 0;
  while ((mm = bareCallRe.exec(body))) {
    const id = mm[1];
    if (JS_KEYWORDS.has(id)) continue;
    if (names.includes(id)) continue;
    if (IMPORTED_NAMES.has(id) || SAFE_GLOBAL_CALLEES.has(id)) continue;
    if (params.has(id)) continue;
    if (hasLocalDecl(body, id)) continue;
    found.add(id);
  }
  return found;
}
const opaque = {};
for (const n of visited) {
  if (!bodies[n]) continue;
  const found = opaqueCalleesOf(bodies[n]);
  if (found.size) opaque[n] = [...found].sort();
}
const opaqueOffenders = Object.keys(opaque);

if (offenders.length) {
  console.log(`FAIL: ${offenders.length} function(s) reachable from ${root}() call a *Sync child_process function: ${offenders.sort().join(", ")}`);
  process.exit(1);
}
if (opaqueOffenders.length) {
  const detail = opaqueOffenders.sort().map((n) => `${n}(${opaque[n].join(",")})`).join("; ");
  console.log(`FAIL: ${opaqueOffenders.length} function(s) reachable from ${root}() call an opaque/indirect identifier that cannot be proven free of spawnSync/execSync/execFileSync: ${detail}`);
  process.exit(1);
}
console.log(`PASS: no spawnSync/execSync/execFileSync reachable from ${root}() across ${visited.size} function(s), no opaque dispatch`);
process.exit(0);
