#!/usr/bin/env bash
# Atomic recovery bundle for an OMP session. It never signals the process.
set -euo pipefail

die() { echo "session-recovery: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
worktree_digest() {
  local repo=$1 f
  {
    git -C "$repo" rev-parse HEAD
    git -C "$repo" status --porcelain=v2 --branch
    git -C "$repo" diff --binary HEAD
    git -C "$repo" submodule status --recursive 2>/dev/null
    while IFS= read -r -d '' f; do
      printf 'untracked %s\0' "$f"
      shasum -a 256 "$repo/$f"
    done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  } | shasum -a 256 | awk '{print $1}'
}
tree_digest() {
  local root=$1 p rel
  (
    cd "$root"
    find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' p; do
      rel=${p#./}
      if [ -L "$p" ]; then
        printf 'link %s %s\0' "$rel" "$(readlink "$p")"
      else
        printf 'file %s ' "$rel"
        shasum -a 256 "$p"
      fi
    done
  ) | shasum -a 256 | awk '{print $1}'
}
usage() {
  echo "usage: $0 snapshot --pid N --pane ID --terminal ID --session-file FILE --repo DIR --out DIR --environment-reviewed [--allow-version-change --source-version V --fallback-binary FILE --fallback-native FILE]" >&2
  echo "       $0 verify DIR" >&2
  echo "       $0 restore-check DIR" >&2
  echo "       $0 accept DIR --evidence FILE --revision FULL_SHA" >&2
  exit 2
}

verify_bundle() {
  [ -f "$1/manifest.json" ] && [ -f "$1/SHA256SUMS" ] || die "not a recovery bundle: $1"
  (cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "bundle checksum verification failed"
}
restore_check() {
  local bundle=$1 tmp head
  verify_bundle "$bundle"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/session-restore.XXXXXX")
  head=$(cat "$bundle/worktree/head.txt")
  git -c advice.detachedHead=false clone -q "$bundle/worktree/repo.bundle" "$tmp/repo"
  git -C "$tmp/repo" -c advice.detachedHead=false checkout -q "$head"
  [ ! -s "$bundle/worktree/tracked.patch" ] || git -C "$tmp/repo" apply --binary "$bundle/worktree/tracked.patch"
  tar -C "$tmp/repo" -xzf "$bundle/worktree/untracked.tar.gz"
  git -C "$tmp/repo" status --porcelain=v2 >"$tmp/status.txt"
  cmp -s "$tmp/status.txt" "$bundle/worktree/status-files.txt" || die "disposable worktree restore does not match snapshot"
  mkdir "$tmp/export"; (cd "$tmp/export" && PI_NATIVES_DIR="$bundle/runtime/natives" "$bundle/runtime/omp" --export "$bundle/session.jsonl" >export.txt)
  grep -q '^Exported to:' "$tmp/export/export.txt" || die "archived session is not parseable by recovery runtime"
  mkdir -p "$tmp/control" "$tmp/home" "$tmp/agent" "$tmp/state" "$tmp/sessions"
  cp "$bundle/session.jsonl" "$tmp/resume-session.jsonl"
  cp "$bundle/control/config.sh" "$bundle/control/herdr-control.ts" "$bundle/control/omp-worker-overlay.yml" "$tmp/control/"
  tar -C "$tmp/control" -xzf "$bundle/control/authority-lib.tar.gz"
  cat >"$tmp/control/recovery-probe.ts" <<'EOF'
import { existsSync } from "node:fs";
import hook from "./herdr-control.ts";
for (const p of ["./config.sh", "./omp-worker-overlay.yml", "./lib/command-policy.sh"]) {
  if (!existsSync(new URL(p, import.meta.url))) throw new Error(`recovery control file missing: ${p}`);
}
console.error("RECOVERY_CONTROL_LOADED");
export default hook;
EOF
  HOME="$tmp/home" PI_CODING_AGENT_DIR="$tmp/agent" PI_NATIVES_DIR="$bundle/runtime/natives" \
    HERDR_CONTROL_DIR="$tmp/control" HERDR_RUN_STATE_DIR="$tmp/state" HERDR_HUB_PORT=59999 \
    "$bundle/runtime/omp" --resume "$tmp/resume-session.jsonl" --mode rpc --no-ui --no-tools --no-skills --no-rules --no-title \
    --session-dir "$tmp/sessions" --hook "$tmp/control/recovery-probe.ts" >"$tmp/resume.out" 2>"$tmp/resume.err" &
  resume_pid=$!
  n=0
  while [ "$n" -lt 50 ] && kill -0 "$resume_pid" 2>/dev/null && ! grep -q '^RECOVERY_CONTROL_LOADED$' "$tmp/resume.err"; do sleep 0.1; n=$((n + 1)); done
  kill "$resume_pid" 2>/dev/null || true
  wait "$resume_pid" 2>/dev/null || true
  grep -q '^RECOVERY_CONTROL_LOADED$' "$tmp/resume.err" || die "isolated resume did not load archived session, hook, config and authority"
  rm -rf "$tmp"
}

case "${1:-}" in
verify) [ "$#" = 2 ] || usage; verify_bundle "$2"; echo "session-recovery: bundle verified"; exit 0;;
restore-check) [ "$#" = 2 ] || usage; restore_check "$2"; echo "session-recovery: disposable restore verified"; exit 0;;
accept)
  [ "$#" = 6 ] && [ "$3" = --evidence ] && [ -r "$4" ] && [ "$5" = --revision ] || usage
  verify_bundle "$2"
  [ "${#6}" = 40 ] && ! printf '%s' "$6" | LC_ALL=C grep -q '[^0-9a-f]' || die "acceptance revision must be exactly 40 lowercase hexadecimal characters"
  here=$(cd "$(dirname "$0")" && pwd)
  manifest_sha=$(sha "$2/manifest.json")
  verifier=${HERDR_VERIFIER:-$here/restart.sh}
  [ -r "$verifier" ] || die "health verifier unavailable"
  verifier_sha=$(sha "$verifier")
  now=$(date -u +%s)
  jq -e --arg manifest "$manifest_sha" --arg verifier "$verifier_sha" --arg revision "$6" --argjson now "$now" \
    '.schema == 1 and .status == "HEALTHY" and .bundle_manifest_sha256 == $manifest and .verifier_sha256 == $verifier and .deployed_revision == $revision and (.checked_at_epoch|type) == "number" and (($now - .checked_at_epoch) >= 0) and (($now - .checked_at_epoch) <= 600)' \
    "$4" >/dev/null || die "acceptance evidence is stale or not bound to this bundle, verifier and revision"
  umask 077
  { date -u +%Y-%m-%dT%H:%M:%SZ; sha "$4"; } >"$2/LIVE_ACCEPTED_AT"
  echo "session-recovery: acceptance recorded; bundle retained at $2"
  exit 0
  ;;
snapshot) shift;; *) usage;; esac

pid='' pane='' terminal='' session_file='' repo='' out='' allow_change=0 source_version='' fallback_binary='' fallback_native='' environment_reviewed=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pid) pid=${2:-}; shift 2;; --pane) pane=${2:-}; shift 2;; --terminal) terminal=${2:-}; shift 2;;
    --session-file) session_file=${2:-}; shift 2;; --repo) repo=${2:-}; shift 2;; --out) out=${2:-}; shift 2;;
    --allow-version-change) allow_change=1; shift;; --source-version) source_version=${2:-}; shift 2;;
    --fallback-binary) fallback_binary=${2:-}; shift 2;; --fallback-native) fallback_native=${2:-}; shift 2;;
    --environment-reviewed) environment_reviewed=1; shift;;
    *) usage;;
  esac
done
case "$pid" in ''|*[!0-9]*) usage;; esac
[ -n "$pane" ] && [ -n "$terminal" ] && [ -r "$session_file" ] && [ -d "$repo/.git" -o -f "$repo/.git" ] && [ -n "$out" ] && [ "$environment_reviewed" = 1 ] || usage
[ ! -e "$out" ] || die "output exists: $out"
out_name=$(basename "$out"); out_parent=$(dirname "$out"); mkdir -p "$out_parent"; out="$(cd "$out_parent" && pwd)/$out_name"

lsof_bin=${HERDR_LSOF:-lsof}
ps_bin=${HERDR_PS:-ps}
birth_before=$($ps_bin -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//' || true)
argv_before=$($ps_bin -p "$pid" -o command= 2>/dev/null || true)
[ -n "$birth_before" ] && [ -n "$argv_before" ] || die "pid $pid is not observable"
txt=$($lsof_bin -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p') || die "cannot inspect pid $pid"
cwd_before=$($lsof_bin -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
[ -n "$cwd_before" ] || die "pid cwd is not observable"
session_before=$(sha "$session_file")
head_before=$(git -C "$repo" rev-parse HEAD)
status_before=$(git -C "$repo" status --porcelain=v2 --branch)
worktree_before=$(worktree_digest "$repo")
binary=''; native=''
while IFS= read -r p; do case "$p" in */bin/omp) [ -n "$binary" ] || binary=$p;; *pi_natives.darwin-arm64.node) [ -n "$native" ] || native=$p;; esac; done <<EOF
$txt
EOF

mode=exact
if [ ! -r "$binary" ] || [ ! -r "$native" ]; then
  [ "$allow_change" = 1 ] || die "prior runtime path is missing; exact recovery unavailable"
  [ -n "$source_version" ] && [ -x "$fallback_binary" ] && [ -r "$fallback_native" ] || die "version-changing recovery requires source version and readable fallback binary/native"
  mode=version-changing
  binary=$fallback_binary; native=$fallback_native
fi

umask 077
parent=$(dirname "$out")
lock="$out.lock"; mkdir "$lock" 2>/dev/null || die "snapshot destination is already being published"
stage=$(mktemp -d "$parent/.session-recovery.XXXXXX")
trap 'rm -rf "$stage" "$lock"' EXIT HUP INT TERM
mkdir -p "$stage/runtime/natives" "$stage/control" "$stage/worktree"
install -m 500 "$binary" "$stage/runtime/omp"
version=$("$stage/runtime/omp" --version | sed -n 's#^omp/##p')
case "$version" in ''|*[!0-9A-Za-z._-]*) die "invalid recovery runtime version";; esac
[ "$mode" = exact ] && source_version=$version
case "$native" in */"$version"/pi_natives.darwin-arm64.node) ;; *) die "recovery native version does not match recovery binary: $version";; esac
mkdir -p "$stage/runtime/natives/$version"
install -m 400 "$native" "$stage/runtime/natives/$version/pi_natives.darwin-arm64.node"

hook=${HERDR_HOOK:-$HOME/.omp/agent/extensions/herdr-control.ts}
control=${HERDR_CONTROL_DIR:-$(cd "$(dirname "$0")" && pwd)}
overlay=${HERDR_WORKER_OVERLAY:-$control/agent-hooks/omp-worker-overlay.yml}
[ -r "$hook" ] && [ -r "$control/config.sh" ] && [ -r "$overlay" ] || die "hook/config/overlay unavailable"
hook_before=$(sha "$hook")
config_before=$(sha "$control/config.sh")
overlay_before=$(sha "$overlay")
authority_before=$(tree_digest "$control/lib")
install -m 400 "$hook" "$stage/control/herdr-control.ts"
install -m 400 "$control/config.sh" "$stage/control/config.sh"
install -m 400 "$overlay" "$stage/control/omp-worker-overlay.yml"
COPYFILE_DISABLE=1 tar -C "$control" -czf "$stage/control/authority-lib.tar.gz" lib
install -m 400 "$session_file" "$stage/session.jsonl"

git -C "$repo" status --porcelain=v2 --branch >"$stage/worktree/status.txt"
git -C "$repo" status --porcelain=v2 >"$stage/worktree/status-files.txt"
git -C "$repo" rev-parse HEAD >"$stage/worktree/head.txt"
git -C "$repo" submodule status --recursive >"$stage/worktree/submodules.txt" 2>/dev/null || die "submodule state is not recoverable"
git -C "$repo" status --ignored --porcelain=v2 >"$stage/worktree/ignored-inventory.txt"
ignored_count=$(grep -c '^!' "$stage/worktree/ignored-inventory.txt" || true)
[ "$ignored_count" = 0 ] || die "worktree has $ignored_count ignored paths; classify and preserve required state before migration"
git -C "$repo" bundle create "$stage/worktree/repo.bundle" HEAD >/dev/null
git -C "$repo" diff --binary HEAD >"$stage/worktree/tracked.patch"
git -C "$repo" ls-files --others --exclude-standard -z >"$stage/worktree/untracked.zlist"
if tr '\0' '\n' <"$stage/worktree/untracked.zlist" | grep -E '(^|/)(\.env($|\.)|id_[a-z0-9_]+$|credentials|secrets?|.*\.pem$|.*\.key$)' >/dev/null; then
  die "untracked files include credential-like names; add safe ignore rules or preserve them separately"
fi
if [ -s "$stage/worktree/untracked.zlist" ]; then
  COPYFILE_DISABLE=1 tar -C "$repo" --null -T "$stage/worktree/untracked.zlist" -czf "$stage/worktree/untracked.tar.gz"
else
  COPYFILE_DISABLE=1 tar -czf "$stage/worktree/untracked.tar.gz" --files-from /dev/null
fi

PI_NATIVES_DIR="$stage/runtime/natives" "$stage/runtime/omp" --version >"$stage/runtime/version.txt"
file "$stage/runtime/omp" "$stage/runtime/natives/$version/pi_natives.darwin-arm64.node" >"$stage/runtime/file-identities.txt"
grep -q 'arm64' "$stage/runtime/file-identities.txt" || die "recovery runtime/native architecture is not arm64"
mkdir "$stage/session-compat"
(cd "$stage/session-compat" && PI_NATIVES_DIR="$stage/runtime/natives" "$stage/runtime/omp" --export "$stage/session.jsonl" >export.txt)
grep -q '^Exported to:' "$stage/session-compat/export.txt" || die "recovery runtime cannot parse archived session"
rm -f "$stage/session-compat"/*.html

# Fail rather than publishing a coherent-looking bundle assembled across a
# process restart, transcript append or Git mutation.
birth_after=$($ps_bin -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//' || true)
argv_after=$($ps_bin -p "$pid" -o command= 2>/dev/null || true)
session_after=$(sha "$session_file")
head_after=$(git -C "$repo" rev-parse HEAD)
status_after=$(git -C "$repo" status --porcelain=v2 --branch)
worktree_after=$(worktree_digest "$repo")
hook_after=$(sha "$hook")
config_after=$(sha "$control/config.sh")
overlay_after=$(sha "$overlay")
authority_after=$(tree_digest "$control/lib")
[ "$birth_before" = "$birth_after" ] && [ "$argv_before" = "$argv_after" ] || die "pid identity changed during snapshot"
[ "$session_before" = "$session_after" ] || die "session changed during snapshot; retry at a checkpoint"
[ "$head_before" = "$head_after" ] && [ "$status_before" = "$status_after" ] && [ "$worktree_before" = "$worktree_after" ] || die "worktree content changed during snapshot; retry at a checkpoint"
[ "$hook_before" = "$hook_after" ] && [ "$config_before" = "$config_after" ] && [ "$overlay_before" = "$overlay_after" ] && [ "$authority_before" = "$authority_after" ] || die "hook/config/overlay/authority inputs changed during snapshot; retry at a checkpoint"
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --argjson pid "$pid" --arg pane "$pane" --arg created "$created" --arg mode "$mode" \
  --arg source_version "$source_version" --arg recovery_version "$version" --arg source_binary "$binary" --arg source_native "$native" \
  --arg binary_sha256 "$(sha "$stage/runtime/omp")" --arg native_sha256 "$(sha "$stage/runtime/natives/$version/pi_natives.darwin-arm64.node")" \
  --arg hook_sha256 "$(sha "$stage/control/herdr-control.ts")" --arg config_sha256 "$(sha "$stage/control/config.sh")" \
  --arg overlay_sha256 "$(sha "$stage/control/omp-worker-overlay.yml")" --arg authority_sha256 "$(sha "$stage/control/authority-lib.tar.gz")" \
  --arg session_sha256 "$(sha "$stage/session.jsonl")" --arg session_file "$session_file" --arg repo "$repo" --arg terminal "$terminal" --arg birth "$birth_before" --arg argv "$argv_before" --arg cwd "$cwd_before" \
  '{schema:3,pid:$pid,pane:$pane,terminal:$terminal,pid_birth:$birth,argv:$argv,cwd:$cwd,created_at:$created,recovery_mode:$mode,source_version:$source_version,recovery_version:$recovery_version,source_binary:$source_binary,source_native:$source_native,binary_sha256:$binary_sha256,native_sha256:$native_sha256,hook_sha256:$hook_sha256,config_sha256:$config_sha256,overlay_sha256:$overlay_sha256,authority_sha256:$authority_sha256,session_file:$session_file,session_sha256:$session_sha256,repo:$repo,retention:"retain_until_fresh_bundle_bound_live_acceptance",ignored_state:"none_at_snapshot",environment_state:"values_not_archived; operator_review_required_and_recorded",secrets_policy:"private_mode_0700; no environment or credential values copied"}' >"$stage/manifest.json"
find "$stage" -type f ! -name SHA256SUMS -exec shasum -a 256 {} + | sed "s#$stage/##" | sort -k2 >"$stage/SHA256SUMS"
(cd "$stage" && shasum -a 256 -c SHA256SUMS >/dev/null)
restore_check "$stage"
mv "$stage" "$out"; rmdir "$lock"; trap - EXIT HUP INT TERM
echo "session-recovery: verified $mode bundle at $out; retain until live acceptance"
