#!/usr/bin/env python3
"""bashlex_nested_classify.py — fix/shell-nested-allowlist-r2f.

Replaces the DENYLIST classifier (SPEC round r1/r2b/r2c: "NESTED if this
specific interpreter-shaped word/flag/kind appears") with an ALLOWLIST:
CLEAN only if every node kind, every command word, every command's
options, and every word's expansions are each individually on a small
known-safe list. Anything not explicitly recognized — a new node kind
bashlex adds, a command not in the fixed verb set, an option this file
does not know, a parameter-expansion operator — fails closed to NESTED.
This is the structural fix for the recurring class of denylist bypass
(PATH=. x, hash -p, enable -f, PS4 + set -x, printf -v, read, mapfile,
declare -n, ${v@P}, …): each of those escalates here not because someone
enumerated it, but because it is not affirmatively on any allow list.

Reads ONE raw shell script on stdin (line-1 `#!` shebang already stripped
by the caller, `_cp_code_content_reason`, same place shebangs are
stripped before python content is judged). Prints exactly one line,
`NESTED` or `CLEAN`, and always exits 0 — the caller (`_cp_shell_nested`
in lib/command-policy.sh) reads that line; a non-`NESTED`/`CLEAN` line or
a non-zero exit means this process is broken and the caller fails closed.

## Rule set (CLEAN requires ALL of these; any failure is NESTED)

1. Parse succeeds, and every bashlex node kind encountered is in
   `ALLOWED_KINDS` below: list, operator, pipeline, pipe, compound, if,
   for, while, reservedword (restricted further to the if/for/while
   keyword vocabulary in `ALLOWED_RESERVEDWORDS` — a subshell `( )` or
   group `{ }`'s own parenthesis/brace reservedwords, and `until`,
   `coproc`, `case`, function definitions, are NOT on that list and so
   fall through to the generic deny), command, word, assignment,
   redirect, parameter, tilde. Everything else — function, process
   substitution, command substitution, coproc, arithmetic compound,
   case, an unparseable construct — is NESTED by simply not being in the
   set; there is no separate "banned kinds" list to keep in sync.

2. A command's own verb (`_handle_command`) must be a plain literal word
   (no parts — no expansion of any kind — and matching
   `[A-Za-z0-9._+-]+`, or the literal `[`) that is a member of
   `ALLOWED_COMMANDS`. No launcher peeling (`env`, `command`, `builtin`,
   `sudo`, `nohup`, `time`, …): those names are simply absent from
   `ALLOWED_COMMANDS`, so `env bash x` is NESTED at the first word,
   same as `bash x` — this design intentionally drops the previous
   denylist's launcher-prelude special case rather than re-deriving it.
   Every allowed command's arguments are further checked by
   `_check_word_parts` (rule 3) and, for the seven commands with their
   own `_check_<name>` function below, by a command-specific option
   rule (sed/find/tar/sort/rm/chmod/printf) straight from the design doc.
   `git` is not in `ALLOWED_COMMANDS` at all (r2e): repo-local config
   (`core.fsmonitor`, `diff.external`, a `textconv` driver) runs an
   arbitrary program for read-only subcommands regardless of CLI flags,
   so no static rule over the invoking command line can be sound.

3. Every word (command argument, assignment value, for-loop item — any
   `kind == "word"` node, reached generically whether or not it sits
   inside a `command` node's parts) is literal text/quoted literal text
   automatically whenever bashlex reports no parts at all. A non-empty
   `parts` list is checked part-by-part: `kind == "parameter"` is CLEAN
   only when its value is a bare name (`^[A-Za-z_][A-Za-z0-9_]*$`), a
   positional (`^[0-9]+$`), or a single-character special parameter
   (`@ * # ? $ ! -`) — this is what excludes every parameter-expansion
   OPERATOR (`${x:-y}`, `${x@P}`, `${!x}`, `${x/a/b}`, `${#x}`, …) by
   construction: their `.value` is never just a bare name. `kind ==
   "tilde"` is CLEAN only for a bare `~` (`~user` has a longer value and
   is rejected). Any other part kind — `commandsubstitution`,
   `processsubstitution`, or anything unrecognized — is NESTED.

4. An assignment (`x=1`, always surfaced by bashlex as a `word`-shaped
   node with `kind` overwritten to `"assignment"` — same `.word`/`.parts`
   shape, see `_handle_command`'s and `p_simple_command`'s comments) is
   CLEAN only when: the name before `=` matches `^[a-z_][a-z0-9_]*$`
   (lowercase-only — this is what rejects `PATH=`, `PS4=`, `IFS=`,
   `BASH_ENV=`, every all-caps/mixed-case name, by construction rather
   than by enumerating dangerous names); the operator is plain `=`, never
   `+=`; the value text does not start with `(` (no arrays); and the
   value's own parts pass rule 3.

5. A redirect's target must be a literal path: `output.parts` empty, no
   expansion at all (stricter than an ordinary argument word, which may
   carry a simple `$NAME`) — "redirect to a literal path" in the design
   doc. A here-string (`redirect.type == "<<<"`) is unconditionally
   NESTED regardless of content — r2f: its word undergoes the same
   parameter/command/arithmetic expansion as a heredoc body, and nothing
   requires that expansion to be visible in `.parts` for every case
   worth banning on sight. A heredoc (`redirect.type in ("<<", "<<-")`)
   is CLEAN only when BOTH: the OWNING command's verb is exactly `cat`,
   AND the delimiter word as written is quoted (`<<'EOF'` or `<<"EOF"`
   — checked via `_heredoc_delim_quoted` on the raw, never-parts-bearing
   delimiter word bashlex hands back; an unquoted delimiter undergoes
   full parameter/command/arithmetic expansion inside the heredoc body
   per `bash(1)`, so `cat <<EOF` / `$(touch pwned)` / `EOF` must be
   NESTED even though the classifier never reads `.heredoc.value`
   itself — r2e, closes REVIEW-r2d.md's heredoc HIGH). This check runs
   unconditionally over EVERY redirect of a `command` node — including
   one with zero `word` parts (a bare `<<EOF...EOF` or an
   assignment-prefixed `x=1 <<EOF...EOF`, both valid grammar productions
   with no verb at all) — and also over every redirect reached outside
   `_handle_command` via `_walk`'s generic traversal, in which case there
   is no owning verb to pass and the check always fails closed to NESTED
   (r2f, closes REVIEW-r2e.md Finding 1: the prior code only ran this
   check after an `if not words: return` early-out, so a word-less
   command's heredoc was never reached).
   r2h: the quoted-delimiter CLEAN half of this check is correct but
   unreachable in practice — `.venv-bashlex`'s `bashlex/heredoc.py:15`
   has its quote-removal call commented out, so `bashlex.parse()`
   itself raises `ParsingError` on ANY quoted heredoc delimiter before
   this file ever walks the tree (see `tmp/DESIGN.md` r2h §F2 for the
   full trace). Accepted as a documented limitation (conductor
   decision, r2h): v27 has no heredoc use, and failing closed to
   NESTED on an upstream parse error is the correct default anyway.

6. Any Python exception while importing bashlex, parsing, or walking,
   or a `SIGALRM` timeout (`TIMEOUT_SECONDS`), is NESTED. The bash glue
   (`_cp_shell_nested`) independently treats a non-zero exit or any
   output other than the literal strings `NESTED`/`CLEAN` as NESTED too,
   so a crash in this file cannot loosen anything from the caller's side
   either.

## Deliberately out of scope (NESTED), named here rather than silently

Subshells `( … )`, brace groups `{ … }`, `until`, `coproc`, `case`,
function definitions, arithmetic `(( … ))` or `$(( … ))`, command/process
substitution anywhere, every here-string (`<<<`, r2f: always NESTED
regardless of content), any heredoc except a `cat` heredoc with a quoted
delimiter (`<<'EOF'`/`<<"EOF"`), every interpreter/indirection verb
(`bash sh zsh dash ksh fish python* perl ruby node deno bun php lua
osascript eval exec xargs source . command builtin sudo nohup time hash
enable set shopt trap alias declare typeset local readonly export read
mapfile ssh curl …` — not individually denylisted, just never added to
`ALLOWED_COMMANDS`), `git` (r2e: removed from `ALLOWED_COMMANDS`
entirely — repo-local config can run a program for a read-only
subcommand with no CLI flag involved, see rule 2 above), `env`/
`command`/`builtin`-style launcher preludes, pipeline negation (`!`),
uppercase/special-name assignments, array assignments, `+=`, any
parameter-expansion operator, `~user`.
"""
import re
import signal
import sys

TIMEOUT_SECONDS = 2
MAX_INPUT_CHARS = 65536

# ---- rule 1: node-kind allowlist -------------------------------------------
ALLOWED_KINDS = {
    "list", "operator", "pipeline", "pipe", "compound",
    "if", "for", "while", "reservedword",
    "command", "word", "assignment", "redirect", "parameter", "tilde",
}
# Only the if/for/while structural keywords — NOT `(` `)` `{` `}` (subshell/
# group), NOT `!` (pipeline negation), NOT `until`/`coproc`/`case` words.
ALLOWED_RESERVEDWORDS = {"if", "then", "elif", "else", "fi", "for", "in", "do", "done", "while", ";"}

# ---- rule 3: word/parameter/tilde shape ------------------------------------
_SIMPLE_PARAM_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])$')

# ---- rule 2: command-word shape + fixed verb set ---------------------------
_CMDWORD_RE = re.compile(r'^[A-Za-z0-9._+-]+$')
ALLOWED_COMMANDS = {
    "echo", "printf", "cat", "ls", "pwd", "wc", "head", "tail", "cut", "tr",
    "sort", "uniq", "basename", "dirname", "date", "test", "[", "true",
    "false", "mkdir", "cp", "mv", "ln", "chmod", "touch", "mktemp",
    "shasum", "sha256sum", "id", "cd", "grep",
    "sed", "find", "tar", "rm", "set",
}

# ---- rule 4: assignment shape ----------------------------------------------
_ASSIGN_SPLIT_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)(\+?=)(.*)$', re.S)
_LOWER_NAME_RE = re.compile(r'^[a-z_][a-z0-9_]*$')

# ---- per-command option rules (design doc section 2) -----------------------
# sed script allowlist (r2f): CLEAN only for `s///flags`, `p`, `d`, each with
# an optional line-number/`$`/`/regex/` address (or address range), joined by
# `;`/newline — denylisting just `e`/`w`/`W` missed `r`/`R` (read-file) and
# any command this file doesn't yet know about; allowlisting the three safe
# commands instead fails closed on everything else by construction.
_SED_ADDR_RE = r'(?:[0-9]+|\$|/(?:\\.|[^/\\])*/)'
_SED_STMT_RE = re.compile(
    r'^\s*(?:' + _SED_ADDR_RE + r'(?:,' + _SED_ADDR_RE + r')?!?\s*)?'
    r'(?:p|d|s(?P<delim>[^0-9A-Za-z\\\s])(?:\\.|(?!(?P=delim)).)*(?P=delim)'
    r'(?:\\.|(?!(?P=delim)).)*(?P=delim)[gpiImM0-9]*)\s*$'
)
_FIND_BANNED = {"-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"}
_TAR_SHORT_ALLOWED_CHARS = set("cxtvfzjJCp")  # bundled short opts: c x t v f z j J C p only
_TAR_OLD_STYLE_RE = re.compile(r'^[A-Za-z]+$')  # old-style first-arg option letters, no leading dash
_TAR_DANGEROUS_LONG = {
    "--to-command", "--use-compress-program", "--checkpoint-action",
    "--info-script", "--new-volume-script", "--rsh-command",
}
_TAR_SAFE_LONG = {
    "--create", "--extract", "--list", "--verbose", "--gzip", "--gunzip",
    "--bzip2", "--xz", "--zstd", "--file", "--directory",
    "--strip-components", "--exclude", "--same-owner", "--no-same-owner",
    "--numeric-owner", "--totals", "--one-top-level",
}
_SORT_NO_ARG_SHORT = {"-r", "-n", "-u"}
_SORT_ARG_SHORT = {"-k", "-t", "-o"}
_SORT_NO_ARG_CHARS = set("rnu")  # bundled form, e.g. `-rn` == `-r -n`
_CHMOD_SETUID_NUM_RE = re.compile(r'^[1-7][0-7]{3}$')  # 4-digit octal, nonzero leading digit
_CHMOD_SETUID_SYM_RE = re.compile(r'[+=][rwxXst,]*s')
# r2h: `set` allowlist — CLEAN only for -e/-u (bundleable) and
# -o pipefail|errexit|nounset (plus the `+` forms of each). Everything
# else (bare `set`, -x/-v, any other -o name, positional args after `--`)
# is NESTED by construction, closing the PS4/`set -x` HIGH (r2b).
_SET_FLAG_CHARS = set("eu")
_SET_O_NAMES = {"pipefail", "errexit", "nounset"}

_nested = False


class _Timeout(Exception):
    pass


def _on_alarm(_signum, _frame):
    raise _Timeout()


def _mark_nested():
    global _nested
    _nested = True


def _check_word_parts(node):                 # word or assignment node -> True if every part is simple
    for p in node.parts:
        if p.kind == "parameter":
            if not _SIMPLE_PARAM_RE.match(p.value):
                return False
        elif p.kind == "tilde":
            if p.value != "~":
                return False
        else:
            return False  # commandsubstitution, processsubstitution, anything unrecognized
    return True


def _check_redirect(node, basename):          # redirect node, owning verb (or None) -> True if CLEAN
    if node.type == "<<<":
        return False                           # here-string: expanded like a heredoc body, always NESTED
    if node.type in ("<<", "<<-"):
        return basename == "cat" and _heredoc_delim_quoted(node.output.word)
    out = node.output
    if out is None:
        return True
    return not out.parts

def _heredoc_delim_quoted(word):              # heredoc delimiter word -> True if quoted ('EOF'/"EOF")
    return len(word) >= 2 and word[0] == word[-1] and word[0] in ("'", '"')


def _check_assignment(node):
    m = _ASSIGN_SPLIT_RE.match(node.word)
    if not m:
        return False
    name, op, value_text = m.groups()
    if op != "=":
        return False                          # no +=
    if not _LOWER_NAME_RE.match(name):
        return False                          # lowercase only — rejects PATH, PS4, IFS, BASH_ENV, ...
    if value_text.startswith("("):
        return False                          # no arrays
    return _check_word_parts(node)


def _check_printf(args):
    return not any(a.word == "-v" or a.word.startswith("-v") for a in args)


def _sed_script_clean(text):                  # True only if every ;/newline-joined statement is s///, p, or d
    for stmt in re.split(r'[;\n]+', text):
        if not stmt.strip():
            continue
        if not _SED_STMT_RE.match(stmt):
            return False
    return True


def _check_sed(args):
    script_seen = False
    expect_script = False
    for a in args:
        w = a.word
        if expect_script:
            if a.parts or not _sed_script_clean(w):
                return False
            script_seen = True
            expect_script = False
            continue
        if w in ("-e", "--expression"):
            expect_script = True
            continue
        if w.startswith("--expression="):
            if a.parts or not _sed_script_clean(w[len("--expression="):]):
                return False
            script_seen = True
            continue
        if w.startswith("--in-place"):
            # BSD sed's `-i extension` takes a mandatory, *separate* argument
            # (REVIEW-r2f HIGH): modeling it as zero-argument let the real
            # script slide into the loosely-checked file-operand branch and
            # an unrestricted `w`/`r` sed command slip through as CLEAN.
            # Narrowing only: any in-place edit (GNU attached suffix or BSD
            # separate-arg suffix) fails closed instead of being modeled.
            return False
        if w.startswith("-") and not w.startswith("--") and any(c in "iI" for c in w[1:]):
            return False
        if w.startswith("-"):
            # Fail closed on anything else: -f/--file/--file= (external
            # script file, contents unreadable to this classifier — r2f,
            # closes REVIEW-r2e Finding 2), any bundled cluster containing
            # `f`, and an `-e` whose script is attached with no space
            # (`-ee touch pwned`, same finding) — none of those match a
            # known branch above, so this used to silently `continue`.
            return False
        if not script_seen:
            if a.parts or not _sed_script_clean(w):
                return False                  # script must be a single literal matching the allowlist
            script_seen = True
        # else: file operand, already validated by rule-3 word-shape check
    return True


def _check_find(args):
    return not any(a.word in _FIND_BANNED for a in args)


def _check_tar(args):
    for idx, a in enumerate(args):
        w = a.word
        if w.startswith("--"):
            name = w.split("=", 1)[0]
            if name in _TAR_DANGEROUS_LONG or name not in _TAR_SAFE_LONG:
                return False                  # unknown/dangerous long option = NESTED
            continue
        if w.startswith("-") and len(w) > 1:
            cluster = w[1:]
            if any(ch not in _TAR_SHORT_ALLOWED_CHARS for ch in cluster):
                return False                  # bundled short option outside c x t v f z j J C p
            continue
        if idx == 0 and _TAR_OLD_STYLE_RE.match(w):
            if any(ch not in _TAR_SHORT_ALLOWED_CHARS for ch in w):
                return False                  # old-style option letters, no leading dash
    return True


def _check_rm(args):
    recursive = False
    targets = []
    for a in args:
        w = a.word
        if not a.parts and w.startswith("-") and w != "-":
            if "r" in w or "R" in w:
                recursive = True
            continue
        targets.append(a)
    if recursive:
        for t in targets:
            w = t.word
            if w in ("/", "~", "$HOME"):
                return False
            if w == ".." or w.startswith("../") or w.endswith("/..") or "/../" in w:
                return False
    return True


def _check_chmod(args):
    for a in args:
        w = a.word
        if a.parts or w.startswith("-"):
            continue
        if _CHMOD_SETUID_NUM_RE.match(w):
            return False                      # setuid/setgid/sticky octal bit
        if _CHMOD_SETUID_SYM_RE.search(w):
            return False                      # +s / =s / u+s symbolic setuid
    return True


def _check_set(args):
    if not args:
        return False                          # bare `set` dumps shell state
    i, n = 0, len(args)
    while i < n:
        a = args[i]
        w = a.word
        if a.parts or len(w) < 2 or w[0] not in "+-":
            return False                      # expansion, bare word, or `--`/positional
        body = w[1:]
        if body == "o" or (body and body[-1] == "o"):
            flags_part = body[:-1] if body != "o" else ""
            if any(c not in _SET_FLAG_CHARS for c in flags_part):
                return False                  # e.g. `-xo` — `x` not an allowed bundled flag
            i += 1
            if i >= n:
                return False                  # `-o`/`-euo` with no following option name
            nxt = args[i]
            if nxt.parts or nxt.word not in _SET_O_NAMES:
                return False
            i += 1
            continue
        if any(c not in _SET_FLAG_CHARS for c in body):
            return False                      # -x, -v, or any other short flag
        i += 1
    return True


def _check_sort(args):
    expect_arg = False
    for a in args:
        w = a.word
        if expect_arg:
            if a.parts:
                return False
            expect_arg = False
            continue
        if not w.startswith("-") or w == "-":
            continue                          # positional file operand / stdin, already word-shape checked
        if w in _SORT_NO_ARG_SHORT:
            continue
        if w in _SORT_ARG_SHORT:
            expect_arg = True
            continue
        if w[:2] in _SORT_ARG_SHORT and len(w) > 2:
            if a.parts:
                return False                  # attached form -k1,1 / -t, / -ofile must be literal
            continue
        cluster = w[1:]
        if cluster and all(ch in _SORT_NO_ARG_CHARS for ch in cluster):
            continue                          # bundled no-arg short opts, e.g. -rn == -r -n (r2f)
        return False                          # any other option, incl. --compress-program = NESTED
    return True


_OPTION_CHECKS = {
    "printf": _check_printf, "sed": _check_sed, "find": _check_find,
    "tar": _check_tar, "sort": _check_sort, "rm": _check_rm, "chmod": _check_chmod,
    "set": _check_set,
}


def _handle_command(node):
    for p in node.parts:
        if p.kind not in ("assignment", "word", "redirect"):
            _mark_nested()
            return
    assignments = [p for p in node.parts if p.kind == "assignment"]
    words = [p for p in node.parts if p.kind == "word"]
    redirects = [p for p in node.parts if p.kind == "redirect"]

    for a in assignments:
        if not _check_assignment(a):
            _mark_nested()
            return

    # Speculative basename for the heredoc/here-string ownership check only
    # (a word-less command, e.g. a bare `<<EOF...EOF` or `x=1 <<EOF...EOF`,
    # has no verb at all; `_check_redirect` must still see `None` rather than
    # skip the check entirely — r2f, closes REVIEW-r2e Finding 1). Full verb
    # validation (membership in ALLOWED_COMMANDS etc.) still happens below.
    basename = None
    if words and not words[0].parts and (_CMDWORD_RE.match(words[0].word) or words[0].word == "["):
        basename = words[0].word

    for r in redirects:
        if not _check_redirect(r, basename):
            _mark_nested()
            return

    if not words:
        return                                 # bare assignment(s)/redirect(s) — no verb to judge

    verb = words[0]
    if verb.parts or not (_CMDWORD_RE.match(verb.word) or verb.word == "["):
        _mark_nested()
        return
    if basename not in ALLOWED_COMMANDS:
        _mark_nested()
        return

    args = words[1:]
    for w in args:
        if not _check_word_parts(w):
            _mark_nested()
            return

    check = _OPTION_CHECKS.get(basename)
    if check is not None and not check(args):
        _mark_nested()
        return


def _walk(node):
    if _nested:
        return
    if not hasattr(node, "kind"):
        return
    kind = node.kind

    if kind not in ALLOWED_KINDS:
        _mark_nested()
        return
    if kind == "reservedword":
        if node.word not in ALLOWED_RESERVEDWORDS:
            _mark_nested()
        return
    if kind == "parameter":
        if not _SIMPLE_PARAM_RE.match(node.value):
            _mark_nested()
        return
    if kind == "tilde":
        if node.value != "~":
            _mark_nested()
        return
    if kind == "word":
        if not _check_word_parts(node):
            _mark_nested()
        return
    if kind == "redirect":
        if not _check_redirect(node, None):     # no owning command here to vouch for a heredoc/here-string
            _mark_nested()
        return
    if kind == "assignment":
        if not _check_assignment(node):
            _mark_nested()
        return
    if kind == "command":
        _handle_command(node)
        return

    # list, operator, pipeline, pipe, compound, if, for, while: structural
    # wrappers with no rule of their own — recurse generically. This is
    # also what makes a subshell/group fall through to NESTED with no
    # special case: `compound.list` for `( ... )`/`{ ... }` carries
    # `reservedword` nodes whose `.word` is `(`/`)`/`{`/`}`, which
    # `ALLOWED_RESERVEDWORDS` above does not contain.
    for attr, val in vars(node).items():
        if attr in ("kind", "pos", "s"):
            continue
        if isinstance(val, list):
            for item in val:
                if hasattr(item, "kind"):
                    _walk(item)
                    if _nested:
                        return
        elif hasattr(val, "kind"):
            _walk(val)
            if _nested:
                return


def main():
    raw = sys.stdin.read(MAX_INPUT_CHARS + 1)
    if len(raw) > MAX_INPUT_CHARS:
        print("NESTED")
        return 0

    old_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(TIMEOUT_SECONDS)
    try:
        try:
            import bashlex  # imported here so an import failure is also "parse error"
            try:
                trees = bashlex.parse(raw)
            except _Timeout:
                raise
            except Exception:  # noqa: BLE001 — any parse failure fails closed
                print("NESTED")
                return 0
        except _Timeout:
            print("NESTED")
            return 0

        try:
            for tree in trees:
                _walk(tree)
                if _nested:
                    break
        except _Timeout:
            print("NESTED")
            return 0
        except RecursionError:
            print("NESTED")
            return 0
        except Exception:  # noqa: BLE001 — a walker bug must fail closed too
            print("NESTED")
            return 0
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

    print("NESTED" if _nested else "CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
