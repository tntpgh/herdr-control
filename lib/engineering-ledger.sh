#!/usr/bin/env bash
# Shared implementation for engineering-ledger-poll.sh.
# shellcheck shell=bash

_engineering_ledger_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_engineering_ledger_repo_dir=$(cd "$_engineering_ledger_lib_dir/.." && pwd)

# Single source for the sensitive-value deny check used when redacting free
# text pulled from Sentry issue titles and KB failure rows. Two variants:
# a strict form used on "signature" values (short, colon-truncated tokens,
# capped at 60 chars) requires password/token/secret/api-key to be followed
# by an assignment; a looser form used on longer free-text "label" values
# (capped at 80 chars) matches those words unconditionally. Kept as plain
# strings (not functions) so the collectors' inline `jq -c` programs can
# share the same pattern via `--arg` instead of duplicating the literal.
_engineering_ledger_sensitive_sig_pattern='(?i)(bearer[[:space:]]+|xox[baprs]-|gh[opsu]_|sk-[a-z0-9]|op://|password[[:space:]]*=|token[[:space:]]*=|secret[[:space:]]*=|api[_-]?key[[:space:]]*=|https?://|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|/users/|/home/|(?:[0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[a-z0-9_=-]{32,})'
_engineering_ledger_sensitive_label_pattern='(?i)(bearer[[:space:]]+|xox[baprs]-|gh[opsu]_|sk-[a-z0-9]|op://|password|token|secret|api[_-]?key|https?://|[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|/users/|/home/|(?:[0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[a-z0-9_=-]{32,})'

ledger_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ledger_error_entry() {
  local source="$1" source_id="$2" poll_id="$3" observed_at="$4" signature="$5"
  jq -nc \
    --arg poll_id "$poll_id" --arg observed_at "$observed_at" \
    --arg source "$source" --arg source_id "$source_id" --arg signature "$signature" \
    '{schema:1,poll_id:$poll_id,observed_at:$observed_at,source:$source,source_id:$source_id,status:"error",failure:{class:"source_error",signature:$signature}}'
}

ledger_sentry_token() {
  if [ -n "${ENGINEERING_LEDGER_SENTRY_TOKEN:-}" ]; then
    printf '%s' "$ENGINEERING_LEDGER_SENTRY_TOKEN"
    return 0
  fi
  command -v op >/dev/null 2>&1 || return 1
  op read 'op://secrets/claude-sentry-auth-token/credential' 2>/dev/null
}

ledger_sentry_get() {
  local url="$1" token
  shift
  command -v curl >/dev/null 2>&1 || return 1
  token=$(ledger_sentry_token) || return 1
  [ -n "$token" ] || return 1

  # Keep the token off argv/process listings: curl reads its auth header from
  # stdin, matching herdr-control's Slack token handling.
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -fsS --config - --get "$@" "$url"
}

ledger_sentry_projects_json() {
  ledger_sentry_get \
    'https://sentry.io/api/0/organizations/the-thurber-team/projects/' \
    --data-urlencode 'per_page=100'
}

ledger_sentry_issues_json() {
  local project_id="$1"
  ledger_sentry_get \
    'https://sentry.io/api/0/organizations/the-thurber-team/issues/' \
    --data-urlencode "project=$project_id" \
    --data-urlencode 'statsPeriod=24h' \
    --data-urlencode 'query=is:unresolved' \
    --data-urlencode 'sort=freq' \
    --data-urlencode 'limit=100'
}

ledger_collect_sentry() {
  local source_id="$1" project_slug="$2" poll_id="$3" observed_at="$4" projects_json="$5"
  local project_id issues_json

  project_id=$(printf '%s' "$projects_json" | jq -er --arg slug "$project_slug" \
    '[.[] | select(.slug == $slug)][0].id | select(type == "string" or type == "number") | tostring' 2>/dev/null) || {
    ledger_error_entry sentry "$source_id" "$poll_id" "$observed_at" project_not_found
    return 0
  }

  issues_json=$(ledger_sentry_issues_json "$project_id" 2>/dev/null) || {
    ledger_error_entry sentry "$source_id" "$poll_id" "$observed_at" issues_unreachable
    return 0
  }
  printf '%s' "$issues_json" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    ledger_error_entry sentry "$source_id" "$poll_id" "$observed_at" invalid_response
    return 0
  }

  printf '%s' "$issues_json" | jq -c \
    --arg poll_id "$poll_id" --arg observed_at "$observed_at" \
    --arg source_id "$source_id" --arg project_slug "$project_slug" --arg project_id "$project_id" \
    --arg sig_pattern "$_engineering_ledger_sensitive_sig_pattern" '
      def safe_sig:
        tostring | split(":")[0] | gsub("^[[:space:]]+|[[:space:]]+$"; "") as $h
        | if ($h | length) == 0 then "unknown"
          elif ($h | test($sig_pattern)) then "redacted"
          else ($h | gsub("[[:space:]]+"; "_") | gsub("[^A-Za-z0-9_.-]"; "_") | .[0:60])
          end;
      def safe_time:
        if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then . else null end;
      [ .[] | {
          issue_id: ((.id // "") | tostring | if test("^[0-9]+$") then . else null end),
          signature: ((.title // "unknown") | safe_sig),
          count: ((.count // 0) | tonumber? // 0),
          first_seen: ((.firstSeen // null) | safe_time),
          last_seen: ((.lastSeen // null) | safe_time)
        }
      ] as $issues
      | {
          schema: 1,
          poll_id: $poll_id,
          observed_at: $observed_at,
          source: "sentry",
          source_id: $source_id,
          status: "ok",
          project: {slug: $project_slug, id: $project_id},
          window_hours: 24,
          issue_count: ($issues | length),
          capped_at: 100,
          top_issues: ($issues | sort_by(.count) | reverse | .[0:10])
        }
    '
}

ledger_kb_rows_json() {
  local kb_repo python dsn
  kb_repo="${ENGINEERING_LEDGER_KB_REPO:-$HOME/Code/knowledge-base}"
  python="${ENGINEERING_LEDGER_KB_PYTHON:-$kb_repo/.venv/bin/python3}"
  [ -x "$python" ] || python=$(command -v python3 2>/dev/null) || return 1

  if [ -n "${NEON_CONNECTION_STRING:-}" ]; then
    dsn="$NEON_CONNECTION_STRING"
  else
    command -v op >/dev/null 2>&1 || return 1
    dsn=$(op read 'op://secrets/neon/credential' 2>/dev/null) || return 1
  fi
  [ -n "$dsn" ] || return 1

  NEON_CONNECTION_STRING="$dsn" "$python" "$_engineering_ledger_lib_dir/engineering-ledger-kb.py" 2>/dev/null
}

ledger_collect_kb() {
  local poll_id="$1" observed_at="$2" rows_json
  rows_json=$(ledger_kb_rows_json) || {
    ledger_error_entry kb nightly_resilience "$poll_id" "$observed_at" neon_unreachable
    return 0
  }
  printf '%s' "$rows_json" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    ledger_error_entry kb nightly_resilience "$poll_id" "$observed_at" invalid_response
    return 0
  }

  printf '%s' "$rows_json" | jq -c \
    --arg poll_id "$poll_id" --arg observed_at "$observed_at" \
    --arg sig_pattern "$_engineering_ledger_sensitive_sig_pattern" \
    --arg label_pattern "$_engineering_ledger_sensitive_label_pattern" '
      def safe_sig:
        tostring | split(":")[0] | gsub("^[[:space:]]+|[[:space:]]+$"; "") as $h
        | if ($h | length) == 0 then "unknown"
          elif ($h | test($sig_pattern)) then "redacted"
          else ($h | gsub("[[:space:]]+"; "_") | gsub("[^A-Za-z0-9_.-]"; "_") | .[0:60])
          end;
      def safe_label:
        tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "") as $v
        | if ($v | length) == 0 then "unknown"
          elif ($v | test($label_pattern)) then "redacted"
          else ($v | gsub("[[:space:]]+"; "_") | gsub("[^A-Za-z0-9_.-]"; "_") | .[0:80])
          end;
      def safe_time:
        if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$") then . else null end;
      [ .[] | {
          run_id: ((.run_id // "") | tostring | if test("^[0-9a-fA-F-]{36}$") then . else null end),
          step_label: ((.step_label // "unknown") | safe_label),
          error_class: ((.error_class // "unknown") | safe_sig),
          error_signature: ((.error_signature // .error_class // "unknown") | safe_sig),
          started_at: ((.started_at // null) | safe_time),
          run_started_at: ((.run_started_at // null) | safe_time)
        }
      ] as $failures
      | {
          schema: 1,
          poll_id: $poll_id,
          observed_at: $observed_at,
          source: "kb",
          source_id: "nightly_resilience",
          status: "ok",
          window_hours: 24,
          failed_steps_count: ($failures | length),
          error_signatures: ($failures | group_by(.error_signature) | map({key: .[0].error_signature, value: length}) | from_entries),
          failures: $failures
        }
    '
}

ledger_gh_prs_json() {
  local repo_path="$1"
  command -v gh >/dev/null 2>&1 || return 1
  [ -d "$repo_path" ] || return 1
  (
    cd "$repo_path" || exit 1
    gh pr list --state all --limit 20 \
      --json number,state,createdAt,updatedAt,mergedAt,closedAt 2>/dev/null
  )
}

ledger_gh_runs_json() {
  local repo_path="$1"
  command -v gh >/dev/null 2>&1 || return 1
  [ -d "$repo_path" ] || return 1
  (
    cd "$repo_path" || exit 1
    gh run list --limit 20 \
      --json databaseId,status,conclusion,createdAt,updatedAt 2>/dev/null
  )
}

ledger_collect_github() {
  local source_id="$1" repo_path="$2" poll_id="$3" observed_at="$4"
  local prs_json='[]' runs_json='[]' prs_ok=true runs_ok=true status=ok

  prs_json=$(ledger_gh_prs_json "$repo_path") || { prs_json='[]'; prs_ok=false; }
  runs_json=$(ledger_gh_runs_json "$repo_path") || { runs_json='[]'; runs_ok=false; }
  printf '%s' "$prs_json" | jq -e 'type == "array"' >/dev/null 2>&1 || { prs_json='[]'; prs_ok=false; }
  printf '%s' "$runs_json" | jq -e 'type == "array"' >/dev/null 2>&1 || { runs_json='[]'; runs_ok=false; }

  if [ "$prs_ok" = false ] && [ "$runs_ok" = false ]; then status=error
  elif [ "$prs_ok" = false ] || [ "$runs_ok" = false ]; then status=partial
  fi

  jq -nc \
    --arg poll_id "$poll_id" --arg observed_at "$observed_at" --arg source_id "$source_id" \
    --arg status "$status" --argjson prs_ok "$prs_ok" --argjson runs_ok "$runs_ok" \
    --argjson prs "$prs_json" --argjson runs "$runs_json" '
      def cutoff7d: ($observed_at | fromdateiso8601) - (7 * 24 * 60 * 60);
      def safe_time:
        if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$") then . else null end;
      {
        schema: 1,
        poll_id: $poll_id,
        observed_at: $observed_at,
        source: "github",
        source_id: $source_id,
        status: $status,
        pull_requests: {
          status: (if $prs_ok then "ok" else "error" end),
          sample_size: ($prs | length),
          open: ([$prs[] | select(.state == "OPEN")] | length),
          merged: ([$prs[] | select(.state == "MERGED")] | length),
          closed_unmerged: ([$prs[] | select(.state == "CLOSED")] | length),
          created_last_7d: ([$prs[] | select(((.createdAt // "" | fromdateiso8601?) // 0) >= cutoff7d)] | length),
          latest_created_at: ([$prs[].createdAt | safe_time] | map(select(. != null)) | sort | last // null)
        },
        ci_runs: {
          status: (if $runs_ok then "ok" else "error" end),
          sample_size: ($runs | length),
          success: ([$runs[] | select(.conclusion == "success")] | length),
          failure: ([$runs[] | select(.conclusion == "failure")] | length),
          cancelled: ([$runs[] | select(.conclusion == "cancelled")] | length),
          in_progress: ([$runs[] | select(.status == "in_progress" or .status == "queued")] | length),
          recent_conclusions: ([$runs[0:10][] |
            if ((.conclusion // "") | length) > 0 then .conclusion
            elif ((.status // "") | length) > 0 then .status
            else "unknown" end
          ]),
          latest_created_at: ([$runs[].createdAt | safe_time] | map(select(. != null)) | sort | last // null)
        }
      }
    '
}

ledger_history_stream() {
  local state_dir="$1" file
  [ -d "$state_dir" ] || return 0
  for file in "$state_dir"/*.jsonl; do
    [ -f "$file" ] || continue
    cat "$file"
  done
}

ledger_previous_signatures() {
  local state_dir="$1" last_poll
  last_poll=$(ledger_history_stream "$state_dir" | jq -r 'select(.poll_id != null) | .poll_id' 2>/dev/null | tail -n 1)
  [ -n "$last_poll" ] || return 0
  ledger_history_stream "$state_dir" | jq -r --arg poll "$last_poll" '
    select(.poll_id == $poll and .status == "ok")
    | if .source == "sentry" then .top_issues[]?.signature
      elif .source == "kb" then .failures[]?.error_signature
      else empty end
    | select(. != "unknown" and . != "redacted")
  ' 2>/dev/null | sort -u
}

ledger_current_signatures() {
  jq -r '
    select(.status == "ok")
    | if .source == "sentry" then .top_issues[]?.signature
      elif .source == "kb" then .failures[]?.error_signature
      else empty end
    | select(. != "unknown" and . != "redacted")
  ' "$1" | sort -u
}

# macOS ships without flock. An atomic lock directory keeps the previous-cycle
# comparison and six-line append together, so concurrent invocations cannot
# interleave records or both compare against the same stale prior cycle.
ledger_lock_acquire() {
  local lock_dir="$1" holder tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 300 ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock_dir/pid" || {
    rmdir "$lock_dir" 2>/dev/null || true
    return 1
  }
}

ledger_lock_release() {
  local lock_dir="${1:-}" holder
  [ -n "$lock_dir" ] && [ -d "$lock_dir" ] || return 0
  holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
  [ "$holder" = "$$" ] || return 1
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

ledger_summary() {
  local cycle_file="$1" poll_id="$2" output_label="$3" new_signatures="$4"
  local source_summary new_label
  source_summary=$(jq -rs '
    map(
      if .source == "sentry" then "sentry/" + .source_id + "=" + .status + ":" + ((.issue_count // 0) | tostring)
      elif .source == "kb" then "kb=" + .status + ":" + ((.failed_steps_count // 0) | tostring)
      else "github/" + .source_id + "=" + .status + ":prs" + ((.pull_requests.sample_size // 0) | tostring) + "/ci" + ((.ci_runs.sample_size // 0) | tostring)
      end
    ) | join(" ")
  ' "$cycle_file")
  new_label=$(printf '%s\n' "$new_signatures" | sed '/^$/d' | head -n 10 | paste -sd, -)
  [ -n "$new_label" ] || new_label=none
  printf 'engineering-ledger: poll=%s %s new_signatures=%s output=%s\n' \
    "$poll_id" "$source_summary" "$new_label" "$output_label"
}

engineering_ledger_poll() {
  local dry_run=0
  case "${1:-}" in
    --dry-run) dry_run=1; shift ;;
    "") ;;
    *) printf 'usage: engineering-ledger-poll.sh [--dry-run]\n' >&2; return 2 ;;
  esac
  [ "$#" -eq 0 ] || { printf 'usage: engineering-ledger-poll.sh [--dry-run]\n' >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { printf 'engineering-ledger: jq is required\n' >&2; return 2; }

  local observed_at poll_id state_dir output_file cycle_file prior_file current_file new_signatures projects_json lock_dir='' lock_held=0
  observed_at=$(ledger_now)
  poll_id="${observed_at%Z}Z-$$"
  state_dir="${ENGINEERING_LEDGER_DIR:-$_engineering_ledger_repo_dir/.local-state/engineering-ledger}"
  output_file="$state_dir/${observed_at%%T*}.jsonl"
  cycle_file=$(mktemp "${TMPDIR:-/tmp}/engineering-ledger-cycle.XXXXXX") || return 2
  prior_file=$(mktemp "${TMPDIR:-/tmp}/engineering-ledger-prior.XXXXXX") || { rm -f "$cycle_file"; return 2; }
  current_file=$(mktemp "${TMPDIR:-/tmp}/engineering-ledger-current.XXXXXX") || { rm -f "$cycle_file" "$prior_file"; return 2; }
  trap 'if [ "${lock_held:-0}" -eq 1 ]; then ledger_lock_release "${lock_dir:-}" || true; fi; rm -f "$cycle_file" "$prior_file" "$current_file"' RETURN

  projects_json=$(ledger_sentry_projects_json 2>/dev/null) || projects_json=''
  if printf '%s' "$projects_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    ledger_collect_sentry tourguide node-cloudflare-workers "$poll_id" "$observed_at" "$projects_json" >> "$cycle_file"
    ledger_collect_sentry thurber-ai thurber-ai "$poll_id" "$observed_at" "$projects_json" >> "$cycle_file"
  else
    ledger_error_entry sentry tourguide "$poll_id" "$observed_at" projects_unreachable >> "$cycle_file"
    ledger_error_entry sentry thurber-ai "$poll_id" "$observed_at" projects_unreachable >> "$cycle_file"
  fi

  ledger_collect_kb "$poll_id" "$observed_at" >> "$cycle_file"
  ledger_collect_github knowledge-base "${ENGINEERING_LEDGER_KB_REPO:-$HOME/Code/knowledge-base}" "$poll_id" "$observed_at" >> "$cycle_file"
  ledger_collect_github tourguide "${ENGINEERING_LEDGER_TOURGUIDE_REPO:-$HOME/Code/tourguide}" "$poll_id" "$observed_at" >> "$cycle_file"
  ledger_collect_github thurber-ai "${ENGINEERING_LEDGER_THURBER_AI_REPO:-$HOME/Code/thurber-ai}" "$poll_id" "$observed_at" >> "$cycle_file"

  [ "$(wc -l < "$cycle_file" | tr -d ' ')" = 6 ] || {
    printf 'engineering-ledger: internal error: expected six source records\n' >&2
    return 2
  }
  jq -e . "$cycle_file" >/dev/null 2>&1 || {
    printf 'engineering-ledger: internal error: invalid JSONL; nothing appended\n' >&2
    return 2
  }

  if [ "$dry_run" -eq 1 ]; then
    ledger_previous_signatures "$state_dir" > "$prior_file"
    ledger_current_signatures "$cycle_file" > "$current_file"
    new_signatures=$(comm -23 "$current_file" "$prior_file")
    printf '%s\n' 'engineering-ledger dry-run digest (not appended):' >&2
    cat "$cycle_file" >&2
    ledger_summary "$cycle_file" "$poll_id" DRY_RUN "$new_signatures"
    return 0
  fi

  umask 077
  mkdir -p "$state_dir" || { printf 'engineering-ledger: cannot create %s\n' "$state_dir" >&2; return 2; }
  lock_dir="$state_dir/.poll.lock"
  ledger_lock_acquire "$lock_dir" || {
    printf 'engineering-ledger: timed out waiting for local ledger lock\n' >&2
    return 2
  }
  lock_held=1
  ledger_previous_signatures "$state_dir" > "$prior_file"
  ledger_current_signatures "$cycle_file" > "$current_file"
  new_signatures=$(comm -23 "$current_file" "$prior_file")
  cat "$cycle_file" >> "$output_file" || {
    printf 'engineering-ledger: cannot append %s\n' "$output_file" >&2
    return 2
  }
  chmod 600 "$output_file" 2>/dev/null || true
  ledger_lock_release "$lock_dir"
  lock_held=0
  lock_dir=''
  ledger_summary "$cycle_file" "$poll_id" "${output_file##*/}" "$new_signatures"
}
