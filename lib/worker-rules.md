<!-- source: herdr-control lib/worker-rules.md — appended to every managed
     launch by lib/agent-profiles.sh canonical_rules_compose. Rules about how
     approvals work for a spawned worker; not project rules. -->
## Getting work approved (herdr-control)

Your approvals are judged by an approver that sees only a terminal panel, and
the panel is clipped. Shape your calls so the WHOLE action is reviewable:

- **More than ~10 lines of code goes in a file, then run it by reference.**
  Write `tmp/<name>.py` / `tmp/<name>.sh` with the write tool, then
  `python3 tmp/<name>.py` / `bash tmp/<name>.sh`. The approver reads and
  classifies the whole file, and an approval is bound to the file's sha256:
  re-running the same file clears; an edited file is reviewed again. A long
  inline `eval` or `python3 -c` cannot be approved — its panel is clipped.
- **Long subagent context goes in a file too.** Write the shared context to
  `tmp/<topic>-context.md` and each brief to `tmp/<topic>-<slice>.md`, then
  spawn with `context: "Read tmp/<topic>-context.md first"` and
  `task: "Read tmp/<topic>-<slice>.md and do it"`.
- **Test inputs are data, keep them out of argv.** A command whose quoted
  arguments merely MENTION `git push`, a credential path, or a policy file is
  scanned as if it ran them. Put such strings in a file and pass the path.
- **Your capability manifest** (`capability_manifest` in
  `.handoffs/identity.json`, approved once at spawn) lists the hosts you may
  GET and the paths you may write. Use an explicit `cd <worktree> && curl -q
  --noproxy '*' ...` GET (`-q` and `--noproxy '*'` FIRST, no `-L`, no `$VAR`,
  no unquoted `* ? { }`) to a `net_read` host, with `-o`/`-D` targets inside
  `writes`, to clear without a review. Use the same explicit
  `cd <worktree> &&` prefix when running a reviewed script by reference.
  editing identity.json changes nothing.
- **A script that runs or imports another local file is reviewed every
  run** — an approval binds one file's sha256. Keep reviewed logic in one file.
