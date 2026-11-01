#!/usr/bin/env python3
"""owner-lease-bind-lifecycle.py --label L --project P --lifecycle-end END
--pane-id ID --pane-birth BIRTH --confirm-form FORM_ID [--apply] —
emergency recovery CLI around lib/owner_lease_recover.bind_missing_lifecycle():
the companion to owner-lease-recover.py for a REGISTERED label whose
lifecycle_end_at was never set at all (NULL) -- e.g. a row inserted before
R13-BOUNDS.md, or by a register_owner() call that omitted the bound. Neither
owner-lease-recover.py (refuses "no_lifecycle_bound" -- it is strictly the
already-expired-bound emergency) nor owner-lease-reregister.py (refuses
"not_unregistered" -- the row was never unregistered) covers this case.

Human confirmation, checked in BOTH modes (same convention as
owner-lease-recover.py's --confirm-form): --confirm-form names a formserve
answer id, read from the PINNED forms state dir
(~/.local/state/herdr/forms/<id>.json, HERDR_STATE_ROOT overridable). The
record must be status=="answered", answers.decision=="approve", and bound to
THIS EXACT request: answers.label, answers.project, and answers.lifecycle_end_at
(within 1s) must all match this invocation's own arguments. Unlike
owner-lease-recover.py's confirmation, this one does NOT bind caller_pane_id/
caller_pane_birth -- the approval is over WHICH label/project/bound, not WHO
runs the recovery; the self-extension guard below is still always enforced,
independent of what the form says, so no caller identity needs to be
pre-approved. This script never serves or creates a form -- it only ever
reads one that was already answered elsewhere; serving the decision form
itself is the conductor's job, never a worker's.

Never self-extension (lib/owner_lease_recover.py): --pane-id/--pane-birth
name the CALLER, which must NOT be the label's current live holder.

Refuses unless HERDR_OWNER_LEASE_WRITER=1 and HERDR_OWNER_LEASE_DB names an
EXISTING, already-migrated DB (owner_projects table present) -- same posture
as every other owner_lease* writer CLI; this script never creates or
migrates the DB itself.

Exit: 0 bound (or would, or an informational non-error business status --
already_bound); 2 refused (typed reason, including race_lost); 4
config/confirmation.
"""
from __future__ import annotations

import argparse
import json
import os
import re
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


def read_confirmation(form_id: str, label: str, project: str, lifecycle_end_at: float) -> str | None:
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
    if answers.get("project") != project:
        return "form_project_mismatch"
    try:
        if abs(float(answers.get("lifecycle_end_at")) - lifecycle_end_at) > 1.0:
            return "form_bound_mismatch"
    except (TypeError, ValueError):
        return "form_bound_mismatch"
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--lifecycle-end", required=True, type=float, dest="lifecycle_end",
                    help="ABSOLUTE epoch seconds; must be in the future and at most 24h out")
    ap.add_argument("--pane-id", required=True, dest="pane_id", help="the CALLER's own pane id (never the holder's)")
    ap.add_argument("--pane-birth", required=True, dest="pane_birth")
    ap.add_argument("--confirm-form", required=True, dest="confirm_form",
                    help="a formserve answer id, already ANSWERED and bound to this exact request")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)

    if os.environ.get("HERDR_OWNER_LEASE_WRITER") != "1":
        print("refused:flags_off")
        return 4
    db = os.environ.get("HERDR_OWNER_LEASE_DB", "")

    refusal = read_confirmation(a.confirm_form, a.label, a.project, a.lifecycle_end)
    if refusal:
        print(f"refused:unconfirmed:{refusal}")
        return 4

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
                      f"would_bind cannot be confirmed until migrated")
                return 0
            result, _token = olrec.bind_missing_lifecycle(
                conn, a.label, a.project, a.lifecycle_end, a.pane_id, a.pane_birth,
                a.confirm_form, now=time.time(), dry_run=True)
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
        result, _token = olrec.bind_missing_lifecycle(
            conn, a.label, a.project, a.lifecycle_end, a.pane_id, a.pane_birth,
            a.confirm_form, now=time.time(), dry_run=False)
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
    print(f"apply:{result}:{a.label}")
    if result == "race_lost":
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
