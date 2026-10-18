"""form_schema.py — derive a required-field schema from a form's own HTML, and
validate a submitted payload against it.

Incident, 2026-10-18: pilot form 20261018T071004-8741's radio was named
`pilot` but the copied template's script sent `choice`. The saved answer was
{choice:null, confirmed:false, notes:""} and the row still flipped to
`answered` — nothing checked that the thing the human actually picked made it
into the payload. Both submit paths (formserve's own /submit and the hub's
/decisions/<id>/submit) now call `validate_answers` with the schema this
module derived from the SAME html.parser pass, so neither surface can drift
from what the page actually declares as required.

The schema is derived once, at serve/registration time, from the form's
`required` attributes — never asserted by the page's own script, which is
exactly the thing that lied in the incident. stdlib html.parser only, no new
dependency.
"""
from __future__ import annotations

from html.parser import HTMLParser


class _SchemaParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        # name -> {"required": bool, "enum": set[str] | None}
        self.fields: dict[str, dict] = {}
        self._select_name: str | None = None

    def _field(self, name: str, has_enum: bool) -> dict:
        return self.fields.setdefault(name, {"required": False, "enum": set() if has_enum else None})

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        d = {k: v for k, v in attrs}
        if tag == "input":
            name = d.get("name")
            if not name:
                return
            itype = (d.get("type") or "text").lower()
            f = self._field(name, has_enum=(itype == "radio"))
            if itype == "radio":
                if f["enum"] is None:
                    f["enum"] = set()
                if "value" in d and d["value"] is not None:
                    f["enum"].add(d["value"])
            if "required" in d:
                f["required"] = True
        elif tag == "select":
            name = d.get("name")
            if not name:
                return
            self._select_name = name
            f = self._field(name, has_enum=True)
            if f["enum"] is None:
                f["enum"] = set()
            if "required" in d:
                f["required"] = True
        elif tag == "option":
            if self._select_name and "value" in d and d["value"] is not None:
                self.fields[self._select_name]["enum"].add(d["value"])
        elif tag == "textarea":
            name = d.get("name")
            if not name:
                return
            f = self._field(name, has_enum=False)
            if "required" in d:
                f["required"] = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "select":
            self._select_name = None


def parse_schema(raw_html: str) -> dict:
    """Required fields only: {name: {"enum": [v, ...]} | {}}.

    A field without `required` anywhere never appears here — a form with no
    required fields derives an empty schema, which `validate_answers` treats
    as a no-op (point 5 of the contract: unchanged behaviour for every
    existing form that never declared one)."""
    p = _SchemaParser()
    p.feed(raw_html)
    out: dict = {}
    for name, f in p.fields.items():
        if not f["required"]:
            continue
        out[name] = {"enum": sorted(f["enum"])} if f["enum"] else {}
    return out


def validate_answers(schema: dict | None, payload: dict) -> str | None:
    """None if `payload` satisfies `schema`, else "<field>: <reason>".

    Covers exactly the incident shape and its neighbours: missing key, null,
    empty string, and a value outside the declared enum (radio/select)."""
    if not schema:
        return None
    for name, spec in schema.items():
        if name not in payload:
            return f"{name}: required field missing"
        val = payload[name]
        if val is None or val == "":
            return f"{name}: required field missing"
        enum = spec.get("enum")
        if enum and val not in enum:
            return f"{name}: value {val!r} is not one of {enum}"
    return None
