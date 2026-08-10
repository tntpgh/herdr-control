# Herdr Browser pane stays at `about:blank` — root-cause report

Date: 2026-08-10

Installed browser plugin: `official.browser` 0.1.0, commit
`f05ae7a61ead89685eef5a7365f01f81110ba777`

## Conclusion

The reproduced `about:blank` failure is not caused by the daemon-to-pane URL
propagation path. It is a startup race in `preview.sh`, followed by an
incomplete success check. This investigation did not separately prove that
Herdr's page-body pixel transport has no independent defect; it proved why this
incident never advanced far enough to ask that layer to render the target page.

`herdr plugin pane open` returns before the plugin viewer has necessarily
created and heartbeated its pane-backed browser view. `preview.sh` immediately
runs the browser CLI without a view id. On the reproduced cold start, the CLI
won the race, created an unbound view (`pane_id: null`), and navigated that
view. The viewer then registered a second, pane-backed view 61 ms later, still
at `about:blank`.

`preview.sh` did not catch this because it:

1. discards the exit status and all output from `browser_cli open`; and
2. accepts any nonempty URL returned for the pane-backed view, including
   `about:blank`, instead of proving that the requested navigation landed.

Once two views exist, the plugin CLI correctly refuses an untargeted command
with `multiple browser views are open; set HERDR_BROWSER_VIEW_ID`. The wrapper
suppresses that error too, finds the pane's nonempty `about:blank` URL, prints
`loaded about:blank`, and exits 0. That zero exit is why `formserve.py` prints no
failure even though the operator sees no page.

The smallest fix belongs in this repository's `preview.sh`: wait for the view
whose `pane_id` matches the pane just opened, target that view explicitly with
`HERDR_BROWSER_VIEW_ID`, require the CLI navigation to succeed, and compare the
pane view's URL with the CLI's returned final URL. The installed plugin already
provides the required view id and explicit-target contract; no platform or
plugin patch is required for this defect.

## Direct observations

### Original live reproduction was not an HTTP failure

- PID 60833 was still running as
  `formserve.py /tmp/project-decisions.html --timeout 14400`.
- `/tmp/formserve_stderr.log` contained only:
  `formserve: serving project-decisions.html at http://127.0.0.1:64772/`.
- `curl http://127.0.0.1:64772/` returned the expected HTML, including the
  `Pending decisions` page title and its `<h1>` content.
- The owned pane `w8:p16` was not closed or reused during this investigation.
  By the time diagnosis began it had advanced from the reported `about:blank`
  state to the viewer's explicit `Browser session ended` screen, while the
  formserve process and HTTP server remained alive. That later daemon shutdown
  is a separate lifecycle outcome, not evidence that formserve failed.

### Exact silent-success reproduction

From a fresh Browser pane in the isolated `wN:t4` tab:

```text
$ bash preview.sh url http://127.0.0.1:64772/
preview: loaded about:blank
preview: but the page looks EMPTY or gated:
about:blank
preview_rc=0
```

The two daemon views immediately afterward were:

```text
view 5dcc9f80...  pane_id=null   created=12:02:33.967Z
  url=http://127.0.0.1:64772/

view 83914073...  pane_id=wN:pA  created=12:02:34.028Z
  url=about:blank
```

The CLI-created, unbound view preceded the actual pane view by 61 ms. A real
pane read confirmed what the operator saw:

```text
[1* about:blank][x] [+]
[<] [>] [R] [Stop] [-] [+] about:blank
```

With those two views present, the command that `preview.sh` was hiding said:

```text
$ browser_cli open http://127.0.0.1:64772/
multiple browser views are open; set HERDR_BROWSER_VIEW_ID
open_rc=1
```

### Renderer and Herdr pane propagation work when the right view is targeted

Using the pane-backed view id from `browser_cli views`:

```text
HERDR_BROWSER_VIEW_ID=83914073-... browser_cli open http://127.0.0.1:64772/
open_rc=0
```

The daemon then reported the target URL on the `wN:pA` view, and after the
viewer's normal refresh interval, `herdr pane read wN:pA --source visible`
showed:

```text
[1* 127.0.0.1:647.][x] [+]
[<] [>] [R] [Stop] [-] [+] http://127.0.0.1:64772/
```

This is the discriminating result: daemon navigation, viewer refresh, and the
actual Herdr-managed pane all propagated correctly when the command addressed
the pane's view.

### Cold-start behavior is race-dependent, but both bad branches are explained

An additional clean cold start produced the other race outcome: the wrapper's
existing `pane_view_url` check ran before any pane-backed view existed and
returned 1 with `no view is registered against pane`. That branch is already
caught. The operator-blocking branch occurs when the viewer registers just in
time for `pane_view_url` to return `about:blank`; because nonempty is the only
condition today, the wrapper returns false success.

The derived state directory was correct in the successful reproductions:
`~/.local/state/herdr/plugins/official.browser/daemon.json` was created and the
CLI and viewer shared its daemon. This rules out the previously documented
wrong-state-directory/throwaway-daemon defect for this incident.

## Code-path evidence

### In this repository

- `preview.sh:253-263` opens/focuses the pane and immediately runs
  `browser_cli open "$url"` with stdout and stderr discarded. The script uses
  `set -uo pipefail`, not `set -e`, so the nonzero result does not stop it.
- `preview.sh:269-276` treats only an empty `pane_view_url` result as failure.
  `about:blank` is nonempty and therefore passes.
- `preview.sh:279-299` runs a new untargeted `browser_cli text` process. With
  multiple views this also fails; its stderr is discarded and the empty parsed
  body is downgraded to a warning.
- `formserve.py:163-177` only reports a pane-open failure when `preview.sh`
  exits nonzero, so the wrapper's false zero is propagated to the human as
  apparent success.

### In the installed `official.browser` plugin

- `src/viewer.ts:189-200` creates a new view and only afterward heartbeats it
  with `HERDR_PANE_ID`. This happens asynchronously relative to the Herdr pane
  open RPC returning.
- `src/cli.ts:76-78` calls `ensureView()` before every non-stop command,
  including `open`.
- `src/daemonClient.ts:76-99` selects the sole existing view or creates a new
  view when none exists. Without `HERDR_BROWSER_VIEW_ID`, that newly created
  view has no pane association.
- `src/daemon.ts:268-295` creates each view at `about:blank` by default with
  `paneId: null`.
- `src/daemon.ts:298-308` refuses implicit selection when more than one view is
  open and explicitly directs callers to set `HERDR_BROWSER_VIEW_ID`.
- `src/daemon.ts:337-343` associates a view with a pane only when the viewer's
  heartbeat supplies its `paneId`.
- `src/daemonClient.ts:604-618` sends the selected view in the
  `x-herdr-browser-view` header; `src/daemon.ts:332-334,419-431` resolves that
  view and applies `/open` to it.
- `src/viewer.ts:196-199` establishes the viewer's selected view;
  `src/daemonClient.ts:139-141,604-618` uses it for `status()`, and
  `src/viewer.ts:1195-1199` refreshes from that status. The observed targeted
  navigation proved the URL/status toolbar path works.

## Ranked explanation

| Rank | Explanation | Confidence | Basis |
| --- | --- | --- | --- |
| 1 | `preview.sh` races viewer registration, navigates or ambiguously addresses the wrong view, suppresses the CLI error, and accepts `about:blank` as success. | High | Reproduced with exact command; view creation timestamps, CLI error, pane read, and exit code all align. |
| 2 | The installed plugin's viewer status path fails to propagate a correctly targeted navigation. | Ruled out for this incident | Explicitly targeting the pane-backed view changed the real pane toolbar to the target URL. Page-body pixels were not independently inspected. |
| 3 | `preview.sh` is using the wrong daemon state directory or a throwaway daemon. | Ruled out for this incident | CLI and pane view appeared in the same daemon and `daemon.json` at the derived path. |
| 4 | Formserve or its HTTP server failed. | Ruled out | Process remained alive and curl returned the expected page. |

## Proposed minimal patch (not applied)

The patch below is deliberately a draft. It has not been applied or tested.
It illustrates the required contract rather than silently changing every
future `preview.sh`/formserve call site during a diagnosis task.

```diff
diff --git a/preview.sh b/preview.sh
--- a/preview.sh
+++ b/preview.sh
@@
-browser_cli() {                         # run the plugin CLI against the REAL daemon
+browser_cli() {                         # run the plugin CLI against the REAL daemon
+  local view_id=""
+  if [ "${1:-}" = "--view-id" ]; then
+    view_id="${2:-}"
+    [ -n "$view_id" ] || return 1
+    shift 2
+  fi
   local root state
   root="$(browser_root)" || return 1
   state="$(browser_state_dir)" || return 1
   ( cd "$root" && HERDR_PLUGIN_ID="$BROWSER_PLUGIN" HERDR_PLUGIN_ROOT="$root" \
-      HERDR_PLUGIN_STATE_DIR="$state" bun run src/cli.ts "$@" )
+      HERDR_PLUGIN_STATE_DIR="$state" HERDR_BROWSER_VIEW_ID="$view_id" \
+      bun run src/cli.ts "$@" )
 }
+
+pane_view_id() {                        # $1 = pane id -> plugin view id, or fail
+  local pane_id="$1"
+  browser_cli views 2>/dev/null | python3 -c '
+import json, sys
+pane_id = sys.argv[1]
+try:
+    views = json.load(sys.stdin).get("views") or []
+except Exception:
+    sys.exit(1)
+for view in views:
+    if view.get("pane_id") == pane_id:
+        print(view.get("view_id") or "")
+        sys.exit(0)
+sys.exit(1)
+' "$pane_id" 2>/dev/null
+}
+
+wait_for_pane_view_id() {               # pane creation is asynchronous
+  local pane_id="$1" view_id attempt
+  for attempt in {1..100}; do
+    view_id="$(pane_view_id "$pane_id")" && [ -n "$view_id" ] && {
+      printf '%s\n' "$view_id"
+      return 0
+    }
+    sleep 0.05
+  done
+  return 1
+}
@@
-  local pane_id; pane_id="$(browser_pane_id)"
+  local pane_id view_id; pane_id="$(browser_pane_id)"
   [ -n "$pane_id" ] || die "browser pane did not open"
+  view_id="$(wait_for_pane_view_id "$pane_id")" || {
+    note "browser pane opened, but its plugin view did not become ready"
+    return 1
+  }

-  browser_cli open "$url" >/dev/null 2>&1
+  local opened expected
+  opened="$(browser_cli --view-id "$view_id" open "$url")" || {
+    # Leave the CLI's stderr intact: formserve captures and reports it.
+    note "navigation failed for pane $pane_id"
+    return 1
+  }
+  expected="$(printf '%s' "$opened" | python3 -c '
+import json, sys
+try:
+    print(json.load(sys.stdin).get("url") or "")
+except Exception:
+    pass
+' 2>/dev/null)"
+  [ -n "$expected" ] || {
+    note "navigation returned no final URL for pane $pane_id"
+    return 1
+  }
@@
-  if [ -z "$landed" ]; then
-    note "navigation reported success but no view is registered against pane $pane_id —"
-    note "the page is not on screen (the CLI may have driven a different daemon)."
+  if [ "$landed" != "$expected" ]; then
+    note "navigation returned $expected, but pane $pane_id is showing ${landed:-<nothing>}"
+    note "the page is not on screen"
     note "Check: herdr plugin pane open ... browser"
     return 1
   fi
@@
-  local body; body="$(browser_cli text 2>/dev/null | python3 -c '
+  local body; body="$(browser_cli --view-id "$view_id" text 2>/dev/null | python3 -c '
```

Important details of the proposed contract:

- Waiting for the pane-backed view closes the actual startup race; a fixed
  sleep would only make it less frequent.
- Explicit view targeting is necessary even if other Browser panes/views exist.
- The CLI's returned URL is the final post-redirect URL, so comparing against it
  avoids rejecting legitimate redirects while still rejecting `about:blank`.
- `text` must use the same explicit view or the existing render/gating check
  becomes ambiguous again.

Before applying this patch, add a focused regression verifier for `preview.sh`
that fakes Herdr/plugin JSON and proves:

1. pane open may return before the matching view appears;
2. navigation is issued with the matching `view_id`, never an implicit view;
3. a nonzero CLI navigation result makes `preview.sh` fail;
4. a landed URL different from the CLI's final URL makes it fail; and
5. a redirect whose final CLI URL matches the pane view succeeds.

## Verification boundary

Observed directly: formserve process liveness, HTTP response, original pane's
later daemon-ended state, multiple fresh pane reproductions, daemon state,
view ids/pane ids/timestamps/URLs, untargeted CLI refusal, targeted CLI success,
and the actual Herdr pane toolbar update. The command outputs above are the
retained transcript of those live probes; they are not a deterministic
automated regression test.

Inferred from code plus those observations: the exact scheduling order between
the Herdr pane-open RPC, viewer startup, and the first CLI process. The 61 ms
creation order and the plugin's selection rules make this inference high
confidence.

Not performed: no source patch was applied, no external plugin code was
modified, the proposed regression verifier was not implemented, and the
page-body pixel layer was not separately captured. The live owned pane
`w8:p16` and its formserve process were left in place.
