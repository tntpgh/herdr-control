#!/usr/bin/env python3
"""Behaviour checks for chrome-relay.py's kill decision: which Chrome counts
as the real one, and when an omp-profile stray may be SIGTERMed. No real
process is signalled (os.kill is patched); state lives in a temp dir.

    python3 verify-chrome-relay.py
"""
from __future__ import annotations

import importlib.util
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("chrome_relay", HERE / "chrome-relay.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

TMP = Path(tempfile.mkdtemp(prefix="chrome-relay-verify-"))
cr.STATE = TMP
cr.IDLE_FILE = TMP / "idle.json"
B = cr.BIN


class Kind(unittest.TestCase):
    def test_classification(self):
        omp = cr.OMP_PROFILES
        cases = {
            B: "real",
            f"{B} --profile-directory=Profile 1": "real",
            f"{B} --user-data-dir={cr.UDD}": "real",
            f"{B} --user-data-dir={cr.UDD}/ --flag": "real",
            f"{B} --no-startup-window --user-data-dir={omp}/google-chrome-91d4 --remote-debugging-port=1": "omp",
            f"{B} --user-data-dir={omp}-old/x": None,          # sibling dir, not omp's
            f"{B} --user-data-dir=/tmp{omp}/x": None,          # omp path nested elsewhere
            f"{B} --user-data-dir={cr.UDD}-Backup": None,      # a different dir sharing the prefix
            f"{B} --user-data-dir=/tmp/x": None,
        }
        for args, want in cases.items():
            with self.subTest(args=args):
                self.assertEqual(cr.chrome_kind(args), want)

    def test_etime(self):
        self.assertEqual([cr.etime_s(e) for e in ("00:05", "01:02:03", "2-00:00:01")], [5, 3723, 172801])


class StalePort(unittest.TestCase):
    def test_devtools_port_file_older_than_the_process_is_ignored(self):
        prof = cr.OMP_PROFILES / f"zz-verify-{os.getpid()}"
        with mock.patch.object(Path, "stat") as st, mock.patch.object(Path, "read_text", return_value="5555\n/x"):
            args = f"{B} --user-data-dir={prof} --remote-debugging-port=0"
            st.return_value = mock.Mock(st_mtime=1000.0)
            self.assertIsNone(cr.omp_cdp_port(args, started_at=2000.0))
            self.assertEqual(cr.omp_cdp_port(args, started_at=900.0), 5555)
        self.assertEqual(cr.omp_cdp_port(f"{B} --user-data-dir={prof} --remote-debugging-port=9333", 0), 9333)


def stray(pid=101, lstart="Thu Oct  1 22:19:57 2026", age=600, port=9471, clients=()):
    return {"pid": pid, "lstart": lstart, "age_s": age, "cdp_port": port, "cdp_clients": list(clients)}


class CloseIdle(unittest.TestCase):
    def setUp(self):
        cr.IDLE_FILE.unlink(missing_ok=True)

    def ticks(self, *per_tick):
        with mock.patch.object(cr.os, "kill") as kill:
            for strays in per_tick:
                cr.close_idle(strays)
        return [c.args[0] for c in kill.call_args_list]

    def test_idle_on_two_ticks_is_closed_once(self):
        self.assertEqual(self.ticks([stray()], [stray()]), [101])

    def test_one_idle_tick_is_not_enough(self):
        self.assertEqual(self.ticks([stray()]), [])

    def test_a_client_between_ticks_resets_it(self):
        self.assertEqual(self.ticks([stray()], [stray(clients=[7])], [stray()]), [])

    def test_reused_pid_with_a_new_start_time_does_not_match(self):
        self.assertEqual(self.ticks([stray()], [stray(lstart="Fri Oct  2 09:00:00 2026")]), [])

    def test_never_closed_while_young_attached_or_port_unknown(self):
        for s in (stray(age=30), stray(clients=[58047]), stray(port=None)):
            with self.subTest(s=s):
                cr.IDLE_FILE.unlink(missing_ok=True)
                self.assertEqual(self.ticks([s], [s], [s]), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
