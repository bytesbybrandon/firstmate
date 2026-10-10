#!/usr/bin/env bash
# Stored directory spelling and read-only validation-remote agreement.
# Run with TMPDIR on a case-insensitive volume for native case-alias coverage;
# symlink aliases cover the same identity boundary on portable CI filesystems.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-project-path-lib.sh
. "$ROOT/bin/fm-project-path-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-path)
mkdir -p "$TMP_ROOT/Project" "$TMP_ROOT/staging one" "$TMP_ROOT/staging-two"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
project="$TMP_ROOT/Project"
fm_git_init_commit "$project"
ln -s "$project" "$TMP_ROOT/PROJECT"
canonical=$(fm_project_canonical_dir "$project")
for alias in "$TMP_ROOT/PROJECT" "$project/../Project/."; do
  [ "$(fm_project_canonical_dir "$alias")" = "$canonical" ] \
    || fail "aliases did not converge to the stored path"
done
if [ -d "$TMP_ROOT/project" ] && [ "$TMP_ROOT/project" -ef "$project" ]; then
  [ "$(fm_project_canonical_dir "$TMP_ROOT/project")" = "$canonical" ] \
    || fail "native lowercase alias retained caller spelling"
  pass "native uppercase/lowercase paths converge to stored spelling"
else
  fm_git_init_commit "$TMP_ROOT/project"
  [ "$(fm_project_canonical_dir "$TMP_ROOT/project")" != "$canonical" ] \
    || fail "distinct case-sensitive directories were conflated"
  pass "distinct case-sensitive directories keep distinct paths"
fi
fm_project_canonical_dir "$TMP_ROOT/absent" >/dev/null \
  && fail "missing path was accepted"
pass "symlink and dot aliases converge; missing directories refuse"

other="$TMP_ROOT/OtherRepo"
fm_git_init_commit "$other"
git -C "$project" remote add origin https://example.invalid/same-origin.git
git -C "$other" remote add origin https://example.invalid/same-origin.git
[ "$(fm_project_canonical_dir "$other")" != "$canonical" ] \
  || fail "distinct repositories sharing an origin were conflated"
pass "ordinary distinct repositories sharing an origin keep distinct paths"

fakebin=$(fm_fakebin "$TMP_ROOT")
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$*" = status ] || exit 2
pwd -P >> "$FM_PATH_CWD_LOG"
[ "${FM_PATH_STATUS_FAILURE:-0}" = 0 ] || exit 1
printf '    gate:  %s\n' "$FM_PATH_GATE"
SH
chmod +x "$fakebin/no-mistakes"
export PATH="$fakebin:$PATH" FM_PATH_CWD_LOG="$TMP_ROOT/cwd-log"
export FM_PATH_GATE="$TMP_ROOT/staging one"
fm_project_validation_remote_check "$project" || fail "ungated repo refused"
[ ! -f "$FM_PATH_CWD_LOG" ] || fail "ungated repo consulted no-mistakes"
git -C "$project" remote add no-mistakes "$FM_PATH_GATE"
fm_project_validation_remote_check "$project" || fail "consistent remote refused"
FM_PATH_GATE='../staging one' fm_project_validation_remote_check "$project" \
  || fail "relative NM_HOME staging path refused"
ln -s "$FM_PATH_GATE" "$TMP_ROOT/staging-alias"
git -C "$project" remote set-url no-mistakes "$TMP_ROOT/staging-alias"
fm_project_validation_remote_check "$project" || fail "same staging directory alias refused"
git -C "$project" remote set-url no-mistakes "file://$FM_PATH_GATE"
fm_project_validation_remote_check "$project" || fail "local file URL refused"
pass "consistent and aliased staging targets pass without registration changes"

git -C "$project" remote set-url no-mistakes "$TMP_ROOT/staging-two"
if out=$(fm_project_validation_remote_check "$project" 2>&1); then
  fail "different staging repository was accepted"
fi
assert_contains "$out" 'validation remote disagreement' "refusal did not explain the disagreement"
assert_contains "$out" "$FM_PATH_GATE" "refusal omitted the resolved staging repository"
[ "$(git -C "$project" remote get-url no-mistakes)" = "$TMP_ROOT/staging-two" ] \
  || fail "refusal repaired the remote"
git -C "$project" remote set-url no-mistakes "$FM_PATH_GATE"
git -C "$project" remote set-url --push no-mistakes "$TMP_ROOT/staging-two"
fm_project_validation_remote_check "$project" >/dev/null 2>&1 \
  && fail "different push target was accepted"
git -C "$project" config --unset-all remote.no-mistakes.pushurl
git -C "$project" config --add remote.no-mistakes.url "$TMP_ROOT/staging-two"
fm_project_validation_remote_check "$project" >/dev/null 2>&1 \
  && fail "second differing fetch URL was accepted"
git -C "$project" config --unset-all remote.no-mistakes.url
git -C "$project" config remote.no-mistakes.url "$FM_PATH_GATE"
FM_PATH_GATE='' fm_project_validation_remote_check "$project" >/dev/null 2>&1 \
  && fail "uninitialized registration was accepted"
FM_PATH_GATE="$TMP_ROOT/absent" fm_project_validation_remote_check "$project" >/dev/null 2>&1 \
  && fail "missing staging directory was accepted"
FM_PATH_STATUS_FAILURE=1 fm_project_validation_remote_check "$project" >/dev/null 2>&1 \
  && fail "failed CLI resolution was accepted"
pass "different fetch/push targets and unresolved registrations refuse without repair"
