// check-no-bare-python3-spawn.mjs — static guard for round 6 finding 1
// (independent integrated review, REQUEST CHANGES at 42f7ea44): no function
// in this file may spawn the literal interpreter name "python3"/"python3.X"
// — every interpreter invocation must go through the one pinned, resolved,
// cached path (hubPythonCache / refreshHubPythonAsync(), itself backed by
// launchd/resolve-hub-python.sh) the same way ensureHub() already does,
// never the ambiguous PATH lookup bare `python3` performs.
//
// At 42f7ea44, recordOccurrence() called `spawnSync("python3", [...])`
// directly — this regex matches that literal and FAILS. After the round 6
// fix it reads `spawnSync(py, [...])` where `py` is `hubPythonCache`, which
// this regex does not match — PASSES.
//
// Usage: bun agent-hooks/check-no-bare-python3-spawn.mjs [file]
// Exit 0 and prints PASS, or exit 1 and prints FAIL plus the offending line(s).
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const file = process.argv[2] ?? path.join(HERE, "omp-herdr-control.ts");
const src = readFileSync(file, "utf8");

const bareSpawnRe = /\b(?:spawnSync|spawn|execSync|execFileSync)\s*\(\s*["']python3(?:\.\d+)?["']/g;
const lines = src.split("\n");
const offenders = [];
for (let i = 0; i < lines.length; i++) {
  bareSpawnRe.lastIndex = 0;
  if (bareSpawnRe.test(lines[i])) offenders.push(`  ${file}:${i + 1}: ${lines[i].trim()}`);
}

if (offenders.length) {
  console.log(`FAIL: ${offenders.length} spawn call(s) name the literal interpreter "python3" instead of a pinned/resolved path:\n${offenders.join("\n")}`);
  process.exit(1);
}
console.log(`PASS: no spawn call in ${file} names a literal "python3" interpreter`);
process.exit(0);
