# herdr-control-board — static prototype

A self-contained, read-only page for herdr-control state. It uses **synthetic fixtures only**: no live data,
no hub API, no network, no storage, and nothing that can approve, deny, dispatch or publish.
The look is a draft. The author never saw the two reference mockups, so this page does not claim to match either.

## Open it

Open `prototype/board/index.html` straight from disk, with no server: double-click it, or run
`open prototype/board/index.html` on macOS. Everything it needs is in this folder. The page's CSP sets
`connect-src 'none'` and `form-action 'none'`, so the browser itself blocks any network call or form post.

Browsers refuse `fetch()` from `file://`, so `index.html` carries inline `<script type="application/json">`
copies of the JSON files. **The JSON files are the source of truth.** After you edit one, regenerate the copies
and re-run the check (both commands run from the worktree root):

```sh
python3 prototype/board/sync.py
/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc prototype/board/check.js
```

`check.js` runs in macOS's bundled JavaScriptCore shell, so it needs no node or npm. It fails when an inline copy
drifts from its JSON file. It also covers the 13 job classes, state derivation, the approval literals, contrast,
the no-network scan, and a stub-DOM render smoke of both layouts.

## Layouts (both dark only, same data, same literal states)

The **View** switch in the top bar picks the layout. **B is the default.**

**B — Ship (working cutaway).** The ship's hull is drawn as a rounded outline with a brass edge and a rounded nose
on the left. Inside it, rooms sit in a 3-column grid:

```
 ( Bridge (Jet) ................ | Lounge (Faye)    )
 ( Ed's terminal nook | Ein's QA |   + GBP drafts   )
 ( Hangar (Spike)     | Cargo    | Big Shot bounty  )   [ Review dock (Vicious) — outside the hull, dashed ]
```

- Each crew member sits at their station. The station shows its worker cards: the same card as the project
  drawer, minus the avatar, plus a link to the card's project and lane.
- The figure at a station moves only when that station has an **executing** worker. A station whose only work is
  stale, blocked or failed shows a still "alert" pose.
- Bridge: plan and architect work, the captain and release-watch badges, and the comms line ("Decisions waiting
  on you").
- Hangar: Spike as project lead (one line per project lead, with links into each project), plus debug work.
- Lounge: research and explore work, plus a summary of the Business Profile drafts.
- Cargo hold: workers with an **unrecognized** job class, plus maintenance and archive lanes. The three old guys
  make a cameo here.
- Big Shot's screen: the bounty board.
- Review dock: review and deep-review. It sits outside the hull because review is independent of the crew.
- The rooms are set by `stations` in the theme file. Each station's `area` picks its grid slot. Below 1100 px the
  hull drops to 2 columns, below 640 px to 1.

**A — Captain overview (alternate).** Jet's calm view: one line per project, showing its summary, the number
executing, "needs a look: …" in plain words, and model spend today. Below that is the decision line. Each project
name opens the **project drawer**, which lists lanes and worker cards with avatars. In A, the bounty board is its
own panel.

These are shared by both layouts:

- the project drawer (`#project/<id>`);
- the decision detail (`#decision/<id>`), which quotes the exact request text and states the literal answer.
  It has no control: the quoted `[Approve] [Deny]` is text;
- the Business Profile drafts panel (Faye);
- the badges-and-states legend.

Esc goes back one level. Focus moves to the heading of whatever opens.

## Display options

| Option | Effect |
|---|---|
| Plain dark mode | Swaps to `themes/plain/theme.json`: no sprites, greyscale dark palette, text station names. Turns on by default under `prefers-contrast: more`. |
| Reduce motion | Stops every animation. Turns on by default under `prefers-reduced-motion: reduce`. The CSS media query also disables animation on its own. |
| Flavour text | Off by default. The only place humour appears. Never shown in plain mode. |

Contrast: every text colour in both palettes is ≥ 4.5:1 against every background colour (WCAG AA). `check.js`
computes the ratios.

## State → visual

Display states are derived in `board.js` (`deriveDisplay`) from engine vocabulary, which was checked in this
worktree:

- task states `starting|running|blocked|completed|failed|cancelled|lost` — `lib/run-registry.sh:1157-1162`;
- hub-derived `stalled|ready_review` — `hub.py:821,844`;
- owner-request `queued|held|timeout|stale` — `lib/owner_lease.py:84-85`;
- dispatch `denied` — `lib/owner_dispatch_auth.py:108`;
- form `expired|gone` — `hub.py:1239,1243`.

States carry the same meaning in every theme. Colour is never the only signal: each state also has its own border
style, icon and words.

| Display state | Engine source | Chip / card | Icon | Motion | Words shown |
|---|---|---|---|---|---|
| Executing | task `running`, updated ≤ 5 min ago | amber solid border | ▶ | station figure bobs (only state that moves) | "Working now. Last update N min ago." |
| Queued | owner request `queued` | dashed muted border | … | still | "Waiting in the queue (position N). Not started." |
| On hold (on purpose) | owner request `held` | brass double border, diagonal hatching | ‖ | still | "Held on purpose by X. reason. Will not run until released." |
| Waiting on a decision | task `blocked` | thick warn border | ? | still, hand-up pose | "Waiting on a human decision (d1)…" |
| Denied | dispatch auth `denied` | red, struck-through label | ⊗ | still, alert pose | "Denied: note. The refused action did not run." |
| Timed out — NOT approved | owner request `timeout`, form `expired`, or open past deadline | dotted thick grey; sprite greyed | ◷ | still | "No answer before the deadline… treated as NOT approved." |
| Stale — no recent update | task `running` with no update for > 5 min, or owner request `stale` | dotted grey, italic, dark card; sprite greyed | ◌ | **never animated** | "Engine last said "running", but nothing for N min. Not known to be working." |
| Stalled — owes an action | hub `stalled` | dashed thick warn | △ | still, alert pose | what the worker owes |
| In review | hub `ready_review` | info-blue solid | ◉ | still, reading pose | "Finished; waiting on review of …" |
| Deployed — NOT verified | `completed` + `shipped` + proof, deploy required but no live check | dashed warn, hatched chip, green left edge | ◐ | still | deploy note + "Not done until a live check passes." |
| Done — proof on file | `completed` + `shipped` + proof (+ live check if required) | filled green chip | ✔ | still | "Shipped. Proof: …" |
| Closed — no ship claimed | `completed` with a non-`shipped` reason | thin border | ■ | still | "Closed: handed off to implement. No ship or proof claimed." |
| Failed | task `failed` | filled red chip, heavy border | ✖ | still, alert pose | "Failed: <detail>" |
| Cancelled | task `cancelled` | thin, struck-through | ⊘ | still | "Cancelled (canceled)." |
| Lost — worker gone | task `lost` | dotted red; sprite greyed | ∅ | still | "Lost: the worker disappeared without a result." |
| Starting | task `starting` | dotted info | ○ | still | "Launching. No work reported yet." |
| Unrecognized engine state | anything else, including `shipped` without proof | dashed red | ¿ | still | quotes the raw engine state; never guesses |

Decision literals: Pending (NOT approved) · APPROVE recorded · DENY recorded · Timed out (NOT approved, NOT
declined) · Cancelled · Form server gone (NOT approved). Only an `answered` + `approve` row ever reads as approved.

Costs appear in plain words as "Model spend today: $N" per card, lane and project; the figures are synthetic.
Failures and denials print their detail. Bounties carry **no** money, rewards or points.

## Characters and badges (presentation only)

Characters and badges never change permissions, ownership or approval paths. The mapping lives in
`themes/bebop/theme.json`. A theme pack can replace it as long as it keeps the same keys.

| Who | Role / badges | Job classes |
|---|---|---|
| Jet | Captain (top conductor), release watch, planning | `plan`, `architect` |
| Spike | Project lead (role 2), debugger | `debug` |
| Faye | Research and opportunities; Business Profile drafts panel | `research`, `explore` |
| Ed | Design and build | `design`, `implement`, `code`, `docs` |
| Ein | QA and test | `quick`, `mechanical` |
| Vicious | Independent adversarial review: Review (standard-high) and Deep review (deep) are separate badges | `review`, `deep-review` |
| Big Shot (guest) | Presents new bounty cards | — |
| The three old guys (guest) | Maintenance and archive cameo | — |
| (none) | "Unrecognized job class" fallback. **Not a class**; secrets are withheld (fail-closed) | anything outside the 13 |

`docs` → Ed is a judgement call: docs is build output.

The sprites are simple inline SVG drawn from each character's canonical look. The `look` field in the theme holds
that description, and it is also the screen-reader label. To restyle without touching `board.js`, change
`sprite_style` (outline, frame, head size) or the per-character `sprite` params (hair, colours, extras).

Tiers come from `lib/agent-profiles.sh:182-217`. `research` has no row of its own, so it falls to the default
(standard) row; the unreviewed design inventory lists it differently.

## Files

| Path | What |
|---|---|
| `index.html` | page skeleton + generated inline data block |
| `board.css` | dark layout, state visuals, ship grid, plain/reduced-motion/mobile rules |
| `board.js` | pure logic (exported as `Board`) + DOM rendering |
| `fixtures/board.json` | 3 projects, 5 lanes, 15 worker cards |
| `fixtures/decisions.json` | 4 decisions (open, expired, denied, approved) |
| `fixtures/job-classes.json` | the 13 classes + tiers, and the unrecognized note |
| `fixtures/gbp-drafts.json` | 3 Business Profile drafts |
| `fixtures/bounties.json` | 2 bounties |
| `themes/bebop/theme.json`, `themes/plain/theme.json` | replaceable presentation packs |
| `sync.py` | regenerates the inline data block |
| `check.js` | acceptance check (JavaScriptCore) |
