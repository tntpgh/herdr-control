#!/usr/bin/env bash
# lib/tool-summary.sh — turn a {tool_name, tool_input} pair into the same
# "toolName: detail" summary line the omp side builds in
# agent-hooks/omp-herdr-control.ts's describeToolCall(). Kept in sync by
# hand — one runs in bash (Claude Code hooks), one in TypeScript (omp's
# extension) — there is no shared runtime to import between them.
#
# Why this exists: a Slack approval alert that only names the TOOL ("Claude
# needs your permission to use Bash") is unanswerable without switching to
# the pane — you don't know which command you'd be approving. This pulls the
# part of the input a human actually needs to decide: the command for bash,
# the path for file tools, the pattern for search tools, and the raw
# (truncated) input JSON for anything unrecognized — never silently dropping
# an unfamiliar tool's arguments.
#
# Provides: tool_summary_line <tool_name> <tool_input_json> -> "name: detail"
# (or just "name" when the input carried nothing tool-specific to show).

_TOOL_SUMMARY_MAX=300

# Flatten to one line (Slack renders the result inside a single backtick
# span) and cap length — a multi-KB heredoc command is still useful to see
# the START of, not useful to dump in full into a phone notification.
_tool_summary_truncate() {
  local flat
  flat=$(printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/ +/ /g; s/^ //; s/ $//')
  if [ "${#flat}" -gt "$_TOOL_SUMMARY_MAX" ]; then
    printf '%s…' "${flat:0:$_TOOL_SUMMARY_MAX}"
  else
    printf '%s' "$flat"
  fi
}

tool_summary_line() {
  local name="$1" input="$2" detail="" pattern path
  case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
    bash | shell)
      detail=$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null) ;;
    write | read | edit | multiedit)
      detail=$(printf '%s' "$input" | jq -r '.file_path // .path // empty' 2>/dev/null) ;;
    grep)
      pattern=$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null)
      path=$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)
      [ -n "$pattern" ] && detail="${pattern}${path:+  ($path)}" ;;
    glob)
      detail=$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null) ;;
    *)
      detail=$(printf '%s' "$input" | jq -c '.' 2>/dev/null)
      [ "$detail" = "{}" ] && detail="" ;;
  esac
  if [ -n "$detail" ]; then
    printf '%s: %s' "$name" "$(_tool_summary_truncate "$detail")"
  else
    printf '%s' "$name"
  fi
}
