#!/usr/bin/env bash
# Explicit trusted-storage fixtures for policy regression suites. This file is
# never sourced by production. It does not replace any production verifier;
# caller authentication itself is exercised by the authorization suites.
fixture_register_task() {
  local args=("$@") receipt="fixture-${1}-${2}" manifest="${15:-}" actor="${5:-fixture-conductor}" birth="${6:-fixture-birth}"
  while [ "${#args[@]}" -lt 16 ]; do args+=(""); done
  # Older menu tests omitted branch/trunk because they exercised only policy
  # text. A verified receipt deliberately requires the complete task binding.
  args[11]="${args[11]:-fixture/$2}"; args[12]="${args[12]:-main}"
  if [ -z "$manifest" ]; then
    case "${14:-}" in \{*) manifest="${14}" ;; esac
  fi
  accept_local_task_authorization "$receipt" "$actor" "$birth" "$9" "$manifest" || return 1
  register_task "${args[@]}" "$receipt" || return 1
  mark_authorization_launch "$receipt" "$2" "$1" launch_claimed || return 1
  mark_authorization_launch "$receipt" "$2" "$1" launched
}
