#!/usr/bin/env bash
# route-task.sh --provider deterministic|jev --brief FILE
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
provider=deterministic
brief_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) [ $# -ge 2 ] || { echo "route-task: --provider needs a value" >&2; exit 2; }; provider=$2; shift 2 ;;
    --brief) [ $# -ge 2 ] || { echo "route-task: --brief needs a file" >&2; exit 2; }; brief_file=$2; shift 2 ;;
    *) echo "usage: route-task.sh [--provider deterministic|jev] --brief FILE" >&2; exit 2 ;;
  esac
done
[ -n "$brief_file" ] || { echo "route-task: --brief is required" >&2; exit 2; }
[ -r "$brief_file" ] || { echo "route-task: brief is not readable: $brief_file" >&2; exit 2; }
case "$provider" in
  deterministic)
    . "$here/lib/task-routing.sh"
    json=$(route_task_deterministic "$(cat "$brief_file")") || status=$?
    status=${status:-0}
    printf '%s\n' "$json"
    exit "$status"
    ;;
  jev)
    exec python3 "$here/scripts/jev_route.py" --brief "$brief_file"
    ;;
  *) echo "route-task: unknown provider: $provider" >&2; exit 2 ;;
esac
