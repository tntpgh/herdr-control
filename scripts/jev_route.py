#!/usr/bin/env python3
"""Fail-closed TypeSafe JEV role router; stdlib only."""
from __future__ import annotations

import argparse
import json
import os
import sys
from urllib import error, request
from urllib.parse import unquote_plus
import re
import unicodedata

HIGH_RISK_RE = re.compile(
    r"\b(api[ -]?keys?|access[ -]?keys?|private[ -]?keys?|signing[ -]?keys?|ssh[ -]?keys?|"
    r"auth|authentication|credentials?|secrets?|tokens?|passwords?|oauth|permissions?|security|"
    r"vulnerabilit(?:y|ies)|exploit|encryption|money|payments?|billing|invoices?|refunds?|charges?|"
    r"payouts?|financial|wire[ -]?transfers?|external communications?|external comms|external emails?|emails?|"
    r"slack|sms|messages?|clients?|customers?|publish|post public|production|prod|live|deploy|release|ship|delete|remove|purge|destroy|"
    r"destructive|drop|truncate|erase|wipe|migrations?)\b",
    re.IGNORECASE,
)

def risk_text(text: str) -> str:
    decoded = unquote_plus(text)
    return "".join(ch for ch in decoded if unicodedata.category(ch) != "Cf")
ENDPOINT = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/systemone")
MODEL = "jev-latest"
ROLES = {"orchestrator": "plan", "planner": "plan", "implementer": "implement", "trivial": "mechanical", "escalate": None}
MIN_CONFIDENCE = 0.75


def fail(message: str) -> int:
    print(f"jev-route: {message}", file=sys.stderr)
    return 1


def read_brief(path: str | None) -> str:
    if path:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    return sys.stdin.read()


def payload_for(brief: str) -> dict:
    return {
        "state": brief,
        "model": MODEL,
        "questions": {
            "role": {
                "type": "choice",
                "instructions": "Which orchestration role should handle this task? Choose only a role, never an approval decision.",
                "criteria": {
                    "orchestrator": "Coordinate or dispatch multiple workers.",
                    "planner": "Analyze, design, research, or break down work.",
                    "implementer": "Implement or debug substantive code.",
                    "trivial": "Perform bounded mechanical or formatting work.",
                    "escalate": "Require human triage because risk or ambiguity is material.",
                },
            },
            "risk_high": {
                "type": "noul",
                "instructions": "Is this task high risk because it involves auth, secrets, security, money, production, deletion, or external communication?",
            },
        },
    }


def call_api(brief: str) -> dict:
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        raise RuntimeError("TYPESAFE_API_KEY is absent")
    body = json.dumps(payload_for(brief), separators=(",", ":")).encode("utf-8")
    req = request.Request(
        ENDPOINT,
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    try:
        with request.urlopen(req, timeout=15) as response:
            if response.status != 200:
                raise RuntimeError(f"API returned HTTP {response.status}")
            return json.loads(response.read().decode("utf-8"))
    except (error.URLError, error.HTTPError, TimeoutError, ValueError) as exc:
        raise RuntimeError("network/API failure") from exc


def parse_response(data: dict) -> dict:
    if not isinstance(data, dict) or not isinstance(data.get("answers"), dict):
        raise ValueError("malformed response")
    answers = data["answers"]
    role_answer = answers.get("role")
    risk_answer = answers.get("risk_high")
    if not isinstance(role_answer, dict) or role_answer.get("type") != "choice":
        raise ValueError("malformed role answer")
    role = role_answer.get("choice")
    confidence = role_answer.get("confidence")
    if role not in ROLES or isinstance(confidence, bool) or not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
        raise ValueError("invalid role or confidence")
    if not isinstance(risk_answer, dict) or risk_answer.get("type") != "noul":
        raise ValueError("malformed risk answer")
    risk = risk_answer.get("noul")
    if isinstance(risk, bool) or not isinstance(risk, (int, float)) or not 0 <= risk <= 1:
        raise ValueError("invalid risk answer")
    if confidence < MIN_CONFIDENCE:
        raise ValueError("low confidence")
    risk_high = risk >= 0.5
    if risk_high:
        role = "escalate"
    job_class = ROLES[role]
    return {
        "role": role,
        "job_class": job_class,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Route a task brief through TypeSafe JEV")
    parser.add_argument("--brief", help="path to a task brief; stdin is used when omitted")
    args = parser.parse_args(argv[1:])
    try:
        brief = read_brief(args.brief)
        if not brief.strip():
            return fail("empty brief")
        if HIGH_RISK_RE.search(risk_text(brief)):
            print(json.dumps({"role": "escalate", "job_class": None}, separators=(",", ":"), sort_keys=True))
            return 1
        result = parse_response(call_api(brief))
    except (OSError, RuntimeError, ValueError) as exc:
        return fail(str(exc))
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if result["role"] != "escalate" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
