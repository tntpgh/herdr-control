#!/usr/bin/env python3
"""Pure receipt-verification checks: no sockets, subprocesses or live state.

The signing helper is independent of authorization.py. The fixed Unicode
vector also lets the TypeScript issuer test the exact same wire bytes.
Verification establishes admission only; durable replay/launch checks belong
to the task/registry integration tests, not this stateless verifier.
"""
from __future__ import annotations

import copy
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock

from authorization import AuthorizationError, VerifiedAuthorization, canonical_json, payload_sha256, verify_command


KEY = "fixture-key-authorization-v1-32-characters"
NOW = 1791590400000
DOMAIN = b"herdr-task-authorization-v1\n"
ALLOWLIST = {
    "repos": ["knowledge-base", "other-repo"],
    "modes": {
        "research": {"job_class": "research", "secrets": "grant", "git": "none", "writes": [], "net_read": []},
        "implement": {"job_class": "implement", "secrets": "default", "git": "push-own-branch", "writes": [], "net_read": []},
    },
}
FIXTURE_PAYLOAD_JSON = '{"mode":"implement","objective":"Inspect café ☕ and 東京; preserve scope.","repo":"knowledge-base"}'
FIXTURE_PAYLOAD_SHA256 = "5a44844abf90a9cb633a62676556682388162aa10582582a7af1fc996e47a917"
FIXTURE_CLAIMS = ('{"command_id":"cmd_fixture_1","effective_scope":{"git":"push-own-branch",'
                  '"job_class":"implement","net_read":[],"secrets":"default","writes":[]},'
                  '"expires_at":1791591000000,"issued_at":1791590400000,"mode":"implement",'
                  '"op":"start","payload_sha256":"5a44844abf90a9cb633a62676556682388162aa10582582a7af1fc996e47a917",'
                  '"remote_task_id":"rtask_20261010T000000Z_0123abcd","repo":"knowledge-base",'
                  '"requester_actor":"fixture-owner@example.com","requester_client":"fixture-oauth-client",'
                  '"scope":"herdr:task.implement","source":"oauth_task_delegation","version":1}')
FIXTURE_SIGNATURE = "1bd26b8d87d7dc597ca40aa3617b7e9f961f0443b9ddf16cebb2433a0d1378ae"


def reference_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def sign_raw(claims: str, key: str = KEY) -> dict:
    signature = hmac.new(key.encode("utf-8"), DOMAIN + claims.encode("utf-8"), hashlib.sha256).hexdigest()
    return {"claims": claims, "signature": signature}


def command(mode: str = "implement", op: str = "start") -> dict:
    payload = {"repo": "knowledge-base", "mode": mode, "objective": "Inspect café ☕ and 東京; preserve scope."}
    cmd = {"command_id": "cmd_fixture_1", "op": op,
           "remote_task_id": "rtask_20261010T000000Z_0123abcd", "payload": payload}
    if op == "resume":
        payload.pop("objective")
        payload.update(local_task_id="task_original", local_run_id="run_original",
                       branch="remote/0123abcd", text="Continue the same approved scope.")
    claims = {
        "version": 1, "source": "oauth_task_delegation", "command_id": cmd["command_id"],
        "op": op, "remote_task_id": cmd["remote_task_id"], "requester_actor": "fixture-owner@example.com",
        "requester_client": "fixture-oauth-client", "scope": "herdr:task.start" if mode == "research" else "herdr:task.implement",
        "repo": payload["repo"], "mode": mode, "effective_scope": copy.deepcopy(ALLOWLIST["modes"][mode]),
        "payload_sha256": hashlib.sha256(reference_json(payload).encode("utf-8")).hexdigest(),
        "issued_at": NOW, "expires_at": NOW + 600000,
    }
    cmd["authorization"] = sign_raw(reference_json(claims))
    return cmd


def changed_claims(cmd: dict, **changes: object) -> dict:
    result = copy.deepcopy(cmd)
    claims = json.loads(result["authorization"]["claims"])
    claims.update(changes)
    result["authorization"] = sign_raw(reference_json(claims))
    return result


class AuthorizationVerification(unittest.TestCase):
    def setUp(self):
        self.cmd = command()
        self.allowlist = copy.deepcopy(ALLOWLIST)

    def verify(self, cmd=None, *, key=KEY, now=NOW, allowlist=None):
        return verify_command(self.cmd if cmd is None else cmd, key,
                              self.allowlist if allowlist is None else allowlist, now_ms=now)

    def refused(self, cmd, **kwargs):
        with self.assertRaises(AuthorizationError):
            self.verify(cmd, **kwargs)

    def test_unicode_cross_language_wire_vector(self):
        self.assertEqual(canonical_json(self.cmd["payload"]), FIXTURE_PAYLOAD_JSON)
        self.assertEqual(payload_sha256(self.cmd["payload"]), FIXTURE_PAYLOAD_SHA256)
        self.assertEqual(self.cmd["authorization"]["claims"], FIXTURE_CLAIMS)
        self.assertEqual(self.cmd["authorization"]["signature"], FIXTURE_SIGNATURE)
        verified = self.verify()
        self.assertEqual(verified.claims, FIXTURE_CLAIMS)
        self.assertEqual(verified.signature, FIXTURE_SIGNATURE)
        self.assertEqual(verified.parsed, json.loads(FIXTURE_CLAIMS))

    def test_canonical_nested_keys_and_array_order(self):
        value = {"z": [{"z": 1, "a": "é"}, False, None], "a": [2, 1]}
        self.assertEqual(canonical_json(value), '{"a":[2,1],"z":[{"a":"é","z":1},false,null]}')
        self.assertNotEqual(payload_sha256({"items": [1, 2]}), payload_sha256({"items": [2, 1]}))

    def test_both_existing_mode_entitlements(self):
        for mode in ("research", "implement"):
            with self.subTest(mode=mode):
                cmd = command(mode=mode)
                self.assertTrue(self.verify(cmd).matches(cmd, self.allowlist, now_ms=NOW))

    def test_resume_binds_existing_work_mapping(self):
        cmd = command(op="resume")
        self.assertEqual(self.verify(cmd).parsed["op"], "resume")
        for field in ("local_task_id", "local_run_id", "branch", "text"):
            with self.subTest(field=field):
                changed = copy.deepcopy(cmd)
                changed["payload"][field] += "_substituted"
                self.refused(changed)

    def test_resume_requires_explicit_signed_payload_mode(self):
        cmd = command(op="resume")
        del cmd["payload"]["mode"]
        claims = json.loads(cmd["authorization"]["claims"])
        claims["payload_sha256"] = payload_sha256(cmd["payload"])
        cmd["authorization"] = sign_raw(reference_json(claims))
        self.refused(cmd)

    def test_resume_explicit_mode_must_match(self):
        cmd = command(op="resume")
        cmd["payload"]["mode"] = "research"
        cmd = changed_claims(cmd, payload_sha256=payload_sha256(cmd["payload"]))
        self.refused(cmd)

    def test_identical_transport_retry_keeps_same_receipt(self):
        first, second = self.verify(), self.verify(copy.deepcopy(self.cmd))
        self.assertEqual(first.claims, second.claims)
        self.assertEqual(first.signature, second.signature)

    def test_missing_authorization(self):
        self.cmd.pop("authorization")
        self.refused(self.cmd)

    def test_malformed_envelope(self):
        for envelope in (None, [], "signed", {}, {"claims": FIXTURE_CLAIMS},
                         {"signature": FIXTURE_SIGNATURE}, {"claims": 1, "signature": FIXTURE_SIGNATURE},
                         {"claims": FIXTURE_CLAIMS, "signature": FIXTURE_SIGNATURE, "approved_by": "Main"}):
            with self.subTest(envelope=envelope):
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"] = envelope
                self.refused(cmd)

    def test_unavailable_or_short_verification_key(self):
        for key in (None, "", "x" * 31, b"x" * 32):
            with self.subTest(key=key):
                self.refused(self.cmd, key=key)

    def test_wrong_key(self):
        self.refused(self.cmd, key="a-different-fixture-key-with-32-characters")

    def test_malformed_signature(self):
        for signature in (None, 0, "", "0" * 63, "0" * 65, "g" * 64, FIXTURE_SIGNATURE.upper()):
            with self.subTest(signature=signature):
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"]["signature"] = signature
                self.refused(cmd)

    def test_claim_tamper_without_resigning(self):
        for old, new in (("fixture-owner", "other-owner"), ("fixture-oauth-client", "other-oauth-client"),
                         ("push-own-branch", "commit-only"), ("0123abcd", "0123abce")):
            with self.subTest(field=old):
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"]["claims"] = FIXTURE_CLAIMS.replace(old, new)
                self.refused(cmd)

    def test_wrong_signature_domain(self):
        cmd = copy.deepcopy(self.cmd)
        cmd["authorization"]["signature"] = hmac.new(KEY.encode(), FIXTURE_CLAIMS.encode(), hashlib.sha256).hexdigest()
        self.refused(cmd)

    def test_signed_malformed_json(self):
        for claims in ("{", "null", "[]", '"claims"', "{}"):
            with self.subTest(claims=claims):
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"] = sign_raw(claims)
                self.refused(cmd)

    def test_duplicate_top_level_json_key(self):
        cmd = copy.deepcopy(self.cmd)
        cmd["authorization"] = sign_raw(FIXTURE_CLAIMS.replace('"version":1}', '"version":1,"version":1}'))
        self.refused(cmd)

    def test_duplicate_nested_scope_key(self):
        cmd = copy.deepcopy(self.cmd)
        cmd["authorization"] = sign_raw(FIXTURE_CLAIMS.replace('"writes":[]}', '"writes":[],"writes":[]}'))
        self.refused(cmd)

    def test_signed_noncanonical_claims(self):
        data = json.loads(FIXTURE_CLAIMS)
        for claims in (json.dumps(data, indent=2), FIXTURE_CLAIMS + "\n",
                       json.dumps(dict(reversed(list(data.items()))), separators=(",", ":")),
                       FIXTURE_CLAIMS.replace('"version":1', '"version":1.0')):
            with self.subTest(claims=claims[:50]):
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"] = sign_raw(claims)
                self.refused(cmd)

    def test_claims_size_bound(self):
        self.refused(changed_claims(self.cmd, requester_actor="x" * 32768))

    def test_missing_or_unknown_claim_field(self):
        for field in json.loads(FIXTURE_CLAIMS):
            with self.subTest(missing=field):
                claims = json.loads(FIXTURE_CLAIMS)
                claims.pop(field)
                cmd = copy.deepcopy(self.cmd)
                cmd["authorization"] = sign_raw(reference_json(claims))
                self.refused(cmd)
        self.refused(changed_claims(self.cmd, approved_by="Main"))

    def test_protocol_and_source_are_exact(self):
        for version in (0, 2, True, "1", None):
            with self.subTest(version=version):
                self.refused(changed_claims(self.cmd, version=version))
        for source in ("Main", "conductor_unknown", "human_exact_command", "", None):
            with self.subTest(source=source):
                self.refused(changed_claims(self.cmd, source=source))

    def test_actor_and_client_require_bounded_text(self):
        for field in ("requester_actor", "requester_client"):
            for value in (None, 1, [], {}, "", "x" * 257, "actor\nforged", "actor\x00forged"):
                with self.subTest(field=field, value=value):
                    self.refused(changed_claims(self.cmd, **{field: value}))

    def test_validity_window_requires_integer_epoch_milliseconds(self):
        for field in ("issued_at", "expires_at"):
            for value in (None, True, str(NOW), float(NOW), 0, -1):
                with self.subTest(field=field, value=value):
                    self.refused(changed_claims(self.cmd, **{field: value}))

    def test_expired_including_exact_expiry(self):
        for now in (NOW + 600000, NOW + 600001):
            with self.subTest(now=now):
                self.refused(self.cmd, now=now)
        self.verify(now=NOW + 599999)

    def test_future_issue_skew_boundary(self):
        self.verify(changed_claims(self.cmd, issued_at=NOW + 30000))
        self.refused(changed_claims(self.cmd, issued_at=NOW + 30001))

    def test_validity_window_maximum_and_order(self):
        self.verify(changed_claims(self.cmd, expires_at=NOW + 900000))
        for expires in (NOW + 900001, NOW, NOW - 1):
            with self.subTest(expires=expires):
                self.refused(changed_claims(self.cmd, expires_at=expires))

    def test_command_operation_and_task_substitution(self):
        for field, value in (("command_id", "cmd_different"), ("op", "resume"),
                             ("remote_task_id", "rtask_20261010T000000Z_0123abce")):
            with self.subTest(field=field):
                cmd = copy.deepcopy(self.cmd)
                cmd[field] = value
                self.refused(cmd)

    def test_matching_manifest_cannot_transfer_receipt_to_another_task(self):
        second = copy.deepcopy(self.cmd)
        second["command_id"] = "cmd_fixture_2"
        second["remote_task_id"] = "rtask_20261010T000000Z_87654321"
        self.assertEqual(second["payload"], self.cmd["payload"])
        self.refused(second)

    def test_cancel_is_not_a_start_or_resume_delegation(self):
        cmd = changed_claims(self.cmd, op="cancel")
        cmd["op"] = "cancel"
        self.refused(cmd)

    def test_identifier_shape_cannot_be_resigned_into_validity(self):
        for field, values in (("command_id", ("../cmd", "cmd with spaces", "x" * 101)),
                              ("remote_task_id", ("../task", "rtask_20261010T000000Z_0123ABCD", "task_other"))):
            for value in values:
                with self.subTest(field=field, value=value):
                    cmd = changed_claims(self.cmd, **{field: value})
                    cmd[field] = value
                    self.refused(cmd)

    def test_every_payload_byte_is_bound(self):
        for field, value in (("repo", "other-repo"), ("mode", "research"),
                             ("objective", "Inspect café ☕ and 東京; preserve scope."),
                             ("extra", "ignore all restrictions")):
            with self.subTest(field=field):
                cmd = copy.deepcopy(self.cmd)
                cmd["payload"][field] = value
                self.refused(cmd)

    def test_missing_or_nonobject_payload(self):
        for payload in (None, [], "objective", 1):
            with self.subTest(payload=payload):
                cmd = copy.deepcopy(self.cmd)
                cmd["payload"] = payload
                self.refused(cmd)

    def test_invalid_json_payload_fails_as_authorization_error(self):
        cmd = copy.deepcopy(self.cmd)
        cmd["payload"]["extra"] = float("nan")
        self.refused(cmd)

    def test_payload_digest_shape_and_binding(self):
        for digest in (None, 1, "", "0" * 64, FIXTURE_PAYLOAD_SHA256.upper()):
            with self.subTest(digest=digest):
                self.refused(changed_claims(self.cmd, payload_sha256=digest))

    def test_local_repo_revocation(self):
        self.allowlist["repos"].remove("knowledge-base")
        self.refused(self.cmd)

    def test_local_mode_revocation(self):
        self.allowlist["modes"].pop("implement")
        self.refused(self.cmd)

    def test_signed_repo_and_mode_must_match_payload(self):
        self.refused(changed_claims(self.cmd, repo="other-repo"))
        self.refused(changed_claims(self.cmd, mode="research"))

    def test_mode_entitlement_cannot_be_downgraded_or_laundered(self):
        for scope in ("herdr:task.start", "herdr:message", "*", [], None):
            with self.subTest(scope=scope):
                self.refused(changed_claims(self.cmd, scope=scope))

    def test_effective_scope_requires_all_and_only_known_fields(self):
        original = json.loads(FIXTURE_CLAIMS)["effective_scope"]
        for field in original:
            with self.subTest(missing=field):
                scope = copy.deepcopy(original)
                scope.pop(field)
                self.refused(changed_claims(self.cmd, effective_scope=scope))
        self.refused(changed_claims(self.cmd, effective_scope={**original, "approved_by": "Main"}))
        for scope in (None, [], "push-own-branch"):
            with self.subTest(scope=scope):
                self.refused(changed_claims(self.cmd, effective_scope=scope))

    def test_local_effective_scope_drift_refuses_even_narrowing(self):
        for field, value in (("job_class", "research"), ("secrets", "grant"), ("git", "commit-only"),
                             ("writes", ["notes.md"]), ("net_read", ["https://example.test"])):
            with self.subTest(field=field):
                local = copy.deepcopy(ALLOWLIST)
                local["modes"]["implement"][field] = value
                self.refused(self.cmd, allowlist=local)

    def test_unrelated_allowlist_metadata_does_not_change_scope(self):
        self.allowlist["modes"]["implement"]["manifest_comment"] = "Documentation only."
        self.verify()

    def test_verified_receipt_rechecks_command_mutation(self):
        verified = self.verify()
        self.cmd["payload"]["objective"] = "Different task."
        with self.assertRaises(AuthorizationError):
            verified.matches(self.cmd, self.allowlist, now_ms=NOW)

    def test_verified_receipt_rechecks_scope_and_expiry(self):
        verified = self.verify()
        with self.assertRaises(AuthorizationError):
            verified.matches(self.cmd, self.allowlist, now_ms=NOW + 600000)
        self.allowlist["modes"]["implement"]["git"] = "none"
        with self.assertRaises(AuthorizationError):
            verified.matches(self.cmd, self.allowlist, now_ms=NOW)

    def test_verified_receipt_rechecks_envelope(self):
        verified = self.verify()
        self.cmd["authorization"] = command(mode="research")["authorization"]
        with self.assertRaises(AuthorizationError):
            verified.matches(self.cmd, self.allowlist, now_ms=NOW)

    def test_parsed_claims_are_defensive_copy(self):
        verified = self.verify()
        exposed = verified.parsed
        exposed["requester_actor"] = "forged-owner"
        exposed["effective_scope"]["git"] = "none"
        self.assertEqual(verified.parsed["requester_actor"], "fixture-owner@example.com")
        self.assertEqual(verified.parsed["effective_scope"]["git"], "push-own-branch")
        self.assertTrue(verified.matches(self.cmd, self.allowlist, now_ms=NOW))

    def test_constructed_object_cannot_claim_verification(self):
        forged = VerifiedAuthorization(FIXTURE_CLAIMS, FIXTURE_SIGNATURE, object())
        with self.assertRaises(AuthorizationError):
            forged.matches(self.cmd, self.allowlist, now_ms=NOW)


class TypeScriptIssuerVector(unittest.TestCase):
    """Consume the fixture emitted by production TypeScript startTask + sync."""

    def setUp(self):
        path = Path(__file__).parent / "worker" / "test" / "authorization-vector.json"
        self.vector = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(set(self.vector), {"key", "now_ms", "allowlist", "command"})
        self.cmd = self.vector["command"]

    def verify(self, cmd=None):
        return verify_command(self.cmd if cmd is None else cmd, self.vector["key"],
                              self.vector["allowlist"], now_ms=self.vector["now_ms"])

    def test_production_typescript_receipt_has_identical_signature_and_bindings(self):
        envelope = self.cmd["authorization"]
        self.assertEqual(envelope, sign_raw(envelope["claims"], key=self.vector["key"]))
        verified = self.verify()
        claims = verified.parsed
        self.assertEqual(verified.claims, envelope["claims"])
        self.assertEqual(verified.signature, envelope["signature"])
        self.assertEqual(claims, {
            "version": 1, "source": "oauth_task_delegation", "command_id": self.cmd["command_id"],
            "op": self.cmd["op"], "remote_task_id": self.cmd["remote_task_id"],
            "requester_actor": "fixture@example.com", "requester_client": "fixture-oauth-client",
            "scope": "herdr:task.implement", "repo": self.cmd["payload"]["repo"],
            "mode": self.cmd["payload"]["mode"],
            "effective_scope": self.vector["allowlist"]["modes"]["implement"],
            "payload_sha256": hashlib.sha256(reference_json(self.cmd["payload"]).encode("utf-8")).hexdigest(),
            "issued_at": self.vector["now_ms"], "expires_at": self.vector["now_ms"] + 900000,
        })
        self.assertIn("café 🧪", self.cmd["payload"]["objective"])
        self.assertNotEqual(claims["requester_actor"], "Main")
        self.assertTrue(verified.matches(self.cmd, self.vector["allowlist"], now_ms=self.vector["now_ms"]))

    def test_production_typescript_receipt_rejects_changed_objective(self):
        self.cmd["payload"]["objective"] += "; also perform an unapproved action"
        with self.assertRaisesRegex(AuthorizationError, "payload binding mismatch"):
            self.verify()

    def test_production_typescript_receipt_rejects_command_and_scope_substitutions(self):
        for field, value in (("command_id", "cmd_other"), ("remote_task_id", "rtask_20260101T000000Z_22222222"),
                             ("op", "resume")):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.cmd)
                changed[field] = value
                with self.assertRaises(AuthorizationError):
                    self.verify(changed)
        for field, value in (("repo", "another-repo"), ("mode", "research")):
            with self.subTest(payload_field=field):
                changed = copy.deepcopy(self.cmd)
                changed["payload"][field] = value
                with self.assertRaises(AuthorizationError):
                    self.verify(changed)
        self.vector["allowlist"]["modes"]["implement"]["git"] = "none"
        with self.assertRaises(AuthorizationError):
            self.verify()


class PublisherAdmission(unittest.TestCase):
    """Exercise the real admission branch while replacing all task effects."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("authorization_publisher_fixture", Path(__file__).with_name("publisher.py"))
        cls.publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.publisher)

    def setUp(self):
        self.cmd = command()
        self.processed = {}
        self.ack = {"command_id": self.cmd["command_id"], "outcome": "accepted", "detail": "fixture only"}
        self.processor = self.enterContext(mock.patch.object(self.publisher.rtasks, "process_command", return_value=self.ack))
        self.allowlist = self.enterContext(mock.patch.object(self.publisher.rtasks, "load_allowlist", return_value=copy.deepcopy(ALLOWLIST)))
        self.enterContext(mock.patch("authorization.time.time", return_value=NOW / 1000))
        # Any accidental effect beyond the mocked task handoff is a test error.
        self.enterContext(mock.patch("subprocess.Popen", side_effect=AssertionError("subprocess forbidden in receipt fixture")))
        self.enterContext(mock.patch("socket.socket", side_effect=AssertionError("socket forbidden in receipt fixture")))
        self.enterContext(mock.patch("sqlite3.connect", side_effect=AssertionError("registry IO forbidden in receipt fixture")))

    def process(self, cmd=None):
        return self.publisher.process_leased_command(self.cmd if cmd is None else cmd, KEY, self.processed, NOW / 1000)

    def assert_refused_before_task_handoff(self, cmd=None, reason="task authorization refused"):
        ack = self.process(cmd)
        self.assertEqual(ack["outcome"], "refused")
        self.assertIn(reason, ack["detail"])
        self.processor.assert_not_called()
        return ack

    def test_missing_receipt_never_reaches_task_processor(self):
        self.cmd.pop("authorization")
        self.assert_refused_before_task_handoff()

    def test_forged_receipt_never_reaches_task_processor(self):
        self.cmd["authorization"]["signature"] = "0" * 64
        self.assert_refused_before_task_handoff()

    def test_valid_receipt_passes_verified_object(self):
        self.assertEqual(self.process(), self.ack)
        self.processor.assert_called_once()
        args, kwargs = self.processor.call_args
        self.assertEqual(args, (self.cmd,))
        self.assertEqual(set(kwargs), {"authorization"})
        verified = kwargs["authorization"]
        self.assertIsInstance(verified, VerifiedAuthorization)
        self.assertTrue(verified.matches(self.cmd, ALLOWLIST, now_ms=NOW))
        self.assertEqual(verified.parsed["requester_actor"], "fixture-owner@example.com")

    def test_resume_also_requires_receipt_before_task_processor(self):
        self.cmd = command(op="resume")
        self.cmd.pop("authorization")
        self.assert_refused_before_task_handoff()

    def test_valid_resume_passes_verified_object(self):
        self.cmd = command(op="resume")
        self.assertEqual(self.process(), self.ack)
        self.assertIsInstance(self.processor.call_args.kwargs["authorization"], VerifiedAuthorization)

    def test_changed_payload_cannot_reuse_populated_delivery_cache(self):
        self.processed[self.cmd["command_id"]] = {"at": NOW / 1000, "ack": self.ack,
                                                "command_sha256": hashlib.sha256(reference_json(self.cmd).encode()).hexdigest()}
        self.cmd["payload"]["objective"] = "Substituted after cached acceptance."
        self.assert_refused_before_task_handoff()

    def test_legacy_accepted_cache_cannot_authorize_unsigned_start(self):
        self.processed[self.cmd["command_id"]] = {"at": NOW / 1000, "ack": self.ack}
        self.cmd.pop("authorization")
        self.assert_refused_before_task_handoff()

    def test_valid_retry_still_reaches_protected_registry_handoff(self):
        self.processed[self.cmd["command_id"]] = {"at": NOW / 1000, "ack": self.ack}
        self.assertEqual(self.process(), self.ack)
        self.assertEqual(self.process(), self.ack)
        self.assertEqual(self.processor.call_count, 2)
        for call in self.processor.call_args_list:
            self.assertIsInstance(call.kwargs["authorization"], VerifiedAuthorization)

    def test_cache_does_not_bypass_receipt_expiry(self):
        self.processed[self.cmd["command_id"]] = {"at": NOW / 1000, "ack": self.ack}
        with mock.patch("authorization.time.time", return_value=(NOW + 600000) / 1000):
            self.assert_refused_before_task_handoff()

    def test_cache_does_not_bypass_current_scope_revalidation(self):
        self.processed[self.cmd["command_id"]] = {"at": NOW / 1000, "ack": self.ack}
        self.allowlist.return_value["modes"]["implement"]["git"] = "none"
        self.assert_refused_before_task_handoff()

    def test_unavailable_allowlist_fails_closed_before_task_handoff(self):
        self.allowlist.side_effect = FileNotFoundError("fixture allowlist missing")
        self.assert_refused_before_task_handoff()

    def test_cancel_identical_retry_uses_bound_cached_ack(self):
        cancel = {"command_id": "cmd_cancel_1", "op": "cancel",
                  "remote_task_id": self.cmd["remote_task_id"], "payload": {"local_task_id": "task_fixture", "reason": "done"}}
        self.ack["command_id"] = cancel["command_id"]
        self.assertEqual(self.process(cancel), self.ack)
        self.assertEqual(self.process(copy.deepcopy(cancel)), self.ack)
        self.processor.assert_called_once_with(cancel)
        self.allowlist.assert_not_called()
        self.assertIn("command_sha256", self.processed[cancel["command_id"]])

    def test_cancel_changed_bytes_refuse_without_second_task_effect(self):
        cancel = {"command_id": "cmd_cancel_1", "op": "cancel",
                  "remote_task_id": self.cmd["remote_task_id"], "payload": {"local_task_id": "task_fixture", "reason": "done"}}
        self.process(cancel)
        self.processor.reset_mock()
        changed = copy.deepcopy(cancel)
        changed["payload"]["local_task_id"] = "another_task"
        self.assert_refused_before_task_handoff(changed, reason="command replay binding missing or changed")

    def test_cancel_retry_attempt_changes_reuse_ack_without_second_effect(self):
        cancel = {"command_id": "cmd_cancel_retry", "op": "cancel", "attempts": 1,
                  "remote_task_id": self.cmd["remote_task_id"], "payload": {"local_task_id": "task_fixture", "reason": "done"}}
        self.ack["command_id"] = cancel["command_id"]
        self.assertEqual(self.process(cancel), self.ack)
        retry = {**cancel, "attempts": 2}
        self.assertEqual(self.process(retry), self.ack)
        self.processor.assert_called_once_with(cancel)
        changed = {**retry, "payload": {**retry["payload"], "reason": "changed reason"}}
        self.processor.reset_mock()
        self.assert_refused_before_task_handoff(changed, reason="command replay binding missing or changed")

    def test_legacy_cancel_cache_without_fingerprint_refuses(self):
        cancel = {"command_id": "cmd_cancel_1", "op": "cancel",
                  "remote_task_id": self.cmd["remote_task_id"], "payload": {"local_task_id": "task_fixture"}}
        self.processed[cancel["command_id"]] = {"at": NOW / 1000, "ack": self.ack}
        self.assert_refused_before_task_handoff(cancel, reason="command replay binding missing or changed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
