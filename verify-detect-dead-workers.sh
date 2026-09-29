#!/usr/bin/env bash
# Proves detect-dead-workers.sh tells a dead pane from one that only MENTIONS
# the errors. The conductor false positive (a pane printing this script's own
# report table read as a dead worker) is the regression this exists for; the
# live strings come from the installed omp 18.4.2 and Codex 0.157 binaries.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fails=0

expect() { # want(hit|clean) label text
  local got
  got="$(printf '%s\n' "$3" | bash "$here/detect-dead-workers.sh" --scan-stdin)"
  if { [ "$1" = hit ] && [ -n "$got" ]; } || { [ "$1" = clean ] && [ -z "$got" ]; }; then
    printf 'PASS: %-5s %s\n' "$1" "$2"
  else
    printf 'FAIL: wanted %s, got [%s]: %s\n' "$1" "$got" "$2"; fails=$((fails + 1))
  fi
}

# Dead: what the harnesses print when a turn ends on a provider limit.
expect hit "omp retry dead-end" "Retry failed after 3 attempts: 429 rate_limit_error: Number of request tokens has exceeded your per-minute rate limit"
expect hit "omp provider wait too long" "Error: Provider requested 6132000ms wait, exceeds retry.maxDelayMs (300000ms). Original error: 429"
expect hit "codex raw error code" "ERROR: stream error: code=usage_limit_reached"
expect hit "codex friendly line" "■ You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/codex/settings/usage to purchase more credits"
expect hit "codex friendly line, no bullet" "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits"

# Alive: panes that only talk about these errors.
expect clean "conductor report table" "PANE	HERDR	LABEL	SIGNATURE
w4R:p2	working	review	usage_limit_reached"
expect clean "grep hit in a file" "docs/notes.md:12:- a Codex worker died with usage_limit_reached"
expect clean "markdown table cell" "| w4R:p2 | You've hit your usage limit | respawned |"
expect clean "prose about the error" "the reviewer hit rate_limit_error yesterday, so I respawned it"
expect clean "empty pane" ""

# End to end, with the hub and herdr stubbed: a dead pane is reported, a live
# one is not, and a `%` in a label is data, not a printf directive.
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
cat > "$stub/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"panes":[{"pane_id":"w1:p1","agent":"omp","agent_status":"working","label":"100%sure %s"},{"pane_id":"w1:p2","agent":"omp","agent_status":"working","label":"alive"},{"pane_id":"w1:p3","label":"shell"}]}'
EOF
cat > "$stub/herdr" <<'EOF'
#!/usr/bin/env bash
case "$3" in
  w1:p1) printf 'working...\nError: Provider requested 6132000ms wait, exceeds retry.maxDelayMs (300000ms)\n' ;;
  *) printf 'still going, ran the tests\n' ;;
esac
EOF
chmod +x "$stub/curl" "$stub/herdr"
out="$(PATH="$stub:$PATH" bash "$here/detect-dead-workers.sh")"; rc=$?
if [ "$rc" = 1 ] && grep -qF $'w1:p1\tworking\t100%sure %s\t' <<< "$out" && ! grep -q 'w1:p2' <<< "$out"; then
  echo "PASS: table reports only the dead pane, label intact"
else
  echo "FAIL: table (rc=$rc): $out"; fails=$((fails + 1))
fi
json="$(PATH="$stub:$PATH" bash "$here/detect-dead-workers.sh" --json)"
if [ "$(jq -r '.candidates | map(.label) | join(",")' <<< "$json" 2>/dev/null)" = "100%sure %s" ]; then
  echo "PASS: --json reports only the dead pane, label intact"
else
  echo "FAIL: json: $json"; fails=$((fails + 1))
fi
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
