"""report_md — a Firstmate report (Markdown) as safe, actionable HTML.

A small subset, the one reports use: ATX headings, paragraphs, nested
lists, GFM pipe tables, fenced code, block quotes, rules, and inline code,
bold, italic, links and bare URLs. Mermaid stays code: the page runs no
diagram script. Every character of the source reaches the page through
html.escape; the only markup is what this module writes. A link leaves the
page only for http(s); `#frag` stays inside the report; anything else is
shown as its text.

Tables come out ready for the dashboard script to sort and filter: a
column with a short, repeating vocabulary (a severity, a repo, yes/no)
gets a facet menu, and every row carries a one-line reference
(`<report>#<section> — cell | cell | ...`) its copy button puts on the
clipboard. The section headed "Captain calls" (or "Captain call",
"Captain-call inventory", ...) is split out so the page can pin it on top.
"""
from __future__ import annotations

import html
import re

CALLS_HEADING = re.compile(r"^captain(?:[- ]calls?\b| inventory\b)", re.I)
# A facet is a column whose cells (comma-separated) draw on 2..FACET_MAX
# short values, some repeating; at most FACETS_PER_TABLE per table.
FACET_MAX = 40
FACET_VALUE_MAX = 32
FACET_MIN_ROWS = 4
FACETS_PER_TABLE = 3
MAX_NEST = 16

# Every pattern here stays linear on a hostile line: no two adjacent
# quantifiers can trade the same characters (a report is up to 512 KB, and a
# backtracking regex holds the GIL, so it would stall every page and the API).
_FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^\s{0,3}(#{1,6})[ \t]+(.+)$")
_HR = re.compile(r"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$")
_QUOTE = re.compile(r"^\s{0,3}>\s?(.*)$")
_ITEM = re.compile(r"^(\s*)([-*+]|\d{1,9}[.)])(\s+)(.*)$")
_DELIM_CELL = re.compile(r":?-+:?")
_ESCAPABLE = r"[\\`*_{}\[\]()#+\-.!|>~]"
# Code spans are cut out first (see _code_spans) and stand in the text as
# \uE000<n>\uE001, which no URL pattern below may swallow.
_PH = re.compile("\uE000(\\d+)\uE001")
_INLINE = re.compile(
    rf"\\(?P<esc>{_ESCAPABLE})"
    r"|\[(?P<ltext>[^\[\]\n]+)\]\((?P<lurl>[^)\s\uE000\uE001]+)\)"
    r"|(?P<url>https?://[^\s<>()\[\]`|\"'*\uE000\uE001]+)"
    r"|\*\*(?P<b>(?:(?!\*\*)[\s\S])+?)\*\*"
    r"|(?<![\w*])\*(?P<i>[^\s*](?:[^*\n]*?[^\s*])?)\*(?![\w*])")
# Characters a pasted reference must not carry: C0/C1 controls (a terminal
# reads ESC sequences, e.g. the end of a bracketed paste) and bidi overrides.
_CONTROLS = re.compile(r"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")
_URL_TAIL = ".,;:!?"


def esc(s: str) -> str:
    return html.escape(s, quote=True)


# ── inline ────────────────────────────────────────────────────────────────────
def _frag(f: str) -> str:
    return re.sub(r"[^\w-]", "", f)


def _link(text: str, url: str, links: bool) -> str:
    inner = _inline(text, links=False)
    if not links:
        return inner
    if url.startswith(("https://", "http://")):
        return f"<a href='{esc(url)}' rel=noreferrer>{inner}</a>"
    if url.startswith("#") and _frag(url[1:]):
        return f"<a href='#r-{esc(_frag(url[1:]))}'>{inner}</a>"
    return inner


def _code_spans(s: str) -> tuple[str, list[str]]:
    """`s` with each code span replaced by a placeholder, and the spans' text.

    A run of N backticks opens a span that the next run of exactly N closes
    (a backslash escapes an opener's first backtick, never a closer). Runs are
    paired in one pass with a forward pointer per run length, so it is linear
    however many unmatched runs a line holds."""
    s = s.replace("\uE000", "\uFFFD").replace("\uE001", "\uFFFD")
    runs = []  # (start, end, opener start)
    for m in re.finditer(r"`+", s):
        a, b = m.span()
        k = a
        while k and s[k - 1] == "\\":
            k -= 1
        runs.append((a, b, a + (a - k) % 2))
    closers: dict[int, list[int]] = {}
    for k, (a, b, _) in enumerate(runs):
        closers.setdefault(b - a, []).append(k)
    ptr = dict.fromkeys(closers, 0)
    out, codes, pos, k = [], [], 0, 0
    while k < len(runs):
        a, b, o = runs[k]
        lst, p = closers.get(b - o), ptr.get(b - o, 0)
        while lst and p < len(lst) and lst[p] <= k:
            p += 1
        if not lst or p == len(lst):
            if lst:
                ptr[b - o] = p
            k += 1
            continue
        ptr[b - o] = p
        c = lst[p]
        out += [s[pos:o], f"\uE000{len(codes)}\uE001"]
        codes.append(s[b:runs[c][0]])
        pos, k = runs[c][1], c + 1
    out.append(s[pos:])
    return "".join(out), codes


def _code_html(code: str) -> str:
    if len(code) > 1 and code[0] == " " and code[-1] == " " and code.strip():
        code = code[1:-1]
    return f"<code>{esc(code)}</code>"


def _inline(s: str, links: bool) -> str:
    out, pos = [], 0
    for m in _INLINE.finditer(s):
        out.append(esc(s[pos:m.start()]))
        pos = m.end()
        if m["esc"] is not None:
            out.append(esc(m["esc"]))
        elif m["ltext"] is not None:
            out.append(_link(m["ltext"], m["lurl"], links))
        elif m["url"]:
            url = m["url"].rstrip(_URL_TAIL)
            out.append(f"<a href='{esc(url)}' rel=noreferrer>{esc(url)}</a>" if links else esc(url))
            out.append(esc(m["url"][len(url):]))
        elif m["b"] is not None:
            out.append(f"<strong>{_inline(m['b'], links)}</strong>")
        else:
            out.append(f"<em>{_inline(m['i'], links)}</em>")
    out.append(esc(s[pos:]))
    return "".join(out)


def inline(s: str, links: bool = True) -> str:
    s, codes = _code_spans(s)
    out = _inline(s, links)
    return _PH.sub(lambda m: _code_html(codes[int(m[1])]), out) if codes else out


def plain(s: str) -> str:
    """Inline Markdown as one line of text: what a reference, a facet or a slug reads."""
    s, codes = _code_spans(s)
    s = re.sub(r"\[([^\[\]\n]+)\]\(([^)\s\uE000\uE001]+)\)",
               lambda m: f"{m[1]} ({m[2]})" if m[2].startswith(("https://", "http://")) else m[1], s)
    s = re.sub(rf"\\({_ESCAPABLE})", r"\1", s.replace("**", ""))
    s = re.sub(r"(?<![\w*])\*([^\s*](?:[^*\n]*?[^\s*])?)\*(?![\w*])", r"\1", s)
    s = _PH.sub(lambda m: codes[int(m[1])].strip(), s)
    return " ".join(_CONTROLS.sub(" ", s).split())


def slug(text: str) -> str:
    """GitHub's heading anchor, so a report's own `#links` land."""
    return re.sub(r"[^\w\- ]", "", plain(text).lower()).replace(" ", "-")


def _natural(v: str):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", v)]


# ── blocks ────────────────────────────────────────────────────────────────────
class _Doc:
    def __init__(self, ref_base: str):
        self.ref_base = ref_base
        self.ids: dict[str, int] = {}
        self.section = ("", "")
        self.tables = 0

    def uid(self, base: str) -> str:
        base = base or "section"
        n = self.ids.get(base, 0)
        self.ids[base] = n + 1
        return base if n == 0 else f"{base}-{n}"


def _lead(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _fence(line: str) -> tuple[int, str, str] | None:
    """(indent, fence, language) of a fence line; a backtick fence's info string has no backtick."""
    m = _FENCE.match(line)
    if not m or (m[2][0] == "`" and "`" in m[3]):
        return None
    return len(m[1]), m[2], (m[3].split() or [""])[0].lower()


def _heading(line: str) -> tuple[int, str] | None:
    """(level, text) of an ATX heading, its closing #s dropped."""
    m = _HEADING.match(line)
    if not m:
        return None
    text = m[2].rstrip()
    bare = text.rstrip("#")
    if bare != text and (not bare or bare[-1] in " \t"):
        text = bare.rstrip()
    return (len(m[1]), text) if text else None


def _table_start(lines: list[str], i: int) -> bool:
    return ("|" in lines[i] and i + 1 < len(lines) and "|" in lines[i + 1]
            and all(_DELIM_CELL.fullmatch(c) for c in _cells(lines[i + 1])))


def _starts_block(lines: list[str], i: int) -> bool:
    ln = lines[i]
    return bool(_fence(ln) or _heading(ln) or _HR.match(ln) or _QUOTE.match(ln)
                or _ITEM.match(ln) or _table_start(lines, i))


def _closer(fence: str) -> re.Pattern:
    return re.compile(rf"^\s*{re.escape(fence[0])}{{{len(fence)},}}\s*$")


def _cells(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [p.strip().replace("\\|", "|") for p in re.split(r"(?<!\\)\|", s)]


def _code(text: str, lang: str) -> str:
    if lang == "mermaid":
        return ("<figure class=fm-mermaid><figcaption>Mermaid diagram, shown as its source "
                f"(this page draws no diagrams)</figcaption><pre><code>{esc(text)}</code></pre></figure>")
    data = f" data-lang='{esc(lang)}'" if lang else ""
    return f"<pre class=fm-code{data}><code>{esc(text)}</code></pre>"


def _split(cell: str) -> list[str]:
    return [v.strip() for v in cell.split(",") if v.strip()]


def _facets(head: list[str], ptext: list[list[str]]) -> list[tuple[int, list[str], list[list[str]]]]:
    out = []
    if len(ptext) < FACET_MIN_ROWS:
        return out
    for c in range(len(head)):
        vals = [_split(r[c]) for r in ptext]
        flat = [v for vs in vals for v in vs]
        distinct = sorted(set(flat), key=_natural)
        if not flat or any(len(v) > FACET_VALUE_MAX for v in flat):
            continue
        if 2 <= len(distinct) <= FACET_MAX and len(distinct) < len(ptext):
            out.append((c, distinct, vals))
            if len(out) == FACETS_PER_TABLE:
                break
    return out


def row_ref(base: str, cells: list[str]) -> str:
    """One line naming a table row: `<report>#<section> — cell | cell | ...`."""
    return f"{base} — " + " | ".join(c or "—" for c in cells)


def _table(head: list[str], rows: list[list[str]], doc: _Doc) -> str:
    k = len(head)
    rows = [(r + [""] * k)[:k] for r in rows]
    doc.tables += 1
    tid = f"rt-{doc.tables}"
    sec_id, sec_text = doc.section
    base = f"{doc.ref_base}#{sec_id}" if sec_id else doc.ref_base
    labels = [plain(h) for h in head]
    ptext = [[plain(c) for c in r] for r in rows]
    facets = _facets(head, ptext)
    menus = "".join(
        f"<label>{esc(labels[c] or f'Column {c + 1}')} <select data-col={c} aria-controls={tid}>"
        "<option value=''>all</option>"
        + "".join(f"<option value='{esc(v)}'>{esc(v)} ({sum(1 for vs in vals if v in vs)})</option>" for v in distinct)
        + "</select></label>"
        for c, distinct, vals in facets)
    n = len(rows)
    bar = (f"<div class='fm-tbar fm-js'>{menus}<span class=fm-tn aria-live=polite>"
           f"{n} {'row' if n == 1 else 'rows'}</span></div>")
    ths = "".join(f"<th scope=col><button type=button class=fm-sort>{inline(h, links=False)}</button></th>" for h in head)
    body = []
    for i, (r, p) in enumerate(zip(rows, ptext)):
        fattr = "".join(f" data-f{c}='{esc(chr(10).join(vals[i]))}'" for c, _, vals in facets)
        # A short single token (an ID, a severity, a date) never breaks at its hyphens.
        tds = "".join(f"<td data-label='{esc(labels[c])}'{' class=fm-nw' if len(p[c]) <= 16 and ' ' not in p[c] else ''}>"
                      f"{inline(cell)}</td>" for c, cell in enumerate(r))
        body.append(f"<tr data-i={i}{fattr}>{tds}<td class=fm-cpc><button type=button class='fm-cp fm-js' "
                    f"data-ref='{esc(row_ref(base, p))}' title='Copy this row as a one-line reference'>copy</button></td></tr>")
    where = f" in {sec_text}" if sec_text else ""
    return (f"<div class=fm-mdt data-table={tid}>{bar}<div class=fm-tscroll><table id={tid} "
            f"aria-label='Table {doc.tables}{esc(where)}'><thead><tr>{ths}"
            "<th class=fm-cpc><span class=sr-only>Copy reference</span></th></tr></thead>"
            f"<tbody>{''.join(body)}</tbody></table></div></div>")


def _list(lines: list[str], i: int, doc: _Doc, depth: int) -> tuple[dict, int]:
    m = _ITEM.match(lines[i])
    ind, ordered, n = len(m[1]), m[2][0].isdigit(), len(lines)
    items: list[tuple[int | None, list[str]]] = []
    while i < n:
        m = _ITEM.match(lines[i])
        if not m or len(m[1]) != ind or m[2][0].isdigit() != ordered:
            break
        width = len(m[1]) + len(m[2]) + len(m[3])
        body = [m[4]]
        i += 1
        while i < n:
            ln = lines[i]
            if not ln.strip():
                j = i + 1
                while j < n and not lines[j].strip():
                    j += 1
                if j < n and _lead(lines[j]) > ind:
                    body.extend([""] * (j - i))
                    i = j
                    continue
                break
            lead = _lead(ln)
            if lead > ind:
                body.append(ln[min(lead, width):])
            elif _starts_block(lines, i):
                break
            else:
                body.append(ln.strip())
            i += 1
        items.append((int(m[2][:-1]) if ordered else None, body))
        j = i
        while j < n and not lines[j].strip():
            j += 1
        nxt = _ITEM.match(lines[j]) if j < n else None
        if not (nxt and len(nxt[1]) == ind and nxt[2][0].isdigit() == ordered):
            break
        i = j
    lis = []
    for num, body in items:
        blocks = _blocks(body, doc, depth + 1)
        first = blocks.pop(0)["inner"] if blocks and blocks[0]["t"] == "p" else ""
        lis.append(f"<li{f' value={num}' if num is not None else ''}>{first}{''.join(b['html'] for b in blocks)}</li>")
    tag = "ol" if ordered else "ul"
    return {"t": "list", "items": len(items), "html": f"<{tag}>{''.join(lis)}</{tag}>"}, i


def _blocks(lines: list[str], doc: _Doc, depth: int = 0) -> list[dict]:
    if depth > MAX_NEST:  # "- - - - …" or "> > > …" nests once per marker; past this it is text
        inner = inline("\n".join(ln.strip() for ln in lines if ln.strip()))
        return [{"t": "p", "inner": inner, "html": f"<p>{inner}</p>"}] if inner else []
    out: list[dict] = []
    i, n = 0, len(lines)
    while i < n:
        ln = lines[i]
        if not ln.strip():
            i += 1
            continue
        f = _fence(ln)
        if f:
            ind, fence, lang = f
            close = _closer(fence)
            body = []
            i += 1
            while i < n and not close.match(lines[i]):
                body.append(lines[i][min(ind, _lead(lines[i])):])
                i += 1
            i += 1
            out.append({"t": "code", "html": _code("\n".join(body), lang)})
            continue
        h = _heading(ln)
        if h:
            level, text = h
            hid = doc.uid(slug(text))
            doc.section = (hid, plain(text))
            out.append({"t": "h", "level": level, "text": plain(text), "id": hid,
                        "html": f"<h{level} id='r-{esc(hid)}'>{inline(text)}</h{level}>"})
            i += 1
            continue
        if _HR.match(ln):
            out.append({"t": "hr", "html": "<hr>"})
            i += 1
            continue
        if _QUOTE.match(ln):
            body = []
            while i < n and lines[i].strip() and _QUOTE.match(lines[i]):
                body.append(_QUOTE.match(lines[i])[1])
                i += 1
            out.append({"t": "quote", "html": f"<blockquote>{''.join(b['html'] for b in _blocks(body, doc, depth + 1))}</blockquote>"})
            continue
        if _table_start(lines, i):
            head, rows = _cells(ln), []
            i += 2
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(_cells(lines[i]))
                i += 1
            out.append({"t": "table", "html": _table(head, rows, doc)})
            continue
        if _ITEM.match(ln):
            block, i = _list(lines, i, doc, depth)
            out.append(block)
            continue
        para = [ln.strip()]
        i += 1
        while i < n and lines[i].strip() and not _starts_block(lines, i):
            para.append(lines[i].strip())
            i += 1
        inner = inline("\n".join(para))
        out.append({"t": "p", "inner": inner, "html": f"<p>{inner}</p>"})
    return out


# ── the document ──────────────────────────────────────────────────────────────
def render(text: str, ref_base: str) -> dict:
    """{"title": str, "title_html": str, "toc": [(id, text)], "calls": None | {"id", "title", "count", "html"},
    "body": str}. `ref_base` (the report's data/ path) starts every row reference."""
    doc = _Doc(ref_base)
    blocks = _blocks(text.replace("\r\n", "\n").split("\n"), doc)
    title = title_html = ""
    first = next((k for k, b in enumerate(blocks) if b["t"] == "h"), None)
    if first is not None and blocks[first]["level"] == 1:
        h = blocks.pop(first)
        title, title_html = h["text"], h["html"]
    toc = [(b["id"], b["text"]) for b in blocks if b["t"] == "h" and b["level"] == 2]
    calls = None
    at = next((k for k, b in enumerate(blocks) if b["t"] == "h" and CALLS_HEADING.match(b["text"])), None)
    if at is not None:
        level = blocks[at]["level"]
        end = next((k for k in range(at + 1, len(blocks)) if blocks[k]["t"] == "h" and blocks[k]["level"] <= level), len(blocks))
        section, blocks = blocks[at:end], blocks[:at] + blocks[end:]
        first_list = next((b for b in section[1:] if b["t"] == "list"), None)
        calls = {"id": section[0]["id"], "title": section[0]["text"], "count": first_list["items"] if first_list else None,
                 "html": "".join(b["html"] for b in section[1:])}
    return {"title": title, "title_html": title_html, "toc": toc, "calls": calls,
            "body": "".join(b["html"] for b in blocks)}


def headline(text: str) -> tuple[str, bool]:
    """(the title render() would draw, whether a captain-calls section exists), without rendering."""
    title, calls, close, seen = "", False, None, False
    for ln in text.split("\n"):
        if close:
            if close.match(ln):
                close = None
            continue
        f = _fence(ln)
        if f:
            close = _closer(f[1])
            continue
        h = _heading(ln)
        if h:
            if not seen and h[0] == 1:
                title = plain(h[1])
            seen = True
            calls = calls or bool(CALLS_HEADING.match(plain(h[1])))
            if calls:
                break
    return title, calls
