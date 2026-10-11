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

const fnDeclRe = /^function\s+([A-Za-z_$][\w$]*)\s*\(/gm;
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

if (offenders.length) {
  console.log(`FAIL: ${offenders.length} function(s) reachable from ${root}() call a *Sync child_process function: ${offenders.sort().join(", ")}`);
  process.exit(1);
}
console.log(`PASS: no spawnSync/execSync/execFileSync reachable from ${root}() across ${visited.size} function(s)`);
process.exit(0);
