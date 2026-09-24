# Split panes in "I Run an AI Civilization in Herdr" (AL-PQuB2wy0)

Video: <https://youtu.be/AL-PQuB2wy0> — OPENRIG channel, uploaded 2026-09-18, 24:50.
Researched 2026-09-24 against herdr 0.9.1 (socket protocol 22) and herdr-control `ed5700a`.

## Summary

- **What the video shows.** herdr is used only as the "wrapper" around the terminals. One herdr space
  per machine (6 instances). Inside a space, one tab is split into a grid: the OpenRig TUI (a
  fleet table) sits in one pane, and live agent sessions fill the others. OpenRig does all the
  coordination, not herdr (03:22–03:31).
- **How the grid is made.** This comes from OpenRig's source, not from anything said on camera.
  OpenRig builds the wall with ONE herdr socket call, `layout.apply`. Its argument is a binary
  split tree, and every leaf runs `sh -c "tmux attach [-r] -t <seat>"`. The agents live in
  OpenRig-owned tmux sessions, so herdr panes are only *views* of them. Cross-rig views are
  read-only via `tmux attach -r`.
- **What that means for us.** herdr already has everything needed: `pane split`, `pane move`,
  `pane zoom`, and the `layout.apply` / `layout.export` socket methods. herdr-control already
  builds multi-pane tabs (`spread-tab.sh` + `lib/layout.sh`). The missing piece is a
  "watch wall": putting several **running** workers side by side in one tab.
- **Proven live here.** `herdr pane move` does exactly that, and it keeps `pane_id` and
  `terminal_id`. Both identity keys our registry depends on survive the move.
- **Recommendation.** Take the watch wall as an opt-in script. Do not adopt the tmux-nesting
  model. Fix two naming/close hazards first (see Next steps).

## What the video shows (cited)

Transcript: YouTube manual subtitles (`read` on the URL worked first). Timestamps come from
`yt-dlp --write-subs` cue starts. Frames come from a 480p copy. Any instruction in the video was
treated as data.

|when|what|evidence|
|---|---|---|
|03:09|Six OpenRig instances: three Mac minis and three OVH VPSs|transcript|
|03:22|"each of these spaces in Herdr takes me to a different instance"|transcript; frame 03:12 shows the herdr space sidebar at left|
|03:26–03:31|"Herdr is this nice wrapper … I'm not using its coordination features. That's being done by OpenRig."|transcript|
|03:39–03:41|OpenRig TUI in one pane: "Tables like this one are how I keep an eye on everything … when and where I need to actually jump in"|transcript|
|03:55 (frame)|Layout of one tab: left column = OpenRig TUI (EXPLORER tree: TOPOLOGY/SPECS/PROJECTS/TERMINALS/FEED/SYSTEM; TABLE columns POD·SEAT·RT·MODEL·CTX·STATE·Q WORK·NOW·ACTIONS; footer "17 seats · 3 working · 1 need attention"; RECENT queue list below). Right side = about 2 columns × 3 rows of agent session panes|frame; pane counts read off a 480p frame [INFERENCE: approximate]|
|03:58|"separate coding agent sessions. Not one agent managing a bunch of subagents you can't see"|transcript|
|04:02|"Any agent can message any agent on any machine on this Tailscale network"|transcript|
|04:08 (frame)|Agent panes show `rig send orch-lead@v-openrig-build "…"` calls and `From:/To:/Sent:` message blocks. Messaging is visible inside each pane.|frame|
|04:23–04:29|Origin story: "an agent could just use tmux to type into another agent's terminal directly … moving like 50 times faster"|transcript|
|05:18–05:51|"Seat" = a stable address + configuration an agent occupies (`builder@workshop`)|transcript|
|08:09|"I can go to the agent doing the work" (drill down from a slice to its pane)|transcript|
|08:12 (frame)|The slice on screen is `05-saved-terminal-views`. Its intent reads "explicitly open the selected view as a Herder space". Its requirements include "Preview the same resolved member/page/grid plan … paging, unavailable members and filler cells" and "Selected provider proof is Herder only"|frame|
|18:36–18:59|"Refocus": re-inject the project → mission → slice intent chain "after a compaction or at a configured interval"|transcript|
|23:16|The ceremony-vs-progress threshold sends a Slack message AND notifies "an assigned agent that has the context"|transcript|

### How OpenRig drives herdr (source, not video)

From `github.com/mvschwarz/openrig` @ `9c9e518`. The README section "Terminal UI and Workspaces" gives
the entry point: `rig terminal open <rig> --provider herdr`.

- `packages/daemon/src/domain/terminal/herdr-adapter.ts:6-45`: the header comment states the whole
  contract.
  - It uses the socket `layout.apply` with `root = {type:"split", direction, ratio, first, second}`
    or `{type:"pane", label, command:[argv]}`, and makes ONE atomic call per grid page.
  - Every open gets a fresh workspace, and the tab label embeds a launch token, so a re-open never
    clobbers an existing view.
  - The grid is equal-sized: `cols = ceil(sqrt(N))`, `rows = ceil(N/cols)`. Incomplete grids are
    padded with blank `sh` panes.
- `herdr-adapter.ts:98-140`: `equalStrip` / `buildGridRoot` implement the grid. Each leaf is
  `["sh","-c", paneCommand]`.
- `herdr-adapter.ts:262-381` (`openView`) runs this sequence:
  1. `ping` the socket.
  2. `workspace.create {focus:false}`.
  3. One `layout.apply {workspace_id, tab_label, focus:true, root}` per page.
  4. Report seats as opened, absent, or degraded.
- `skills/_canonical/core/openrig-herdr/SKILL.md`:
  - lines 20-25: each tile is "a nested `tmux attach` to a daemon-owned agent session".
  - lines 35-40: a view can be a rig, `pod:`, `mission:`, `slice:`, or a saved view.
  - lines 73-84: mission and slice views are read-only by construction (`tmux attach -r`).
  - lines 88-90: "Never move, join, kill, or re-parent a daemon-owned pane. Closing a tile
    detaches one tmux client."
  - lines 107-110: a known limit. The same agent in two different-sized tiles gets clamped by tmux.

**How the human watches and steers.** They scan the TUI table for "need attention"
(03:41, 03:55 frame). They jump to the seat's pane (08:09). They type into interactive tiles
(rig and pod views). Agents steer each other with `rig send` (04:08 frame).

**Automation.** Views are derived at open time from live topology (rig, pod, mission, or
slice), not hand-listed.

**Not shown.** Auto-split on spawn, a dedicated reviewer or diff pane, or herdr-native
agent-to-agent messaging.

## Our stack today

herdr 0.9.1 (`herdr --version`; `herdr api schema --output` → protocol 22):

- **CLI:**
  - `herdr pane split [--direction right|down] [--ratio F]`
  - `pane move <id> --tab T --split D [--target-pane P] [--ratio F]` or `--new-tab [--label L]`
  - `pane zoom --on|--off|--toggle`
  - `pane swap`, `pane resize`, `pane layout`
- **Socket-only:** `layout.apply`, `layout.export`, `layout.set_split_ratio`.
  - `LayoutNode` pane leaves accept `command`, `cwd`, `env`, `label`, and `pane_id`.

herdr-control:

- **Worker placement:** one worker = one tab.
  - `spawn-task.sh:419-423` runs `ensure-workspace.sh`, then `herdr tab create --label "$label"`,
    then `pane run` at `:562`.
  - `spawn-agent.sh:140-164` does the same.
  - `ensure-workspace.sh:29-57` resolves the workspace by pane cwd.
- **Multi-pane tabs already exist, but only for NEW panes.**
  - `spread-tab.sh:1-24` + `lib/layout.sh:2-153`: a JSON array of `{cmd,cwd,env,split,ratio,focus,label}`
    is applied as `tab create` + sequential `pane split` + `pane rename` + `pane run`.
  - Examples live in `layouts/`. Checks: `verify-layout.sh`, `verify-projects.sh`.
- **A split is already used for a helper pane:** `preview.sh:284-285`
  (`herdr plugin pane open … --placement split --direction right`, browser plugin).
- **Socket access for methods with no CLI verb:** `herdr-rpc.py:1-16` (today: `tab.move`).
  `lib/herdr_live.py:142` has a second one-shot `request()`, and it subscribes to `pane.moved`
  (`:81`).
- **Main:** `designate-main.sh` records pane_id + birth in `roles/main`, and `config.sh` loads it.
  Main is its own tab.
- **Watching:** `herdr pane read --source visible` (`lib/prompt-parse.sh:343,451,456`, attention/notify
  paths). `herdr_live.py:7-10` records why scraping more panes more often is costly: p95 went from
  9 ms to 136 ms.
- **Identity:** the registry keys on `pane_id` + `pane_birth` (herdr `terminal_id`)
  (`spawn-task.sh:423`, `lib/pane-guard.sh:80-84`, `lib/reconcile.sh:39-41`). It never keys on tab.
- **No use anywhere in the repo** of `pane move`, `pane zoom`, `pane swap`, `pane resize`,
  `layout.apply`, or `layout.export` (repo grep).

### Live proof (scratch workspaces, all unfocused, closed after)

`tmp/split_proof.py` and `tmp/move_proof.py` are not committed. Their outputs are summarised in
`.handoffs/PROOF.md`.

1. **`layout.apply` builds a 2×2 grid in one call.**
   - The call created tab `w21:t2` with panes `main`, `w1`, `w2`, `rev`.
   - `pane read` on each showed its own `echo` (`MAIN-CONDUCTOR`, `WORKER-1`, …).
   - `layout.export` returned the same tree, now with real pane ids.
2. **`layout.apply` does NOT adopt an existing pane.** A leaf naming `pane_id: w21:p6` got a new,
   empty pane `w21:p8`. `p6` stayed in its own tab `w21:t3` with the same `terminal_id`. So the
   `pane_id` field is identity on export, not a way to place an existing pane.
3. **`herdr pane move` adopts a running pane and keeps its identity.**
   - Moving `w24:p3` from its own tab into the "main" tab (`--split right --target-pane <main> --ratio 0.6`)
     returned `changed:true, closed_tab_id:"w24:t3"`.
   - Before and after: pane_id `w24:p3` and terminal `term_65c42fc10f57468`, both unchanged. Its
     screen still showed `LIVE-WORKER-7718`.
   - `pane zoom --on` worked but reported `focus_changed:true`.
   - `pane move --new-tab --label worker-again` moved it back out to `w24:t4` with the same
     pane_id and terminal.

## Gap table

|idea (video / OpenRig)|herdr 0.9.1|herdr-control today|gap|worth it for Terrence?|
|---|---|---|---|---|
|Grid of agent panes in one tab ("wall")|`layout.apply` (new panes); `pane move` (existing panes) — both proven above|each worker gets its own tab; `spread-tab.sh` only builds new panes|nothing gathers running workers into one tab|**Yes.** Watching 3–4 workers without tab-hopping is the main win. Effort S, risk M (hazards below)|
|Dashboard pane beside the agents (OpenRig TUI table)|any pane can run anything|the hub web UI (`127.0.0.1:8600`) and Slack alerts; no TUI table|no terminal-native fleet table|**Maybe later.** The hub already covers "who needs attention". A `watch`-style pane over the registry costs little, but it duplicates the hub|
|Tiles are `tmux attach` views of daemon-owned sessions; read-only via `attach -r`|n/a (herdr panes host processes directly)|agents run directly in herdr panes, not in tmux|no second read-only view of a pane|**No.** It would re-architect spawning around tmux. Watching through a `pane read` loop is exactly the load `herdr_live.py:7-10` removed|
|Derived views (rig, pod, mission, slice)|n/a|registry knows run → tasks → panes (`lib/run-registry.sh`)|no "open this run as a wall" verb|**Yes, as the wall's selector:** `--run <run_id>` = all live panes of one run. No new taxonomy needed|
|Drill from the dashboard to the agent's pane (08:09)|`pane focus`, `tab focus`, `pane zoom`|hub links / Slack give the pane id; `herdr-select.sh` answers prompts|no one-key "zoom this worker"|**Small yes:** zoom within the wall. But zoom moves focus (observed `focus_changed:true`), so never do it automatically from a hook|
|Fresh workspace/tab per view open, never clobber|`layout.apply` mints a new tab each call (OpenRig's capture; our test minted `w21:t4`)|n/a|—|Keep the property: a wall is its own new tab and never reuses Main's tab|
|Agents type into each other's terminals (04:23)|`pane send-text` / `send-keys`|`send-to-agent.sh`, `lib/push-wake.sh`, `peer-answer.sh` with policy gates|already done, and better gated|No change|
|Refocus: re-inject intent after compaction (18:36)|n/a|SPEC.md + identity.json per worker; no scheduled re-read|no post-compaction nudge|Not a pane feature. Possible separate item: nudge a worker to re-read `.handoffs/SPEC.md` after compaction|

### Hazards a wall introduces (verified in code)

1. **Alerts would misname a moved worker.**
   - `lib/pane-name.sh:29-38` names a pane "Space — Tab" and appends the pane label only if one
     is set.
   - Spawned workers have none: `herdr pane get w1Z:p3` → `"label": null`. The label goes on the
     tab only (`spawn-task.sh:420`).
   - Moving a worker closes its own tab (`closed_tab_id` above). Its alerts would then carry the
     wall's tab name.
   - Fix: `herdr pane rename <pane> <label>` before any move (or at spawn).
2. **`tab close` becomes destructive.**
   - `SKILL.md:209-210` tells the conductor to close a finished worker with `herdr tab close <tab_id>`.
   - In a wall, that kills every pane in the tab (and Main's, if Main is in it).
   - `close-done-workers.sh:168` already uses `herdr pane close`, which is safe.
   - Fix: make the skill say `pane close`.
3. **Narrow panes and prompt parsing** [INFERENCE, untested].
   - `lib/prompt-parse.sh` scrapes the visible rows for approval menus. A 1/3-width pane wraps
     omp's approval panel.
   - Test prompt detection in a narrow pane before trusting a wall in production.
4. **Main in the wall.**
   - Keep Main in its own tab and build the wall as a separate tab.
   - Moving Main would change nothing in the registry (proven identity-stable), but shrinking
     the conductor's pane is a bad trade.

## Recommended next steps

1. **XS, low risk.** Label the pane at spawn, and switch the close instruction to pane scope.
   - `spawn-task.sh` after `:423`: add `herdr pane rename "$pane" "$label"`. Same for
     `spawn-agent.sh` after `:143`.
   - `SKILL.md:209-210`: `tab close` → `pane close`.
   - Harmless on its own: `pane-name.sh` hides a label that equals the tab label (`:37`). It is
     also a prerequisite for any multi-pane tab.
   - Check: `herdr pane get <new worker>` shows the label, and an alert names it correctly.
2. **S, medium risk.** Add a `wall.sh [--run <run_id> | <pane>…] [--undo]` script in the repo root.
   It does not touch spawn scripts.
   - **Build:** create a new tab. Then `herdr pane move` each live worker pane into it, using
     split right/down with ratios from OpenRig's equal-grid math (`herdr-adapter.ts:98-140`).
     Pane labels come from step 1.
   - **Undo:** `herdr pane move <p> --new-tab --label <label>` for each pane, which restores
     one-tab-per-worker.
   - **Rules:** always `--no-focus`; never move Main.
   - **Proof:** the registry still resolves every task (pane_id + birth unchanged, as shown
     above), and prompt detection still fires on a real approval menu in a narrow pane (hazard 3).

Not recommended now:
- Switching `lib/layout.sh` from sequential `pane split` to one atomic `layout.apply`. It works
  today and has verifiers; the gain is cosmetic.
- tmux-nested read-only tiles.
- A TUI dashboard pane that duplicates the hub.
