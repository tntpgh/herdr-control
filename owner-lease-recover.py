#!/usr/bin/env python3
"""owner-lease-recover.py --label L --project P --new-lifecycle-end END
--pane-id ID --pane-birth BIRTH --confirm-form FORM_ID [--apply] —
emergency recovery CLI around lib/owner_lease_recover.recover_lifecycle():
the ONE path that extends lifecycle_end_at for a REGISTERED label whose
bound has already passed and whose unregister_token is empty (or otherwise
unrecoverable through the normal unregister_owner()+reregister_owner()
cycle, R13-BOUNDS.md).

Human confirmation, checked in BOTH modes (same convention as --token on
owner-lease-unregister.py/owner-lease-reregister.py -- a dry-run reports the
SAME refusal a real run would, never a false preview): --confirm-form names
a formserve answer id, read from the PINNED forms state dir
(~/.local/state/herdr/forms/<id>.json, HERDR_STATE_ROOT overridable --
the same env var formserve.py itself reads). The record must be
status=="answered", answers.decision=="approve", and bound to THIS EXACT
request: answers.label, answers.new_lifecycle_end_at (within 1s) and
answers.caller_pane_id/answers.caller_pane_birth must all match this
invocation's own arguments, so a confirmation answered for a different
label, a different bound, or a different caller can never be replayed here.
This script never serves or creates a form -- it only ever reads one that
was already answered elsewhere; serving the decision form itself is the
conductor's job (Main), never a worker's.

--conductor-grant TOKEN is the SECOND, alternate confirmation path
(docs/design/weekly-conductor-authorization.md (f)), reached only by a
new, unattended daily tick -- never interactively by T. Mutually
exclusive with --confirm-form; when given, --new-lifecycle-end must NOT
also be given -- it is computed internally as
`min(now + ol.MAX_TTL_S, clamp_expires_at)`, where `clamp_expires_at`
comes from the redemption token itself (never recomputed from the
standing grant's own `expires_at`, and never a bare weekly grant
`command_id` -- `claim-conductor-redemption`/`peek-conductor-redemption`
reject that outright by checking `source=='conductor_weekly_redemption'`,
closing the exact REVIEW-GRANT-9ac2fc4 bearer-credential gap). A dry-run
calls `peek-conductor-redemption` (read-only, never burns the one-time
token); `--apply` calls `claim-conductor-redemption` (atomically
consumes it). `confirmation_ref` becomes `conductor_week:<grant_command_id>`
-- never the bare token id, so the audit trail still names exactly which
standing grant authorized the call, through its own child.

Never self-extension (lib/owner_lease_recover.py): --pane-id/--pane-birth
name the CALLER, which must NOT be the label's current live holder.

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DB names an
EXISTING, already-migrated DB (owner_projects table present) -- same
posture as every other owner_lease* writer CLI; this script never creates
or migrates the DB itself.

Exit: 0 recovered (or would, or an informational non-error business
status -- not_expired/no_lifecycle_bound); 2 refused (typed reason,
including race_lost); 4 config/confirmation.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import owner_lease as ol  # noqa: E402
import owner_lease_recover as olrec  # noqa: E402

FORM_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def forms_dir() -> Path:
    # Same PINNED-but-env-overridable root formserve.py's own FORMS_DIR reads
    # (HERDR_STATE_ROOT) -- never any other argument-controlled path.
    return Path(os.environ.get("HERDR_STATE_ROOT", str(Path.home() / ".local/state/herdr"))) / "forms"


def registry_db() -> Path:
    # Same env var/path convention lib/run-registry.sh's own run_state_root()
    # uses (HERDR_RUN_STATE_DIR) -- a DIFFERENT sqlite db than owner_lease's
    # own HERDR_OWNER_LEASE_DB; the conductor-week grant/redemption rows
    # live in the registry, not the owner-lease db.
    return Path(os.environ.get("HERDR_RUN_STATE_DIR", str(Path.home() / ".local/state/herdr/runs"))) / "registry.sqlite3"


def _task_authorization(op: str, *args: str) -> dict:
    """Subprocess call to lib/task-authorization.py -- the SAME adapter
    shape lib/run-registry.sh's own _task_authorization_adapter uses,
    never a second, parallel reimplementation of the storage layer.
    Raises ValueError with the adapter's own stderr reason on refusal."""
    helper = HERE / "lib" / "task-authorization.py"
    try:
        out = subprocess.run([sys.executable, str(helper), str(registry_db()), op, *args],
                             capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise ValueError(f"task_authorization_adapter_unreachable:{exc}") from exc
    if out.returncode != 0:
        reason = (out.stderr or "").strip() or "task_authorization_adapter_failed"
        raise ValueError(reason)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"task_authorization_adapter_bad_output:{op}") from exc


def read_confirmation(form_id: str, label: str, new_lifecycle_end_at: float,
                      caller_pane_id: str, caller_pane_birth: str) -> str | None:
    """None on a valid, exactly-bound confirmation. A short refusal reason
    string otherwise. Never raises on a missing/corrupt/mismatched form --
    every outcome here is a typed refusal the caller prints and exits on."""
    if not FORM_ID_RE.match(form_id or ""):
        return "invalid_form_id"
    try:
        rec = json.loads((forms_dir() / f"{form_id}.json").read_text())
    except (OSError, json.JSONDecodeError):
        return "form_unreadable"
    if not isinstance(rec, dict) or rec.get("status") != "answered":
        return "form_not_answered"
    answers = rec.get("answers")
    if not isinstance(answers, dict) or answers.get("decision") != "approve":
        return "form_not_approved"
    if answers.get("label") != label:
        return "form_label_mismatch"
    try:
        approved_bound = float(answers.get("new_lifecycle_end_at"))
        if (not math.isfinite(approved_bound)
                or not math.isfinite(new_lifecycle_end_at)
                or abs(approved_bound - new_lifecycle_end_at) > 1.0):
            return "form_bound_mismatch"
    except (TypeError, ValueError):
        return "form_bound_mismatch"
    if answers.get("caller_pane_id") != caller_pane_id or answers.get("caller_pane_birth") != caller_pane_birth:
        return "form_caller_mismatch"
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--new-lifecycle-end", type=float, dest="new_lifecycle_end", default=None,
                    help="ABSOLUTE epoch seconds; must be in the future and at most 24h out. "
                         "Required with --confirm-form; refused if given together with "
                         "--conductor-grant, which computes it internally.")
    ap.add_argument("--pane-id", required=True, dest="pane_id", help="the CALLER's own pane id (never the holder's)")
    ap.add_argument("--pane-birth", required=True, dest="pane_birth")
    confirm = ap.add_mutually_exclusive_group(required=True)
    confirm.add_argument("--confirm-form", dest="confirm_form",
                         help="a formserve answer id, already ANSWERED and bound to this exact request")
    confirm.add_argument("--conductor-grant", dest="conductor_grant",
                         help="a conductor-weekly-authorization redemption TOKEN id (never the bare "
                              "weekly grant id) -- unattended-tick path only, "
                              "docs/design/weekly-conductor-authorization.md (f)")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)

    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")

    if a.conductor_grant:
        # §(f): checked in BOTH modes -- peek (read-only) in dry-run, never
        # burning the one-time token on a preview; claim (atomic single-use
        # consume) only under --apply. Both reject a bare weekly grant
        # command_id outright (wrong `source`) and validate the label is
        # in the grant's own closed scope -- lib/task-authorization.py's
        # job, never re-derived here.
        if a.new_lifecycle_end is not None:
            print("refused:unconfirmed:new_lifecycle_end_with_conductor_grant")
            return 4
        op = "claim-conductor-redemption" if a.apply else "peek-conductor-redemption"
        try:
            redemption = _task_authorization(op, a.conductor_grant, a.label)
        except ValueError as exc:
            print(f"refused:unconfirmed:conductor_grant_invalid:{exc}")
            return 4
        clamp_expires_at = redemption.get("clamp_expires_at")
        grant_command_id = redemption.get("grant_command_id")
        if not isinstance(clamp_expires_at, int) or not grant_command_id:
            print("refused:unconfirmed:conductor_grant_malformed")
            return 4
        # §(f) item 5 / §(g) item 13: a lease this path creates or extends
        # can never reach past the grant's own expires_at (via the
        # redemption token's own clamp_expires_at, itself already clamped
        # to the grant at mint time, §(g) item 14) -- the OTHER half of
        # this min() is recover_lifecycle()'s own unchanged 24h ceiling.
        new_lifecycle_end = min(time.time() + ol.MAX_TTL_S, clamp_expires_at / 1000.0)
        # Never the bare grant id (REVIEW-GRANT-9ac2fc4) -- the redemption
        # token's own grant_command_id, prefixed so the audit trail still
        # reads as grant-authorized, not a formserve id.
        confirmation_ref = f"conductor_week:{grant_command_id}"
    else:
        if a.new_lifecycle_end is None:
            print("refused:unconfirmed:new_lifecycle_end_required")
            return 4
        new_lifecycle_end = a.new_lifecycle_end
        refusal = read_confirmation(a.confirm_form, a.label, new_lifecycle_end, a.pane_id, a.pane_birth)
        if refusal:
            print(f"refused:unconfirmed:{refusal}")
            return 4
        confirmation_ref = a.confirm_form

    if not a.apply:
        # R17b: dry-run opens read-only, never migrates.
        try:
            conn = ol.open_ro(db, require_table="owner_projects")
        except ValueError as exc:
            print(f"refused:{exc}")
            return 4
        try:
            cur, target = ol.schema_status(conn)
            if cur < target:
                print(f"schema_pending:{cur}->{target} (owner-lease-migrate.py --db {db} --apply) -- "
                      f"would_recover cannot be confirmed until migrated")
                return 0
            result, _token = olrec.recover_lifecycle(
                conn, a.label, a.project, new_lifecycle_end, a.pane_id, a.pane_birth,
                confirmation_ref, now=time.time(), dry_run=True)
        except ol.InvalidOwner as exc:
            print(f"refused:owner_project_mismatch:{exc}")
            return 2
        except ol.Unauthorized as exc:
            print(f"refused:unauthorized:{exc}")
            return 2
        except ol.Disabled as exc:
            print(f"refused:disabled:{exc}")
            return 2
        except ValueError as exc:
            print(f"refused:invalid_input:{exc}")
            return 2
        finally:
            conn.close()
        print(f"dry-run:{result}:{a.label}")
        return 0

    # R17b: --apply never migrates implicitly either.
    try:
        conn = ol.open_rw_checked(db, require_table="owner_projects")
    except ValueError as exc:
        print(f"refused:{exc}")
        return 4
    except ol.SchemaMigrationRequired as exc:
        print(f"refused:schema_migration_required:{exc.cur}->{exc.target}:owner-lease-migrate.py --db {db} --apply")
        return 4
    try:
        result, token = olrec.recover_lifecycle(
            conn, a.label, a.project, new_lifecycle_end, a.pane_id, a.pane_birth,
            confirmation_ref, now=time.time(), dry_run=False)
    except ol.InvalidOwner as exc:
        print(f"refused:owner_project_mismatch:{exc}")
        return 2
    except ol.Unauthorized as exc:
        print(f"refused:unauthorized:{exc}")
        return 2
    except ol.Disabled as exc:
        print(f"refused:disabled:{exc}")
        return 2
    except ValueError as exc:
        print(f"refused:invalid_input:{exc}")
        return 2
    finally:
        conn.close()
    if result == "recovered":
        print(f"apply:recovered:{a.label}:{token}")
        return 0
    print(f"apply:{result}:{a.label}")
    if result == "race_lost":
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
