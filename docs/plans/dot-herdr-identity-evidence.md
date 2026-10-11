# Identity repair: candidate and verification

Date: 2026-10-10 UTC. Inactive code only; no live designation or canary.

Code candidate: `4e41e83b66ee9309c3dae56ed7f17707ecb6dd91`, branch `fix/dot-control-authorization`. The parent reports external independent approval of the earlier bounded M1 at `2f7c6fd359afe1227225235761fff4e98beec367`. Fresh independent security and test reviews are CLEAR on this exact code, with zero unresolved HIGH/CRITICAL and no remaining finding. The parent's separate external review is still pending. It does not authorize deployment, a new persistent grant or a real approval.

## Result and implementation boundary

The inherited caller-identity function could treat missing or malformed Herdr process inventory as a proven outside-Herdr caller (`rc=2`). That result is an eligibility input to the existing `designate-main.sh --force` gate. Failed/unknown identity must instead return 1; valid complete matching identity returns 0 and valid complete outside identity returns 2. The force policy and consumer remain unchanged.

`lib/pane-guard.sh` now parses raw Herdr output before shell capture using isolated Python standard-library JSON decoding. It rejects invalid UTF-8, malformed/multiple documents, duplicate keys, nonstandard numeric constants, missing/wrong-type fields, unsafe pane identifiers and noninteger/out-of-range process IDs. Integer-token PIDs must be in `1..2147483647`; booleans, decimals, exponent encodings and numeric rounding cannot identify a caller. Complete arrays are validated before output. Scoped `pipefail` retains producer failures; failed map lookup returns unknown. `python3 -I -S` excludes CWD/PYTHONPATH modules and site startup hooks.

Only the shared identity function and regression verifier change production behavior. Two older verifier fixtures now use valid nonmatching numeric PIDs instead of zero/missing PID. Those changes preserve their real ancestry check; no host restriction or production identity rule was loosened.

## Review history: rejected candidates remain rejected

| Candidate | Finding and disposition |
|---|---|
| `8947af4` | First missing/malformed response repair. Review found escaped newline/NUL and glob-bearing pane IDs could normalize during serialization. One MEDIUM; not accepted. |
| `15e0bc1` | Absolute ASCII ID validation. Review found raw NUL bytes removed by Bash before validation. One MEDIUM; BLOCK. |
| `0be4844` | Direct raw jq parsing and producer failure propagation. Independent lanes found invalid UTF-8 normalization and permissive/rounded numeric parsing. Two MEDIUM findings across the lanes, zero HIGH/CRITICAL; BLOCK. |
| `1836510` | Strict standard-library decoder. Test lane passed, but security found two HIGH issues: unisolated CWD/PYTHONPATH imports and unchecked map-lookup failure. Overall BLOCK; test CLEAR did not override security. |
| `d7090fc` | Isolated parser imports and checked lookup status, plus five new tests. Test CLEAR; security WATCH with zero HIGH/CRITICAL and one LOW inferred large-map/early-exit refusal. The initial reviewer fixture could not exclude E2BIG; the subsequent streamed red control proves `printf: Broken pipe`. |
| `4e41e83` | Consume the entire map while printing the first match. One streamed large-inventory test proves the repair. Fresh independent security and test reviews CLEAR; zero unresolved HIGH/CRITICAL, no remaining finding. Both independently reran all 77 cases. |

The final security reviewer began fresh, did not author or advise the fixes, independently ran 77/77, inspected the large-map red control and verified the unchanged exact-rc2 force gate. The test reviewer independently ran 77/77, inspected the streamed fixture and corresponding 76/1 red control, and confirmed cleanup, syntax and first-match behavior. Its verdict is explicitly test-only. No reviewer who advised a repair approves that repair here. Reviews used fixtures and scratch state, never live workers, real designation, network or model CLI requests.

## Reproducible evidence

| Check | Exact observed result | Evidence |
|---|---|---|
| `bash verify-process-identity-failures.sh` at `4e41e83` | 77 passed, 0 failed; all Herdr/ps calls intercepted; actual force consumer tested for refusal only | [Current isolated suite](evidence/dot-control/identity-current.txt) |
| New 77-case suite with old `d7090fc` guard | 76 passed, 1 failed, explicit broken pipe; streamed large valid inventory avoids exported-payload limits | [Large-map red control](evidence/dot-control/identity-large-red.txt) |
| New 76-case suite with old `1836510` guard | 71 passed, 5 failed; lookup failure and module substitution regressions | [Import/lookup red control](evidence/dot-control/identity-import-red.txt) |
| 71-case suite with old `0be4844` guard | 58 passed, 13 failed; numeric, duplicate-key and UTF-8 regressions | [Strict parser red control](evidence/dot-control/identity-json-red.txt) |
| 56-case suite with old `15e0bc1` guard | 47 passed, 9 failed; raw-byte regressions | [Raw-byte red control](evidence/dot-control/identity-raw-red.txt) |
| 42-case suite with old `8947af4` guard | 36 passed, 6 failed; escaped ID/serialization regressions | [Encoding red control](evidence/dot-control/identity-encoding-red.txt) |
| First 36-case suite with old `2f7c6fd` guard | 12 passed, 24 failed; missing/malformed inventory and force-refusal regressions | [Initial red control](evidence/dot-control/identity-old-code-red.txt) |

Each red control runs an archived old source tree in a temporary directory with the newer verifier. Force assertions require both exit 3 and the exact caller-gate refusal diagnostic; a later target refusal does not pass. Positive matching/outside cases prevent a refuse-everything implementation from passing. Producer failures after valid output, malformed later array entries/another pane, unavailable/truncated ancestry, identical and nonmatching raw-byte cases are included. CWD/PYTHONPATH substitution is directly exercised; exclusion of site startup hooks relies on the Python `-S` execution mode, not a separate startup-hook fixture.

The verifier is exercised by `.github/scripts/verify-task-authorization.sh`. Final exact-candidate CI at `4e41e83` completed with exit 0: **497 checks** (source authentication 64, registry authorization 24, action transactions 14, reservations 25, registry 134, provenance gates 56, identity 77, registry integration 103). [Full CI log](evidence/dot-control/identity-current-ci.txt). Timer/process checks explicitly excluded by `--registry-only` are not counted or claimed. The complete baseline-to-candidate installed read-only secret scanner exited 0 with no warnings; no push ran. [Scanner evidence](evidence/dot-control/identity-secret-scan.txt).

A supporting enforcement rerun completed **185/185, exit 0**. It began on `d7090fc` and overlapped the final full-map-consumption correction, so this is explicitly **not an independently frozen 4e41e83 run**. [Supporting enforcement log](evidence/dot-control/identity-enforce-supporting.txt). The final frozen CI and focused verifier provide exact-candidate results; the earlier external reviewer also independently passed 185/185 at the approved M1 baseline. Worker source is unchanged by the identity commits; no new Worker runtime claim is made. Earlier gate logs are historical evidence, not substituted for the final candidate.

## Operational limits and next work

No live canary has run. Actual workflow owner-relay/interruption counts are **not measured**. This engineering task required zero owner input requests, zero owner relays and zero human approval prompts; local git metadata writes used auto-review. Those counts do not establish workflow acceptance. Live designations, KB/Main sends, merge/push/deploy, security-setting changes and new persistent grants: **0**.

The next bounded scopes are [menu/watchdog observations and durable receipt-to-ack recovery](dot-herdr-recovery-slices.md). Full M2 epochs/expiry/HEAD-index/full-ceiling binding and global nonremote admission are conditional follow-ons, not automatic prerequisites for an operationally isolated trusted-host canary. Legacy unknown provenance still needs genuine new bounded authorization; no historical approval is backfilled.

The existing Library report remains the externally reviewed `2f7c6fd` snapshot pending the parent's new review. Preserve `libfile_5327f8eaa4dc8191b09c9c853b428b5c` when refreshing it; no duplicate or premature replacement is made.
