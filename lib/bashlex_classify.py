#!/usr/bin/env python3
"""bashlex_classify.py — SPEC #264 round 3's parser-based escalation gate.

Reads ONE raw shell command on stdin (exactly as the pane sent it — no
pre-stripping; `lib/command-policy.sh`'s `_cp_bashlex_findgit_present` is
the only caller). Parses it with bashlex (a Python port of bash's own
grammar) and walks the whole AST — pipelines, lists, compound commands
(`if`/`while`/`for`/`{ }`/`( )`), command and process substitutions, and
function bodies — looking at every SIMPLE command's resolved command word
(and, through a launcher chain such as `nice`/`env`/`sudo`, the word after
it — see `_CP_LAUNCHER_NAMES`, read from the one list this repeats instead
of re-enumerating, via the `CP_LAUNCHER_NAMES` env var).

Spelling detection (matching text ANYWHERE, position-independent) cannot
win against line continuations, quote splices, extglob and empty-expansion
splices — see `~/.herdr/worktrees/herdr-control/review/pr-264-r2/.handoffs/
REVIEW.md` M1-M4. A real parser resolves bash's OWN lexical rules (it
deletes a backslash-newline and removes quotes exactly where bash does)
so the four classes collapse to two checks instead of four spelling rules:

  1. Is the resolved command word (or, through a launcher, the word after
     it) something bash itself could not resolve statically — an
     expansion/substitution part, a glob character, or a byte outside
     `[A-Za-z0-9._/+-]`? If so: ESCALATE. Extglob (`@(g)it`) and `$9`/`$@`/
     backtick/`$()` splices both land here — extglob fails to PARSE at all
     (bashlex has no extglob support, same as a genuine syntax error: SPEC
     step 2, "parse error -> escalate"), and every empty-expansion splice
     leaves a non-empty `.parts` list on its word node.
  2. If that resolved word's basename IS plainly find/git/fd (case-
     insensitive; `git-<verb>` counts as git too), print the simple
     command's OWN resolved, properly quoted argv (so bash's EXISTING
     find/git-specific rules — `_cp_git_seg_exec_unsafe`, called by the
     caller on each printed line — can judge it exactly as if it had been
     spelled plainly in the first place; this file holds none of that
     judgement itself, so there is no second find/git rule to keep in
     sync with the first).

Output grammar (one line per verdict; the caller reads ALL of them):
  `ESCALATE <reason>`   — fail closed (parse error/timeout/unreadable word)
  `CHECK <quoted argv>` — hand this resolved segment to the existing
                          find/git classification; union the result
  `ALLOW`               — printed alone when nothing above fired

Any OTHER output, a non-zero exit, or no output at all means the caller
treats this process as broken and fails closed — this file does not get a
second chance to loosen a verdict by crashing quietly.
"""
import os
import re
import shlex
import signal
import sys

TIMEOUT_SECONDS = 2
_PLAIN_RE = re.compile(r'^[A-Za-z0-9._/+-]+$')
_ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
_FINDGIT_RE = re.compile(r'^(find|fd|git|git-.+)$', re.IGNORECASE)
_MAX_LAUNCHER_CHAIN = 16
_WORD_BOUNDARY_CHARS = set(' \t\n;&|()<>')
_NAME_EQ_PAREN_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=\(')

_escalated = []
_checks = []
_PLACEHOLDER_SPANS = []


class _Timeout(Exception):
    pass


def _on_alarm(_signum, _frame):
    raise _Timeout()


def _escalate(reason):
    _escalated.append(reason)


def _at_word_start(s, i):
    return i == 0 or s[i - 1] in _WORD_BOUNDARY_CHARS


def _unquote_heredoc_delimiters(text):
    """bashlex cannot parse a heredoc whose delimiter is quoted/escaped at
    all (`<<'EOF'`, `<<"EOF"`, `<<\\EOF`, `<<-'EOF'` ...) — `ParsingError`
    every time, confirmed by direct probe — even though a quoted
    delimiter (suppress body expansion) is one of the most common heredoc
    idioms in real shell. Rewrite the delimiter to its unquoted,
    quote-removed form before parsing. This is CONSERVATIVE, never a
    loosening: bashlex then treats the body as subject to substitution
    and walks any `$(...)`/backtick/`$VAR` it finds there exactly like a
    real unquoted heredoc's body, i.e. it can only see MORE potential
    commands than real bash would actually run under the original quoted
    delimiter (which never expands the body at all), never fewer —
    nothing in the body becomes less visible to the walker. The closing
    delimiter line is always bare, unquoted text in both bash and this
    rewrite, so quote-removing only the OPENING token does not change
    which line bashlex matches the heredoc's end against; a delimiter
    that does not actually appear as its own line before true
    end-of-input still fails bashlex's own heredoc lexer exactly as it
    does today (`ParsingError: ... delimited by end-of-file`), so a
    mismatched delimiter still fails closed with no extra code here."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text[i:i + 2] == '<<' and text[i:i + 3] != '<<<':
            start = i
            j = i + 2
            if j < n and text[j] == '-':
                j += 1
            k = j
            while k < n and text[k] in ' \t':
                k += 1
            word_start = k
            delim_chars = []
            was_quoted = False
            while k < n:
                c = text[k]
                if c in ' \t\n':
                    break
                if c == "'":
                    was_quoted = True
                    k += 1
                    while k < n and text[k] != "'":
                        delim_chars.append(text[k])
                        k += 1
                    k += 1
                    continue
                if c == '"':
                    was_quoted = True
                    k += 1
                    while k < n and text[k] != '"':
                        if text[k] == '\\' and k + 1 < n and text[k + 1] in '"\\$`':
                            delim_chars.append(text[k + 1])
                            k += 2
                            continue
                        delim_chars.append(text[k])
                        k += 1
                    k += 1
                    continue
                if c == '\\':
                    was_quoted = True
                    k += 1
                    if k < n:
                        delim_chars.append(text[k])
                        k += 1
                    continue
                delim_chars.append(c)
                k += 1
            if was_quoted and delim_chars:
                out.append(text[start:word_start])
                out.append(''.join(delim_chars))
                i = k
                continue
        out.append(text[i])
        i += 1
    return ''.join(out)


def _preprocess_inert_placeholders(raw):
    """Main's round-3 diagnosis (vcp 9/1733 FAIL): bashlex does not
    implement arithmetic EXPANSION (`$((...))`: `NotImplementedError`) or
    compound ARRAY assignment (`name=(a b)`: `ParsingError`) — both
    ordinary, harmless bash this policy must not escalate every use of.
    Rewrite each occurrence to an inert placeholder BEFORE parsing, but
    ONLY when its own inner content carries none of `$`/backtick/a quote
    (array assignment ALSO excludes a literal paren, since that can only
    mean a nested, unresolved construct) — `a[$(id)]` (an arithmetic
    SUBSCRIPT that runs a command) and `arr=($(cmd))` both keep every
    forbidden byte, so substitution is skipped for them and the ORIGINAL
    text reaches bashlex, which still fails to parse it: SPEC step 2's
    fail-closed path, unchanged. Returns `(rewritten_text,
    placeholder_spans)` — the spans are checked by `_is_plain_literal`
    against `pos()` in the REWRITTEN text's own coordinates (what bashlex
    reports `.pos` against, since `main()` parses `rewritten_text`, never
    `raw`), so a placeholder landing in COMMAND-WORD position still
    escalates — it stands for text this file could not resolve statically,
    not a literal."""
    out = []
    spans = []
    i = 0
    n = len(raw)
    while i < n:
        if raw.startswith('$((', i):
            depth = 2
            j = i + 3
            while j < n and depth > 0:
                if raw[j] == '(':
                    depth += 1
                elif raw[j] == ')':
                    depth -= 1
                j += 1
            if depth == 0:
                inside = raw[i + 3:j - 2]
                if not any(c in inside for c in '$`\'"'):
                    start = len(''.join(out))
                    out.append('0')
                    spans.append((start, start + 1))
                    i = j
                    continue
        elif _at_word_start(raw, i):
            m = _NAME_EQ_PAREN_RE.match(raw, i)
            if m:
                open_idx = m.end() - 1
                depth = 1
                k = open_idx + 1
                while k < n and depth > 0:
                    if raw[k] == '(':
                        depth += 1
                    elif raw[k] == ')':
                        depth -= 1
                    k += 1
                if depth == 0:
                    inside = raw[open_idx + 1:k - 1]
                    if not any(c in inside for c in '$`\'"()'):
                        repl = m.group(1) + '=ARR'
                        start = len(''.join(out))
                        out.append(repl)
                        spans.append((start, start + len(repl)))
                        i = k
                        continue
        out.append(raw[i])
        i += 1
    return ''.join(out), spans


def _overlaps_placeholder(pos):
    if not pos:
        return False
    start, end = pos
    for s, e in _PLACEHOLDER_SPANS:
        if start < e and s < end:
            return True
    return False


def _is_plain_literal(word_node):
    if word_node.parts:
        return False
    if _overlaps_placeholder(word_node.pos):
        return False
    return bool(_PLAIN_RE.match(word_node.word))


def _launcher_names():
    raw = os.environ.get("CP_LAUNCHER_NAMES", "")
    return set(n for n in raw.split() if n)



def _handle_command(node, launcher_names):
    # `node.parts` holds every assignment/redirect/word in SOURCE order.
    # Drop redirects outright (irrelevant to the command word); collect the
    # rest in order. A word that bashlex did not tag `assignment` (observed
    # when a redirect precedes it, e.g. `<<< x X=1 git status` — a bashlex
    # quirk, not a bash one: real bash still treats `X=1` as an assignment
    # there) is re-checked by SHAPE (`NAME=value`) below, not by node kind
    # alone, so that quirk cannot smuggle an assignment through as if it
    # were the command word.
    words = []
    for p in node.parts:
        if p.kind in ("redirect",):
            continue
        if p.kind in ("assignment",):
            continue
        if p.kind == "word":
            words.append(p)
    # Drop a LEADING run of assignment-shaped words (bash grammar: an
    # assignment is only ever a PREFIX of a simple command — anything
    # assignment-shaped later is a real argument, e.g. `git config a=b`).
    idx = 0
    while idx < len(words) and _ASSIGN_RE.match(words[idx].word):
        idx += 1
    if idx >= len(words):
        return  # nothing but assignments/redirects in this simple command

    chain = 0
    while True:
        w = words[idx]
        if not _is_plain_literal(w):
            _escalate(
                "command word is not a plain literal (expansion, glob, or "
                "unreadable byte): %r" % (w.word,)
            )
            return
        basename = os.path.basename(w.word).lower()
        if basename in launcher_names and idx + 1 < len(words):
            if chain >= _MAX_LAUNCHER_CHAIN:
                _escalate("launcher chain longer than %d words" % _MAX_LAUNCHER_CHAIN)
                return
            idx += 1
            chain += 1
            continue
        break

    resolved = words[idx]
    basename = os.path.basename(resolved.word).lower()
    if not _FINDGIT_RE.match(basename):
        return

    # Reconstruct this simple command's resolved argv from `resolved`
    # onward, PLUS any leading GIT_*/PAGER/EDITOR/VISUAL assignment this
    # segment carried (the launcher chain above intentionally does not
    # re-walk assignments the way `_cp_locate_command_word` does — keeping
    # ALL of them here, not just the exec-var ones, is simpler and strictly
    # safer: an extra inert token on the reconstructed line costs nothing,
    # `_cp_protect_text`/`_cp_git_seg_exec_unsafe` already parses it back
    # out the same way the real segment would have carried it).
    tail = [words[j].word for j in range(0, idx) if _ASSIGN_RE.match(words[j].word)]
    tail += [t.word for t in words[idx:]]
    quoted = " ".join(shlex.quote(t) for t in tail)
    _checks.append(quoted)


def _walk(node, launcher_names):
    if node.kind == "command":
        _handle_command(node, launcher_names)
    # Generic recursion: every bashlex node exposes its children only
    # through python-list-valued or single-node-valued attributes (`parts`,
    # `list`, `redirects`, `command`, `name`, `body`, ...) — walking every
    # attribute generically, rather than naming each node kind's children
    # one at a time, is what makes this cover pipelines, lists, compound
    # commands (`if`/`while`/`for`/`{ }`/`( )`), command/process
    # substitutions AND function bodies in one pass: SPEC step 3.
    for attr, val in vars(node).items():
        if attr in ("kind", "pos", "s", "word", "op", "pipe", "type"):
            continue
        if isinstance(val, list):
            for item in val:
                if hasattr(item, "kind"):
                    _walk(item, launcher_names)
        elif hasattr(val, "kind"):
            _walk(val, launcher_names)


def main():
    raw = sys.stdin.read()
    # A heredoc whose closing delimiter is the LAST line of input with no
    # trailing newline (e.g. `printf 'node <<EOF\n...\nEOF'`, no final
    # `\n`) is valid, complete bash — but Main's round-3 run found bashlex's
    # heredoc lexer requires the delimiter line itself to be
    # newline-terminated to recognize it as closed. Appending a trailing
    # newline when one is missing never changes what real bash reads from a
    # command string (the shell does not require one either), so this is
    # unconditional and safe, not gated like the two substitutions below.
    if raw and not raw.endswith("\n"):
        raw += "\n"
    raw = _unquote_heredoc_delimiters(raw)
    rewritten, placeholder_spans = _preprocess_inert_placeholders(raw)
    _PLACEHOLDER_SPANS[:] = placeholder_spans
    launcher_names = _launcher_names()

    old_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(TIMEOUT_SECONDS)
    try:
        import bashlex  # imported here so an import failure is also "parse error"
        try:
            trees = bashlex.parse(rewritten)
        except _Timeout:
            raise
        except Exception as exc:  # noqa: BLE001 — bashlex raises several types
            # (ParsingError on a genuine syntax error OR anything this
            # grammar never implemented at all, e.g. `case`/extglob;
            # NotImplementedError for some of the latter directly) — ALL of
            # them mean "this file could not prove the command safe",
            # which is exactly the fail-closed case SPEC step 2 asks for.
            print("ESCALATE parse error: %s: %s" % (type(exc).__name__, exc))
            return 0
    except _Timeout:
        print("ESCALATE parser timed out after %ss" % TIMEOUT_SECONDS)
        return 0
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

    try:
        for tree in trees:
            _walk(tree, launcher_names)
    except RecursionError:
        print("ESCALATE AST too deeply nested to walk safely")
        return 0
    except Exception as exc:  # noqa: BLE001 — a walker bug must fail closed too
        print("ESCALATE walker error: %s: %s" % (type(exc).__name__, exc))
        return 0

    if _escalated:
        for reason in _escalated:
            print("ESCALATE %s" % reason)
        return 0
    if _checks:
        for seg in _checks:
            print("CHECK %s" % seg)
        return 0
    print("ALLOW")
    return 0


if __name__ == "__main__":
    sys.exit(main())
