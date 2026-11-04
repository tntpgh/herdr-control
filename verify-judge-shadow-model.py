#!/usr/bin/env python3
"""verify-judge-shadow-model.py — scripts/judge-shadow.py's default judge model
is the exact Sonnet 5.5 selector (never bare `sonnet`) and --model still overrides.

  python3 verify-judge-shadow-model.py
"""
import importlib.util, os, sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("judge_shadow", os.path.join(here, "scripts", "judge-shadow.py"))
js = importlib.util.module_from_spec(spec)
spec.loader.exec_module(js)

seen = []
js.replay = lambda a: seen.append(a.model) or 0


def run(argv):
    sys.argv = ["judge-shadow.py"] + argv
    try:
        js.main()
    except SystemExit:
        pass


run([])
run(["--model", "opus"])
fails = 0
for got, want, what in ((seen[0], "anthropic/claude-sonnet-5-5", "default model"), (seen[1], "opus", "--model override")):
    ok = got == want
    fails += not ok
    print(f"  {'ok  ' if ok else 'FAIL'}  {what}: {got}")
sys.exit(1 if fails else 0)
